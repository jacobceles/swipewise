#!/usr/bin/env python3
"""Build only the standalone test observer, offline, with a new disposable certificate."""

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PROJECT = Path(__file__).resolve().parent / 'observer'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def source_identity():
    def git(*args):
        return subprocess.run(['git', *args], cwd=ROOT, capture_output=True, check=True).stdout
    paths = git('ls-files', '-z').split(b'\0') + git('ls-files', '--others', '--exclude-standard', '-z').split(b'\0')
    files = {}
    for raw in paths:
        if not raw:
            continue
        path = ROOT / os.fsdecode(raw)
        if path.is_file() and not path.is_symlink():
            files[os.fsdecode(raw)] = {'sha256': sha(path), 'mode': stat.S_IMODE(path.stat().st_mode)}
    tree = json.dumps(files, sort_keys=True, separators=(',', ':')).encode()
    return {'head': git('rev-parse', 'HEAD').decode().strip(),
            'tracked_patch_sha256': hashlib.sha256(git('diff', '--binary', 'HEAD', '--no-ext-diff')).hexdigest(),
            'working_tree_sha256': hashlib.sha256(tree).hexdigest(), 'files': files}


def build(output):
    output = Path(output).resolve()
    output.mkdir(mode=0o700)
    source = source_identity()
    (output / 'source-tree.json').write_text(json.dumps(source, indent=2, sort_keys=True) + '\n')
    keystore = output / 'observer-test.keystore'
    # Standard disposable test-only password; no owner or release signing material.
    key = ['keytool', '-genkeypair', '-keystore', str(keystore), '-storepass', 'android',
           '-keypass', 'android', '-alias', 'qualification', '-keyalg', 'RSA', '-keysize', '2048',
           '-validity', '2', '-dname', 'CN=Qualification Observer Test Only']
    subprocess.run(key, capture_output=True, text=True, check=True, timeout=60)
    keystore.chmod(0o600)
    # Fresh worktrees need not have Flutter's generated gradlew. Use only the
    # already cached distribution pinned by this repository, never download it.
    wrapper = (ROOT / 'android/gradle/wrapper/gradle-wrapper.properties').read_text()
    match = re.search(r'gradle-([0-9.]+)-(all|bin)\.zip', wrapper)
    if not match:
        raise RuntimeError('PINNED_GRADLE_UNAVAILABLE')
    version, variant = match.groups()
    cache = Path(os.environ.get('GRADLE_USER_HOME', str(Path.home() / '.gradle')))
    distributions = list((cache / f'wrapper/dists/gradle-{version}-{variant}').glob(f'*/gradle-{version}/bin/gradle'))
    if len(distributions) != 1:
        raise RuntimeError('CACHED_GRADLE_UNAVAILABLE')
    command = [str(distributions[0]), '-p', str(PROJECT), '--offline', '--no-daemon',
               '--max-workers=2', '-Pandroid.builder.sdkDownload=false',
               f'-PobserverKeystore={keystore}', 'assembleDebug', 'lintDebug']
    with (output / 'build.log').open('x') as log:
        completed = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                   text=True, timeout=300)
    if completed.returncode:
        raise RuntimeError('OBSERVER_BUILD_FAILED')
    apk = PROJECT / 'build/outputs/apk/debug/observer-debug.apk'
    if not apk.is_file():
        # AGP uses the root project name for a root-module APK.
        apks = list((PROJECT / 'build/outputs/apk/debug').glob('*.apk'))
        if len(apks) != 1:
            raise RuntimeError('OBSERVER_APK_UNAVAILABLE')
        apk = apks[0]
    artifact = output / 'observer.apk'
    artifact.write_bytes(apk.read_bytes())
    sdk = Path(os.environ['ANDROID_HOME'])
    signer = sdk / 'build-tools/36.0.0/apksigner'
    cert = subprocess.run([signer, 'verify', '--print-certs', artifact], capture_output=True,
                          text=True, check=True, timeout=30).stdout
    (output / 'certificate.txt').write_text(cert)
    certificate = re.search(r'^Signer #1 certificate SHA-256 digest: ([a-fA-F0-9]{64})$', cert, re.M)
    if not certificate:
        raise RuntimeError('OBSERVER_CERTIFICATE_UNAVAILABLE')
    if source_identity() != source:
        raise RuntimeError('SOURCE_CHANGED_DURING_BUILD')
    manifest = {'schema_version': 1, 'scope': 'standalone-test-observer', 'status': 'PASS',
                'artifact_sha256': sha(artifact), 'certificate_evidence_sha256': sha(output / 'certificate.txt'),
                'signing_cert_sha256': certificate[1].lower(),
                'head': source['head'], 'tracked_patch_sha256': source['tracked_patch_sha256'],
                'working_tree_sha256': source['working_tree_sha256'], 'command': command,
                'config_sha256': hashlib.sha256(json.dumps(command).encode()).hexdigest(),
                'package': 'com.appsoflife.swipewise.qualification.observer',
                'shipping_artifact': False, 'disposable_signing_key': True}
    (output / 'build-result.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    return artifact, manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='New output directory')
    args = parser.parse_args()
    apk, _ = build(args.output)
    print(f'Standalone observer built: {apk}')
