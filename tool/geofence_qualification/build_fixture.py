#!/usr/bin/env python3
"""Offline build of the opt-in debug fixture and delegating instrumentation."""

import json
import hashlib
import os
import re
import subprocess
from pathlib import Path

from geofence_qualification.build_observer import ROOT, sha, source_identity
from geofence_qualification.owned_avd import image_spec


def build_fixture(output):
    output = Path(output).resolve()
    output.mkdir(mode=0o700)
    source = source_identity()
    (output / 'source-tree.json').write_text(json.dumps(source, sort_keys=True, indent=2) + '\n')
    key = output / 'fixture-test.keystore'
    subprocess.run(['keytool', '-genkeypair', '-keystore', str(key), '-storepass', 'android',
                    '-keypass', 'android', '-alias', 'qualification', '-keyalg', 'RSA',
                    '-keysize', '2048', '-validity', '2', '-dname', 'CN=Synthetic Geofence Fixture'],
                   capture_output=True, check=True, timeout=60)
    key.chmod(0o600)
    wrapper = (ROOT / 'android/gradle/wrapper/gradle-wrapper.properties').read_text()
    version, variant = re.search(r'gradle-([0-9.]+)-(all|bin)\.zip', wrapper).groups()
    cache = Path(os.environ.get('GRADLE_USER_HOME', str(Path.home() / '.gradle')))
    gradles = list((cache / f'wrapper/dists/gradle-{version}-{variant}').glob(f'*/gradle-{version}/bin/gradle'))
    if len(gradles) != 1:
        raise RuntimeError('CACHED_GRADLE_UNAVAILABLE')
    command = [str(gradles[0]), '-p', str(ROOT / 'android'), '--offline', '--no-daemon',
               '--max-workers=2', '-Pandroid.builder.sdkDownload=false',
               '-Ptarget=integration_test/geofence_fixture.dart', f'-Ptarget-platform={image_spec()[2]}',
               '-PqualificationFixture=true', f'-PqualificationKeystore={key}',
               ':app:assembleDebug', ':app:assembleDebugAndroidTest', ':app:lintDebug']
    with (output / 'build.log').open('x') as log:
        completed = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=600)
    if completed.returncode:
        raise RuntimeError('FIXTURE_BUILD_FAILED')
    signer = Path(os.environ['ANDROID_HOME']) / 'build-tools/36.0.0/apksigner'
    artifacts = {}
    for name, relative in [('fixture', 'apk/debug/app-debug.apk'),
                           ('instrumentation', 'apk/androidTest/debug/app-debug-androidTest.apk')]:
        source_apk = ROOT / 'build/app/outputs' / relative
        artifact = output / f'{name}.apk'
        artifact.write_bytes(source_apk.read_bytes())
        cert = subprocess.run([signer, 'verify', '--print-certs', artifact], capture_output=True,
                              text=True, check=True, timeout=30).stdout
        certificate = re.search(r'^Signer #1 certificate SHA-256 digest: ([a-fA-F0-9]{64})$', cert, re.M)
        if not certificate:
            raise RuntimeError('FIXTURE_CERTIFICATE_UNAVAILABLE')
        artifacts[name] = {'artifact_sha256': sha(artifact), 'signing_cert_sha256': certificate[1].lower()}
    manifest = subprocess.run([Path(os.environ['ANDROID_HOME']) / 'build-tools/36.0.0/aapt2',
                               'dump', 'xmltree', output / 'fixture.apk', '--file', 'AndroidManifest.xml'],
                              capture_output=True, text=True, check=True, timeout=30).stdout
    (output / 'manifest.txt').write_text(manifest)
    if 'com.google.firebase.provider.FirebaseInitProvider' in manifest or 'firebase_crashlytics_collection_enabled' not in manifest:
        raise RuntimeError('FIXTURE_FIREBASE_ISOLATION_MISSING')
    if source_identity() != source:
        raise RuntimeError('SOURCE_CHANGED_DURING_BUILD')
    if artifacts['fixture']['signing_cert_sha256'] != artifacts['instrumentation']['signing_cert_sha256']:
        raise RuntimeError('INSTRUMENTATION_CERTIFICATE_MISMATCH')
    result = {'schema_version': 1, 'scope': 'debug-synthetic-fixture', 'shipping_artifact': False,
              'entrypoint': 'integration_test/geofence_fixture.dart', 'command': command,
              'head': source['head'], 'tracked_patch_sha256': source['tracked_patch_sha256'],
              'working_tree_sha256': source['working_tree_sha256'], 'artifacts': artifacts,
              'config_sha256': hashlib.sha256(json.dumps(command).encode()).hexdigest()}
    (output / 'build-result.json').write_text(json.dumps(result, sort_keys=True, indent=2) + '\n')
    return output / 'fixture.apk', output / 'instrumentation.apk', result
