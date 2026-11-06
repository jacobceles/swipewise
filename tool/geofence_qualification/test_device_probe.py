"""Offline guard tests. No emulator, ADB process, install or real device is used."""

import copy
import hashlib
import json
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

from geofence_qualification import owned_avd as owned
from geofence_qualification import probe_device as probe
from geofence_qualification import emulator_adb_guard


class OwnershipTests(unittest.TestCase):
    def setUp(self):
        # Offline fixtures own their temporary root and fake client; they must
        # not depend on a workstation's approved live-device directory or SDK.
        self.directory = tempfile.TemporaryDirectory(prefix='swipewise-owned-')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        approved = mock.patch.object(owned, 'approved_root', return_value=self.root.parent)
        approved.start()
        self.addCleanup(approved.stop)
        client = mock.patch.object(owned.shutil, 'which', return_value=str(self.root / 'client/adb'))
        client.start()
        self.addCleanup(client.stop)
        with mock.patch.object(owned, 'free_port_pair', return_value=5570):
            self.owner = owned.OwnedAvd(self.root, self.root / 'sdk')
        owner = self.owner
        owner.avd.mkdir()
        owner.avd_identity = (owner.avd.stat().st_dev, owner.avd.stat().st_ino)
        (owner.home / f'{owner.name}.ini').write_text(f'path={owner.avd}\n')
        owner.process = mock.Mock(pid=12345)
        owner.process.poll.return_value = None
        owner.qemu = {'pid': 12345, 'parent': 999, 'started': 'Fri Nov 6 00:00:00 2026',
                      'executable': str(owner.sdk / 'emulator/qemu/darwin-aarch64/qemu-system-aarch64'),
                      'argv': ['qemu-system-aarch64', '-avd', owner.name, '-port', '5570',
                               '-datadir', str(owner.avd), '-adb-path',
                               str(Path(owned.__file__).with_name('emulator_adb_guard.py'))]}
        self.current = copy.deepcopy(owner.qemu)
        self.transport = '7'
        self.device_name = owner.name
        self.socket_pid = 12345
        self.mutations = []

    def command(self, args, **kwargs):
        args = [str(value) for value in args]
        if args[0] == 'lsof':
            port = next(arg.removeprefix('-iTCP:') for arg in args if arg.startswith('-iTCP:'))
            return f'p{self.socket_pid}\nn127.0.0.1:{port}'
        if args[1:] == ['devices', '-l']:
            return f'List of devices attached\nemulator-5554 device transport_id:1\nemulator-5570 device product:test transport_id:{self.transport}'
        if args[1:4] == ['-s', 'emulator-5570', 'get-serialno']:
            return 'emulator-5570'
        if args[1:] == ['-s', 'emulator-5570', 'emu', 'avd', 'name']:
            return f'{self.device_name}\nOK'
        if args[1:3] == ['-s', 'emulator-5570']:
            self.mutations.append(args)
            return 'Success'
        raise AssertionError(f'Unexpected command {args}')

    def invoke(self):
        with mock.patch.object(owned, 'process_info', side_effect=lambda _: self.current), \
                mock.patch.object(owned, 'command', side_effect=self.command):
            return self.owner.run_adb(['install', 'synthetic.apk'])

    def test_owned_adb_targets_only_current_serial(self):
        self.assertEqual(self.invoke(), 'Success')
        self.assertEqual(len(self.mutations), 1)
        self.assertEqual(self.mutations[0][1:3], ['-s', 'emulator-5570'])
        self.assertEqual(self.owner.actions[0]['owner']['run_id'], self.owner.run_id)

    def test_installed_headless_backend_name_is_allowed_inside_sdk_only(self):
        self.current['executable'] += '-headless'
        self.assertEqual(self.invoke(), 'Success')

    def test_bound_adb_client_matches_the_path_sender_client(self):
        self.assertEqual(self.owner.adb, Path(owned.shutil.which('adb')).resolve())

    def test_pid_or_birth_change_refuses_before_mutation(self):
        for field, value in [('pid', 54321), ('started', 'another process start')]:
            with self.subTest(field=field):
                self.current = copy.deepcopy(self.owner.qemu)
                self.current[field] = value
                with self.assertRaises(owned.InfrastructureError):
                    self.invoke()
                self.assertFalse(self.mutations)

    def test_executable_parent_or_qemu_argument_mismatch_refuses(self):
        changes = [('executable', '/unrelated/qemu-system-aarch64'), ('parent', 54321)]
        # A separate qemu child must remain a direct child of our live launcher.
        self.owner.process.pid = 777
        self.owner.qemu['parent'] = 777
        for field, value in changes:
            with self.subTest(field=field):
                self.current = copy.deepcopy(self.owner.qemu)
                self.current[field] = value
                with self.assertRaises(owned.InfrastructureError):
                    self.invoke()
        self.owner.process.pid = 12345
        for flag in ('-avd', '-port', '-datadir', '-adb-path'):
            with self.subTest(flag=flag):
                self.current = copy.deepcopy(self.owner.qemu)
                self.current['argv'][self.current['argv'].index(flag) + 1] = 'foreign'
                with self.assertRaises(owned.InfrastructureError):
                    self.invoke()
                self.assertFalse(self.mutations)

    def test_nonce_or_avd_registry_mismatch_refuses(self):
        self.owner.marker.write_text('{"run_id":"stale"}')
        with self.assertRaises(owned.InfrastructureError):
            self.invoke()
        self.owner.marker.write_bytes(self.owner.marker_bytes)
        (self.owner.home / f'{self.owner.name}.ini').write_text('path=/foreign/avd\n')
        with self.assertRaises(owned.InfrastructureError):
            self.invoke()
        self.assertFalse(self.mutations)

    def test_directory_replacement_or_symlink_refuses(self):
        original = self.owner.avd
        moved = original.with_name('retained-original.avd')
        original.rename(moved)
        original.symlink_to(moved, target_is_directory=True)
        with self.assertRaises(owned.InfrastructureError):
            self.invoke()
        self.assertFalse(self.mutations)

    def test_foreign_port_owner_refuses(self):
        self.socket_pid = 54321
        with self.assertRaises(owned.InfrastructureError):
            self.invoke()
        self.assertFalse(self.mutations)

    def test_changed_transport_or_avd_identity_refuses(self):
        self.owner.transport_id = '7'
        self.transport = '8'
        with self.assertRaises(owned.InfrastructureError):
            self.invoke()
        self.transport = '7'
        self.device_name = 'foreign-avd'
        with self.assertRaises(owned.InfrastructureError):
            self.invoke()
        self.assertFalse(self.mutations)

    def test_explicit_serial_escape_never_calls_adb(self):
        with mock.patch.object(owned, 'command') as command:
            with self.assertRaises(owned.InfrastructureError):
                self.owner.guard('emulator-5554')
        command.assert_not_called()

    def test_player_sender_rechecks_each_injection(self):
        with mock.patch.object(self.owner, 'guard', side_effect=[{'run_id': self.owner.run_id},
                                                               owned.InfrastructureError('stale')]) as guard, \
                mock.patch.object(owned.shutil, 'which', return_value=str(self.owner.adb)), \
                mock.patch('play_gpx_route.send_location') as send:
            self.owner.send_location(self.owner.serial, {'speed_mps': 0}, 'fix')
            with self.assertRaises(owned.InfrastructureError):
                self.owner.send_location(self.owner.serial, {'speed_mps': 0}, 'fix')
        self.assertEqual(guard.call_count, 2)
        self.assertEqual(send.call_count, 1)

    def test_player_sender_refuses_a_changed_client_before_injection(self):
        with mock.patch.object(owned.shutil, 'which', return_value='/changed/adb'), \
                mock.patch.object(self.owner, 'guard') as guard, \
                mock.patch('play_gpx_route.send_location') as send:
            with self.assertRaises(owned.InfrastructureError):
                self.owner.send_location(self.owner.serial, {'speed_mps': 0}, 'fix')
        guard.assert_not_called()
        send.assert_not_called()

    def test_cleanup_refuses_mismatched_owner(self):
        self.current['started'] = 'reused PID'
        with mock.patch.object(owned, 'process_info', return_value=self.current), \
                mock.patch.object(owned, 'command', side_effect=self.command):
            with self.assertRaises(owned.InfrastructureError):
                self.owner.close()
        self.owner.process.wait.assert_not_called()
        self.assertFalse(self.mutations)

    def test_offline_cleanup_requires_fresh_host_proof_before_exact_pid_signal(self):
        with mock.patch.object(self.owner, 'run_adb', side_effect=owned.InfrastructureError('offline')), \
                mock.patch.object(owned, 'process_info', return_value=self.current), \
                mock.patch.object(owned, 'command', side_effect=self.command), \
                mock.patch.object(owned.os, 'kill') as kill:
            self.owner.close()
        kill.assert_called_once_with(self.current['pid'], owned.signal.SIGTERM)
        self.owner.process.wait.assert_called_once_with(timeout=30)
        self.assertTrue(self.owner.closed)

    def test_wrapper_exit_does_not_prove_its_qemu_child_stopped(self):
        self.owner.process.pid = 777
        self.owner.qemu['parent'] = 777
        self.current = copy.deepcopy(self.owner.qemu)
        with mock.patch.object(owned, 'process_info', return_value=self.current), \
                mock.patch.object(owned, 'command', side_effect=self.command), \
                mock.patch.object(owned.subprocess, 'run',
                                  return_value=subprocess.CompletedProcess([], 0, '12345', '')):
            with self.assertRaisesRegex(owned.InfrastructureError, 'CHILD_QEMU_EXIT_NOT_CONFIRMED'):
                self.owner.close()
        self.assertFalse(self.owner.closed)

    def test_already_exited_launcher_does_not_prove_its_qemu_child_stopped(self):
        self.owner.process.pid = 777
        self.owner.process.poll.return_value = 0
        with mock.patch.object(owned.subprocess, 'run',
                               return_value=subprocess.CompletedProcess([], 0, '12345', '')), \
                mock.patch.object(self.owner, 'run_adb') as adb, \
                mock.patch.object(owned.os, 'kill') as kill:
            with self.assertRaisesRegex(owned.InfrastructureError, 'CHILD_QEMU_EXIT_NOT_CONFIRMED'):
                self.owner.close()
        adb.assert_not_called()
        kill.assert_not_called()
        self.assertFalse(self.owner.closed)

    def test_existing_manifest_or_nonempty_root_cannot_be_resumed(self):
        with self.assertRaises(owned.InfrastructureError):
            owned.OwnedAvd(self.root, self.owner.sdk)

    def test_exited_launcher_with_confirmed_absent_child_can_close(self):
        self.owner.process.pid = 777
        self.owner.process.poll.return_value = 0
        with mock.patch.object(owned.subprocess, 'run',
                               return_value=subprocess.CompletedProcess([], 1, '', '')), \
                mock.patch.object(self.owner, 'run_adb') as adb, \
                mock.patch.object(owned.os, 'kill') as kill:
            self.owner.close()
        adb.assert_not_called()
        kill.assert_not_called()
        self.assertTrue(self.owner.closed)

    def test_exited_launcher_with_unidentified_qemu_cannot_claim_cleanup(self):
        self.owner.process.poll.return_value = 0
        self.owner.qemu = None
        with self.assertRaisesRegex(owned.InfrastructureError, 'RUN_QEMU_EXIT_NOT_CONFIRMED'):
            self.owner.close()
        self.assertFalse(self.owner.closed)


class ProbeTests(unittest.TestCase):
    def test_live_probe_accepts_only_an_existing_approved_subdirectory(self):
        with tempfile.TemporaryDirectory() as root:
            approved = Path(root).resolve() / 'opencode'
            approved.mkdir()
            for temporary in (root, str(approved)):
                with self.subTest(temporary=temporary), \
                        mock.patch.dict(owned.os.environ, {'TMPDIR': temporary}):
                    self.assertEqual(owned.approved_root(), approved)

    def test_live_probe_still_refuses_a_missing_approved_root(self):
        with tempfile.TemporaryDirectory() as root, \
                mock.patch.dict(owned.os.environ, {'TMPDIR': root}):
            with self.assertRaisesRegex(owned.InfrastructureError, 'APPROVED_TEMP_ROOT_UNAVAILABLE'):
                owned.approved_root()

    def test_live_owner_still_requires_an_available_adb_client(self):
        with tempfile.TemporaryDirectory(prefix='swipewise-owned-') as root:
            path = Path(root).resolve()
            with mock.patch.object(owned, 'approved_root', return_value=path.parent), \
                    mock.patch.object(owned, 'free_port_pair', return_value=5570), \
                    mock.patch.object(owned.shutil, 'which', return_value=None):
                with self.assertRaisesRegex(owned.InfrastructureError, 'ADB_CLIENT_UNAVAILABLE'):
                    owned.OwnedAvd(path, path / 'sdk')

    def test_emulator_shield_version_query_is_host_only(self):
        with mock.patch.dict(emulator_adb_guard.os.environ, {'ANDROID_HOME': '/synthetic-sdk'}), \
                mock.patch.object(emulator_adb_guard.subprocess, 'run',
                                return_value=subprocess.CompletedProcess([], 0)) as run:
            self.assertEqual(emulator_adb_guard.main(['version']), 0)
        self.assertEqual(run.call_args.args[0][-1], 'version')
        self.assertEqual(len(run.call_args.args[0]), 2)

    def test_emulator_internal_unscoped_and_scoped_mutations_are_never_forwarded(self):
        with mock.patch.dict(emulator_adb_guard.os.environ, {'ANDROID_HOME': '/synthetic-sdk'}), \
                mock.patch.object(emulator_adb_guard.subprocess, 'run') as run, \
                mock.patch('sys.stderr'):
            for args in (['-e', 'shell', 'settings', 'put', 'system', 'screen_off_timeout', '999'],
                         ['-s', 'emulator-5554', 'shell', 'anything'], ['kill-server'], ['devices']):
                self.assertEqual(emulator_adb_guard.main(args), 1)
        run.assert_not_called()

    def test_zero_exit_ko_or_semantic_failure_is_unavailable(self):
        for output in ('KO: rejected', 'Error: unknown package', 'No matching activities'):
            with self.subTest(output=output), \
                    mock.patch.object(owned.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, output, '')):
                with self.assertRaises(owned.InfrastructureError):
                    owned.command(['synthetic-command'])

    def test_trace_missing_empty_wrong_run_or_sequence_cannot_supply_observations(self):
        self.assertEqual(probe.trace_events('', 'q-run'), [])
        for event in ({'schema_version': 1, 'run_id': 'other', 'seq': 0, 'elapsed_ns': 1},
                      {'schema_version': 1, 'run_id': 'q-run', 'seq': 1, 'elapsed_ns': 1}):
            with self.assertRaises(owned.InfrastructureError):
                probe.trace_events(json.dumps(event), 'q-run')

    def test_listener_requires_a_fresh_end_snapshot_and_no_reconnection(self):
        events = [{'seq': 0, 'stage': 'listener_connected', 'data': {'active': []}},
                  {'seq': 1, 'stage': 'listener_snapshot', 'data': {'connected': True}}]
        self.assertTrue(probe.listener_continuous(events, 0))
        self.assertFalse(probe.listener_continuous(events, 1))
        self.assertFalse(probe.listener_continuous(events + [
            {'seq': 2, 'stage': 'listener_connected', 'data': {'active': []}}], 0))
        self.assertFalse(probe.listener_continuous(events + [
            {'seq': 2, 'stage': 'listener_disconnected', 'data': {}}], 0))

    def test_arbitrary_serial_or_manifest_cli_argument_is_rejected(self):
        with mock.patch.object(probe, 'new_owned_avd') as create, \
                mock.patch('sys.stderr'):
            for arg in ('--serial=emulator-5554', '--manifest=stale.json'):
                with self.assertRaises(SystemExit):
                    probe.main([arg])
        create.assert_not_called()


def safety_mutations():
    path = Path(owned.__file__)
    source = path.read_text()
    before = hashlib.sha256(path.read_bytes()).hexdigest()
    cases = [
        ('pid-birth', "if info['pid'] != expected['pid'] or info['started'] != expected['started']:", 'if False:',
         'test_pid_or_birth_change_refuses_before_mutation'),
        ('port-owner', 'if f\'p{self.qemu["pid"]}\\n\' not in sockets + \'\\n\' or not re.search(rf\':{port}$\', sockets, re.M):',
         'if False:', 'test_foreign_port_owner_refuses'),
        ('transport', "self.transport_id != match[1]", 'False', 'test_changed_transport_or_avd_identity_refuses'),
        ('nonce', 'self.marker.read_bytes() != self.marker_bytes', 'False', 'test_nonce_or_avd_registry_mismatch_refuses'),
        ('same-adb-client', 'self.adb = Path(client).resolve()', "self.adb = self.sdk / 'platform-tools/adb'",
         'test_bound_adb_client_matches_the_path_sender_client'),
        ('emulator-adb-shield-binding', '        if args.count(flag) != 1',
         '        if flag == "-adb-path":\n            continue\n        if args.count(flag) != 1',
         'test_executable_parent_or_qemu_argument_mismatch_refuses'),
        ('qemu-child-cleanup', 'if child.returncode != 1 or child.stdout.strip() or child.stderr.strip():',
          'if False:', 'test_wrapper_exit_does_not_prove_its_qemu_child_stopped'),
        ('already-exited-launcher', "if self.process and self.qemu['pid'] != self.process.pid:",
         "if self.process and self.process.poll() is None and self.qemu['pid'] != self.process.pid:",
         'test_already_exited_launcher_does_not_prove_its_qemu_child_stopped'),
        ('unidentified-qemu-cleanup', "raise InfrastructureError('RUN_QEMU_EXIT_NOT_CONFIRMED')",
         'return', 'test_exited_launcher_with_unidentified_qemu_cannot_claim_cleanup'),
    ]
    results = []
    module = sys.modules[__name__]
    for name, find, replace, test_name in cases:
        if source.count(find) != 1:
            raise AssertionError(f'Mutation no longer matches: {name}')
        mutant = types.ModuleType('owned_avd_mutant')
        mutant.__file__ = str(path)
        exec(compile(source.replace(find, replace), str(path), 'exec'), mutant.__dict__)
        suite = unittest.TestSuite([OwnershipTests('test_owned_adb_targets_only_current_serial'),
                                   OwnershipTests(test_name)])
        outcome = unittest.TestResult()
        with mock.patch.object(module, 'owned', mutant):
            suite.run(outcome)
        detected = (outcome.testsRun == 2 and not outcome.errors and bool(outcome.failures) and
                    all(test_name in failed.id() for failed, _ in outcome.failures))
        results.append({'mutation': name, 'detected': detected, 'errors': len(outcome.errors),
                        'failures': len(outcome.failures)})
    after = hashlib.sha256(path.read_bytes()).hexdigest()
    return {'schema_version': 1, 'mutations': results, 'source_before': before, 'source_after': after,
            'status': 'PASS' if before == after and all(r['detected'] for r in results) else 'FAIL'}


class SafetyMutationTests(unittest.TestCase):
    def test_actual_ownership_guard_mutations_are_detected(self):
        result = safety_mutations()
        self.assertEqual(result['status'], 'PASS', result)

    def test_emulator_shield_mutation_is_detected(self):
        path = Path(emulator_adb_guard.__file__)
        before = hashlib.sha256(path.read_bytes()).hexdigest()
        mutant = types.ModuleType('emulator_adb_guard_mutant')
        mutant.__file__ = str(path)
        source = path.read_text().replace("if args == ['version']:", 'if True:')
        exec(compile(source, str(path), 'exec'), mutant.__dict__)
        suite = unittest.TestSuite([ProbeTests('test_emulator_shield_version_query_is_host_only'),
                                   ProbeTests('test_emulator_internal_unscoped_and_scoped_mutations_are_never_forwarded')])
        outcome = unittest.TestResult()
        with mock.patch.object(sys.modules[__name__], 'emulator_adb_guard', mutant):
            suite.run(outcome)
        self.assertEqual(outcome.testsRun, 2)
        self.assertFalse(outcome.errors)
        self.assertEqual(len(outcome.failures), 1)
        self.assertIn('test_emulator_internal_unscoped', outcome.failures[0][0].id())
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), before)
