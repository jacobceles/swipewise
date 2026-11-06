"""One in-memory run owner, one new AVD. Saved evidence is never a resume token."""

import hashlib
import json
import os
import re
import shlex
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

IMAGE = 'system-images;android-36.1;google_apis;arm64-v8a'
QEMU_NAMES = {'qemu-system-aarch64', 'qemu-system-aarch64-headless'}


class InfrastructureError(RuntimeError):
    pass


def command(args, *, env=None, timeout=10, input=None):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True,
                            timeout=timeout, env=env, input=input)
    if result.returncode or re.search(
            r'(?im)^\s*(KO\b|error\b|failure\b|exception\b|unknown command\b)|'
            r'(?i:no (?:matching|running) activities|unable to resolve|permission denied)',
            result.stdout + '\n' + result.stderr):
        raise InfrastructureError('COMMAND_FAILED_OR_UNAVAILABLE')
    return result.stdout.strip()


def process_info(pid):
    return {
        'pid': pid,
        'parent': int(command(['ps', '-p', str(pid), '-o', 'ppid='])),
        'started': command(['ps', '-p', str(pid), '-o', 'lstart=']),
        'executable': command(['ps', '-ww', '-p', str(pid), '-o', 'comm=']),
        'argv': shlex.split(command(['ps', '-ww', '-p', str(pid), '-o', 'command='])),
    }


def validate_process(info, expected, sdk, avd, name, port, launcher_pid):
    """Also used by offline negative tests; the live guard calls this exact check."""
    if info['pid'] != expected['pid'] or info['started'] != expected['started']:
        raise InfrastructureError('PROCESS_IDENTITY_CHANGED')
    executable = Path(info['executable']).resolve()
    qemu_root = (sdk / 'emulator/qemu').resolve()
    if not executable.is_relative_to(qemu_root) or executable.name not in QEMU_NAMES:
        raise InfrastructureError('NOT_RUN_QEMU')
    if info['pid'] != launcher_pid and info['parent'] != launcher_pid:
        raise InfrastructureError('NOT_LAUNCHER_CHILD')
    args = info['argv']
    for flag, value in (('-avd', name), ('-port', str(port)), ('-datadir', str(avd)),
                        ('-adb-path', str(Path(__file__).with_name('emulator_adb_guard.py')))):
        if args.count(flag) != 1 or args.index(flag) + 1 >= len(args) or args[args.index(flag) + 1] != value:
            raise InfrastructureError('QEMU_ARGUMENT_IDENTITY_CHANGED')


def free_port_pair():
    # Never pick the owner's conventional 5554/5555 pair, and never accept a
    # caller's arbitrary serial. Ordinary -port, not the special -ports option.
    for port in range(5570, 5590, 2):
        sockets = []
        try:
            for candidate in (port, port + 1):
                sock = socket.socket()
                sockets.append(sock)
                sock.bind(('127.0.0.1', candidate))
            return port
        except OSError:
            continue
        finally:
            for sock in sockets:
                sock.close()
    raise InfrastructureError('NO_FREE_PORT_PAIR')


class OwnedAvd:
    def __init__(self, evidence, sdk):
        # The caller just created evidence with mkdtemp. No existing manifest,
        # serial, AVD name/path or PID can be supplied to this constructor.
        self.evidence = Path(evidence).resolve()
        if (Path(evidence).is_symlink() or self.evidence.parent != approved_root() or
                not self.evidence.name.startswith('swipewise-owned-') or any(self.evidence.iterdir())):
            raise InfrastructureError('NEW_RUN_DIRECTORY_REQUIRED')
        self.sdk = Path(sdk).resolve()
        self.root_identity = (self.evidence.stat().st_dev, self.evidence.stat().st_ino)
        self.run_id = 'q-' + uuid.uuid4().hex
        self.name = self.run_id
        self.home = self.evidence / 'avd-home'
        self.home.mkdir(mode=0o700)
        self.avd = self.home / f'{self.name}.avd'
        self.marker = self.home / 'run-owner.json'
        self.marker.write_text(json.dumps({'run_id': self.run_id, 'pid': os.getpid()}))
        self.marker_bytes = self.marker.read_bytes()
        self.home_identity = (self.home.stat().st_dev, self.home.stat().st_ino)
        self.avd_identity = None
        self.port = free_port_pair()
        self.serial = f'emulator-{self.port}'
        # W3 invokes `adb` through PATH. Pin that same client for all guarded
        # commands, rather than mixing the SDK copy with a different PATH copy.
        client = shutil.which('adb')
        if not client:
            raise InfrastructureError('ADB_CLIENT_UNAVAILABLE')
        self.adb = Path(client).resolve()
        emulator_home = self.evidence / 'emulator-home'
        emulator_home.mkdir(mode=0o700)
        self.env = dict(os.environ, ANDROID_AVD_HOME=str(self.home),
                        ANDROID_EMULATOR_HOME=str(emulator_home))
        self.process = None
        self.qemu = None
        self.transport_id = None
        self.closed = False
        self.log_handle = None
        self.log_path = None
        self.actions = []

    def files_owned(self):
        root = self.evidence.lstat()
        stat = self.home.lstat()
        if (self.evidence.is_symlink() or (root.st_dev, root.st_ino) != self.root_identity or
                self.home.is_symlink() or (stat.st_dev, stat.st_ino) != self.home_identity or
                self.marker.read_bytes() != self.marker_bytes or
                json.loads(self.marker_bytes)['run_id'] != self.run_id or
                json.loads(self.marker_bytes)['pid'] != os.getpid() or
                self.home.parent != self.evidence or self.avd.parent != self.home or
                self.avd.name != f'{self.name}.avd' or self.name != self.run_id):
            raise InfrastructureError('AVD_DIRECTORY_OWNERSHIP_CHANGED')
        if self.avd_identity:
            stat = self.avd.lstat()
            if self.avd.is_symlink() or (stat.st_dev, stat.st_ino) != self.avd_identity:
                raise InfrastructureError('AVD_PATH_CHANGED')
            ini = self.home / f'{self.name}.ini'
            if [line for line in ini.read_text().splitlines() if line.startswith('path=')] != [f'path={self.avd}']:
                raise InfrastructureError('AVD_REGISTRY_CHANGED')

    def start(self):
        self.files_owned()
        image = self.sdk / 'system-images/android-36.1/google_apis/arm64-v8a'
        if not (image / 'system.img').is_file():
            raise InfrastructureError('INSTALLED_IMAGE_REQUIRED')
        if self.process and self.process.poll() is None:
            raise InfrastructureError('ALREADY_RUNNING')
        if self.avd_identity is None:
            if self.avd.exists():
                raise InfrastructureError('NEW_AVD_REQUIRED')
            manager = self.sdk / 'cmdline-tools/latest/bin/avdmanager'
            output = command([manager, 'create', 'avd', '-n', self.name, '-k', IMAGE, '-p', self.avd],
                             env=self.env, timeout=60, input='no\n')
            (self.evidence / 'avd-create.txt').write_text(output + '\n')
            stat = self.avd.lstat()
            self.avd_identity = (stat.st_dev, stat.st_ino)
        self.files_owned()
        # Creation may have taken seconds; refuse a port claimed in the meantime.
        with socket.socket() as console, socket.socket() as adb:
            console.bind(('127.0.0.1', self.port))
            adb.bind(('127.0.0.1', self.port + 1))
        shield = Path(__file__).with_name('emulator_adb_guard.py')
        if not shield.is_file() or not os.access(shield, os.X_OK):
            raise InfrastructureError('EMULATOR_ADB_SHIELD_UNAVAILABLE')
        args = [str(self.sdk / 'emulator/emulator'), '-avd', self.name, '-port', str(self.port),
                '-datadir', str(self.avd), '-no-window', '-no-audio', '-no-snapshot',
                '-no-boot-anim', '-gpu', 'swiftshader', '-no-metrics',
                '-adb-path', str(shield)]
        self.closed = False
        self.qemu = None
        self.transport_id = None
        self.log_path = self.evidence / 'emulator.log'
        if self.log_path.exists():
            self.log_path = self.evidence / f'emulator-restart-{time.time_ns()}.log'
        self.log_handle = self.log_path.open('x')
        self.process = subprocess.Popen(args, env=self.env, stdout=self.log_handle,
                                        stderr=subprocess.STDOUT, start_new_session=True)
        self.save_owner()
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise InfrastructureError('EMULATOR_EXITED')
            root = process_info(self.process.pid)
            candidates = [root]
            if Path(root['executable']).name not in QEMU_NAMES:
                children = subprocess.run(['pgrep', '-P', str(self.process.pid)],
                                          capture_output=True, text=True, timeout=5)
                candidates = [process_info(int(p)) for p in children.stdout.split()]
            matches = [p for p in candidates if Path(p['executable']).name in QEMU_NAMES]
            if len(matches) == 1:
                self.qemu = matches[0]
                validate_process(self.qemu, self.qemu, self.sdk, self.avd, self.name,
                                 self.port, self.process.pid)
                self.save_owner()
                break
            time.sleep(0.2)
        if not self.qemu:
            raise InfrastructureError('RUN_QEMU_NOT_IDENTIFIED')
        self.wait_ready()
        self.save_owner()

    def host_guard(self):
        self.files_owned()
        if self.closed or not self.process or self.process.poll() is not None or not self.qemu:
            raise InfrastructureError('NO_LIVE_RUN_OWNER')
        validate_process(process_info(self.qemu['pid']), self.qemu, self.sdk, self.avd,
                         self.name, self.port, self.process.pid)
        for port in (self.port, self.port + 1):
            sockets = command(['lsof', '-nP', '-a', '-p', str(self.qemu['pid']),
                               f'-iTCP:{port}', '-sTCP:LISTEN', '-Fpn'])
            if f'p{self.qemu["pid"]}\n' not in sockets + '\n' or not re.search(rf':{port}$', sockets, re.M):
                raise InfrastructureError('PORT_PROCESS_OWNERSHIP_CHANGED')

    def raw_identity_read(self, args):
        return command([self.adb, '-s', self.serial, *args])

    def guard(self, serial=None):
        if (serial is not None and serial != self.serial) or self.serial != f'emulator-{self.port}':
            raise InfrastructureError('SERIAL_MISMATCH')
        self.host_guard()
        devices = command([self.adb, 'devices', '-l'])
        lines = [line for line in devices.splitlines() if line.split() and line.split()[0] == self.serial]
        if len(lines) != 1 or not re.match(rf'{re.escape(self.serial)}\s+device\s+', lines[0]):
            raise InfrastructureError('TARGET_TRANSPORT_UNAVAILABLE')
        match = re.search(r'\btransport_id:(\d+)\b', lines[0])
        if not match or (self.transport_id is not None and self.transport_id != match[1]):
            raise InfrastructureError('TRANSPORT_ID_CHANGED')
        self.transport_id = match[1]
        if self.raw_identity_read(['get-serialno']) != self.serial:
            raise InfrastructureError('ADB_SERIAL_IDENTITY_CHANGED')
        if self.raw_identity_read(['emu', 'avd', 'name']).splitlines() != [self.name, 'OK']:
            raise InfrastructureError('EMULATOR_AVD_IDENTITY_CHANGED')
        return {'run_id': self.run_id, 'pid': self.qemu['pid'], 'process_started': self.qemu['started'],
                'serial': self.serial, 'transport_id': self.transport_id, 'avd': str(self.avd),
                'port': self.port, 'adb_port': self.port + 1}

    def wait_ready(self):
        deadline = time.monotonic() + 180
        last_error = 'BOOT_NOT_COMPLETE'
        while time.monotonic() < deadline:
            try:
                self.guard()
                if self.raw_identity_read(['shell', 'getprop', 'sys.boot_completed']) == '1':
                    return
            except (InfrastructureError, OSError, subprocess.SubprocessError) as exc:
                last_error = type(exc).__name__
            time.sleep(1)
        raise InfrastructureError(f'BOUNDED_BOOT_FAILURE_{last_error}')

    def run_adb(self, args, *, timeout=15):
        proof = self.guard()
        output = command([self.adb, '-s', self.serial, *args], timeout=timeout)
        self.actions.append({'at_unix_ns': time.time_ns(), 'args': [str(a) for a in args],
                             'owner': proof, 'stdout_sha256': hashlib.sha256(output.encode()).hexdigest()})
        self.save_owner()
        return output

    def send_location(self, serial, point, mode):
        # W3 remains the only coordinate/speed/formatting/timing implementation.
        import play_gpx_route
        if Path(shutil.which('adb') or '').resolve() != self.adb.resolve():
            raise InfrastructureError('PLAYER_ADB_EXECUTABLE_CHANGED')
        proof = self.guard(serial)
        play_gpx_route.send_location(serial, point, mode)
        self.actions.append({'at_unix_ns': time.time_ns(), 'input': point, 'mode': mode, 'owner': proof})
        self.save_owner()

    def save_owner(self):
        data = {'schema_version': 1, 'run_id': self.run_id, 'avd_home': str(self.home),
                'avd_path': str(self.avd), 'avd_name': self.name, 'port': self.port,
                'adb_port': self.port + 1, 'serial': self.serial, 'transport_id': self.transport_id,
                'launcher_pid': self.process.pid if self.process else None,
                'adb_client': str(self.adb),
                'qemu': self.qemu, 'home_identity': self.home_identity,
                'avd_identity': self.avd_identity, 'actions': self.actions,
                'emulator_log': str(self.log_path) if self.log_path else None,
                'closed': self.closed, 'not_resumable': True}
        (self.evidence / 'owner.json').write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')

    def close(self):
        # Do not signal by a saved PID or load a manifest. With a live process,
        # revalidate host + transport + AVD before the scoped console shutdown.
        if self.process and self.process.poll() is None:
            try:
                self.run_adb(['emu', 'kill'])
            except (InfrastructureError, subprocess.SubprocessError):
                # An offline/failed-boot transport cannot authenticate a console
                # shutdown. Host PID/birth/path/ports/nonce must still prove this
                # live run's QEMU before signalling that exact created process.
                if self.serial != f'emulator-{self.port}':
                    raise InfrastructureError('SERIAL_MISMATCH')
                self.host_guard()
                self.actions.append({'cleanup': 'SIGTERM_HOST_OWNED_QEMU', 'pid': self.qemu['pid'],
                                     'run_id': self.run_id, 'transport_id': self.transport_id})
                self.save_owner()
                os.kill(self.qemu['pid'], signal.SIGTERM)
            self.process.wait(timeout=30)
        if self.process and not self.qemu:
            raise InfrastructureError('RUN_QEMU_EXIT_NOT_CONFIRMED')
        if self.process and self.qemu['pid'] != self.process.pid:
            # A wrapper's exit, including before close(), is not proof its child stopped.
            child = subprocess.run(['ps', '-p', str(self.qemu['pid']), '-o', 'pid='],
                                   capture_output=True, text=True, timeout=5)
            if child.returncode != 1 or child.stdout.strip() or child.stderr.strip():
                raise InfrastructureError('CHILD_QEMU_EXIT_NOT_CONFIRMED')
        self.files_owned()
        self.closed = True
        self.save_owner()
        if self.log_handle:
            self.log_handle.close()
        # Retain the uniquely owned AVD files for review. No recursive deletion,
        # global provider/server reset, arbitrary PID signal or owner-AVD cleanup.


def approved_root():
    # tempfile.gettempdir() normally points to macOS's T directory, while the
    # approved task root is its pre-created opencode subdirectory.
    parent = Path(os.environ.get('TMPDIR', tempfile.gettempdir())).resolve()
    if parent.name != 'opencode':
        parent = parent / 'opencode'
    if not parent.is_dir():
        raise InfrastructureError('APPROVED_TEMP_ROOT_UNAVAILABLE')
    return parent


def new_owned_avd():
    parent = approved_root()
    evidence = Path(tempfile.mkdtemp(prefix='swipewise-owned-', dir=parent))
    return OwnedAvd(evidence, Path(os.environ['ANDROID_HOME']))
