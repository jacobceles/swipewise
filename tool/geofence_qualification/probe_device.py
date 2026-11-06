#!/usr/bin/env python3
"""Execute one bounded, run-owned console-GPS/FLP/GMS capability probe.

This helper is not the SwipeWise fixture or its notification qualification. A
successful capability probe still exits 3 (NOT-COVERED for app qualification).
There is no serial/manifest/AVD resume argument and no owner-device code path.
"""

import argparse
import hashlib
import json
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import play_gpx_route as player  # noqa: E402
from geofence_qualification.build_observer import build, sha  # noqa: E402
from geofence_qualification.owned_avd import InfrastructureError, new_owned_avd  # noqa: E402

PACKAGE = 'com.appsoflife.swipewise.qualification.observer'
LAT, LON = 39.237148, -123.176090


def trace_events(text, run_id):
    if len(text) > 256 * 1024:
        raise InfrastructureError('OBSERVER_TRACE_TOO_LARGE')
    events = []
    for line in text.splitlines():
        event = json.loads(line)
        if (event.get('schema_version') != 1 or event.get('run_id') != run_id or
                type(event.get('seq')) is not int or event['seq'] != len(events) or
                type(event.get('elapsed_ns')) is not int or
                (events and event['elapsed_ns'] < events[-1]['elapsed_ns'])):
            raise InfrastructureError('OBSERVER_TRACE_IDENTITY_OR_SEQUENCE')
        events.append(event)
    return events


def read_events(owner):
    text = owner.run_adb(['exec-out', 'run-as', PACKAGE, 'cat', 'files/observations.jsonl'])
    events = trace_events(text, owner.run_id)
    (owner.evidence / 'helper-observations.jsonl').write_text(text + '\n')
    return events


def wait_events(owner, predicate, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            events = read_events(owner)
        except json.JSONDecodeError:
            # One concurrently appended final line may still be in flight. No
            # permanent parse failure/empty collection can satisfy the predicate.
            time.sleep(0.2)
            continue
        if predicate(events):
            return events
        time.sleep(1)
    return read_events(owner)


def has(events, stage):
    return any(event['stage'] == stage for event in events)


def start_activity(owner, mode):
    output = owner.run_adb(['shell', 'am', 'start', '-W', '-n', f'{PACKAGE}/.ProbeActivity',
                            '--es', 'run_id', owner.run_id, '--es', 'mode', mode])
    if not re.search(r'^Status: ok$', output, re.M):
        raise InfrastructureError('ACTIVITY_START_NOT_CONFIRMED')


def static_route(owner, name, lat, lon):
    # Two static samples are a capability stimulus, NOT an approach trajectory
    # or motion-classification claim. W3 alone parses/schedules/formats/sends.
    path = owner.evidence / f'{name}.gpx'
    path.write_text(f'<gpx><trk><trkseg>'
                    f'<trkpt lat="{lat}" lon="{lon}"><time>2020-01-01T00:00:00Z</time></trkpt>'
                    f'<trkpt lat="{lat}" lon="{lon}"><time>2020-01-01T00:00:02Z</time></trkpt>'
                    f'</trkseg></trk></gpx>')
    points = player.parse_gpx(path)
    player.replay_route(points, owner.serial, 'fix', sender=owner.send_location)
    return {'sha256': sha(path), 'nominal_speed_mps': 0.0, 'commanded_accuracy_m': None,
            'kind': 'static-coordinate capability stimulus, not walking/AR policy'}


def observed_fix(events, stage, lat, lon):
    samples = [event['data'] for event in events if event['stage'] == stage]
    return next((sample for sample in samples if sample.get('available') is True and
                 abs(sample['lat'] - lat) <= 0.00003 and abs(sample['lon'] - lon) <= 0.00003 and
                 0 <= sample['age_ms'] <= 15_000 and sample['elapsed_realtime_ns'] > 0), None)


def listener_continuous(events, after_seq):
    snapshots = [event for event in events if event['stage'] == 'listener_snapshot' and
                 event['seq'] > after_seq]
    return bool(snapshots and snapshots[-1]['data'].get('connected') is True and
                sum(event['stage'] == 'listener_connected' for event in events) == 1 and
                not has(events, 'listener_disconnected'))


def probe(owner, apk, result):
    if not owner.process or owner.process.poll() is not None:
        owner.start()
    else:
        owner.guard()  # Only an already-live in-memory owner, never a saved manifest.
    result['environment'] = {
        'image': 'system-images;android-36.1;google_apis;arm64-v8a',
        'image_properties_sha256': sha(owner.sdk / 'system-images/android-36.1/google_apis/arm64-v8a/source.properties'),
        'android_fingerprint': owner.run_adb(['shell', 'getprop', 'ro.build.fingerprint']),
        'android_abi': owner.run_adb(['shell', 'getprop', 'ro.product.cpu.abi']),
        'adb_client_sha256': sha(owner.adb),
        'adb_version': owner.run_adb(['version']),
    }
    gms = owner.run_adb(['shell', 'dumpsys', 'package', 'com.google.android.gms'])
    versions = re.findall(r'\bversionName=([^\s]+)', gms)
    if not versions:
        raise InfrastructureError('GMS_VERSION_UNAVAILABLE')
    result['environment']['gms_version'] = versions[0]
    installed = owner.run_adb(['install', '--no-incremental', '-t', str(apk)], timeout=60)
    if 'Success' not in installed.splitlines():
        raise InfrastructureError('OBSERVER_INSTALL_NOT_CONFIRMED')
    package_path = owner.run_adb(['shell', 'pm', 'path', PACKAGE])
    if not re.fullmatch(r'package:/data/app/[^\s]+/base\.apk', package_path):
        raise InfrastructureError('INSTALLED_OBSERVER_PATH_UNAVAILABLE')
    installed_hash = owner.run_adb(['shell', 'sha256sum', package_path.removeprefix('package:')]).split()[0]
    if installed_hash != sha(apk):
        raise InfrastructureError('INSTALLED_OBSERVER_HASH_MISMATCH')
    result['local_artifact_readback_matches'] = True
    for permission in ('ACCESS_COARSE_LOCATION', 'ACCESS_FINE_LOCATION', 'ACCESS_BACKGROUND_LOCATION'):
        owner.run_adb(['shell', 'pm', 'grant', PACKAGE, f'android.permission.{permission}'])
    owner.run_adb(['shell', 'cmd', 'location', 'set-location-enabled', 'true'])
    if owner.run_adb(['shell', 'cmd', 'location', 'is-location-enabled']) != 'true':
        raise InfrastructureError('LOCATION_SETTING_UNAVAILABLE')
    start_activity(owner, 'init')
    owner.run_adb(['shell', 'cmd', 'notification', 'allow_listener', f'{PACKAGE}/.ArrivalListener'])
    def listener_ready(items):
        return has(items, 'listener_connected') or any(
            event['stage'] == 'listener_snapshot' and event['data'].get('connected') is True
            for event in items)
    events = wait_events(owner, listener_ready, 20)
    if not listener_ready(events):
        raise InfrastructureError('NOTIFICATION_LISTENER_NOT_CONNECTED')
    start_activity(owner, 'observe')
    result['outside_input'] = static_route(owner, 'outside-static', LAT - 0.003, LON)
    events = wait_events(owner, lambda e: has(e, 'location_observers_stopped'), 25)
    gps = observed_fix(events, 'gps_sample', LAT - 0.003, LON)
    flp = observed_fix(events, 'flp_sample', LAT - 0.003, LON)
    result['observed_gps'] = gps
    result['observed_flp'] = flp
    result['location_observers_stopped'] = has(events, 'location_observers_stopped')
    if not result['location_observers_stopped']:
        raise InfrastructureError('LOCATION_OBSERVER_COMPLETION_UNAVAILABLE')
    # Even if FLP was absent, record the actual GMS add outcome instead of
    # guessing that GMS must be unavailable or treating stored metadata as proof.
    start_activity(owner, 'gms-add')
    events = wait_events(owner, lambda e: has(e, 'gms_add_success') or has(e, 'gms_add_failure'), 35)
    result['gms_add_success'] = has(events, 'gms_add_success')
    if result['gms_add_success']:
        result['inside_input'] = static_route(owner, 'inside-static', LAT, LON)
        def entered(items):
            return any(item['stage'] == 'gms_transition' and item['data']['has_error'] is False and
                       item['data']['transition'] == 1 and item['data']['request_ids'] == [owner.run_id]
                       for item in items)
        events = wait_events(owner, entered, 120)
        result['gms_enter_observed'] = entered(events)
    else:
        result['gms_enter_observed'] = False
    end_after_seq = events[-1]['seq'] if events else -1
    start_activity(owner, 'snapshot')
    events = read_events(owner)
    listener = listener_continuous(events, end_after_seq)
    result['listener_continuity_observed'] = bool(listener)
    result['observed_stages'] = [{'stage': e['stage'], 'elapsed_ns': e['elapsed_ns']} for e in events]
    missing = []
    for code, present in [('GPS_CONSOLE_SAMPLE', gps), ('FLP_CONSOLE_SAMPLE', flp),
                          ('SUCCESSFUL_GMS_ADD', result['gms_add_success']),
                          ('GMS_ENTER_WITHIN_120S', result['gms_enter_observed']),
                          ('LISTENER_CONTINUITY', listener)]:
        if not present:
            missing.append(code)
    result['capability_status'] = 'PASS' if not missing else 'INFRASTRUCTURE-BLOCKED'
    result['status'] = 'NOT-COVERED' if not missing else 'INFRASTRUCTURE-BLOCKED'
    result['reasons'] = missing or ['MAIN_FIXTURE_DEFAULT_DWELL_AND_ANDROID_POST_NOT_YET_COVERED']


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args(argv)  # No arbitrary serial, AVD, PID or existing manifest arguments.
    owner = new_owned_avd()
    print(f'Run-owned evidence: {owner.evidence}', flush=True)
    result = {'schema_version': 1, 'scope': 'run-owned-capability', 'run_id': owner.run_id,
              'status': 'INFRASTRUCTURE-BLOCKED', 'capability_status': 'INFRASTRUCTURE-BLOCKED',
              'input_source': 'emulator-console-gps', 'shipping_artifact': False,
              'started_at_unix_ms': time.time_ns() // 1_000_000, 'reasons': []}
    try:
        apk, artifact = build(owner.evidence / 'observer-build')
        result['observer_build'] = artifact
        probe(owner, apk, result)
    except KeyboardInterrupt:
        result['reasons'] = ['CANCELLED']
    except (InfrastructureError, OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        result['reasons'] = [str(error) if isinstance(error, (InfrastructureError, RuntimeError))
                             else type(error).__name__]
    finally:
        try:
            if owner.process and owner.process.poll() is None and owner.transport_id:
                try:
                    read_events(owner)
                    pid = owner.run_adb(['shell', 'pidof', PACKAGE])
                    if re.fullmatch(r'\d+', pid):
                        log = owner.run_adb(['logcat', '-d', '--pid', pid, '-t', '300'])
                        (owner.evidence / 'observer-logcat.txt').write_text(log + '\n')
                except (InfrastructureError, OSError, ValueError, subprocess.SubprocessError):
                    result['failure_capture'] = 'PARTIAL_OR_UNAVAILABLE'
            owner.close()
            result['cleanup'] = ('OWNED_PROCESS_STOPPED_AVD_FILES_RETAINED' if owner.process
                                 else 'NO_EMULATOR_CREATED')
        except (InfrastructureError, OSError, subprocess.SubprocessError) as error:
            result.update(status='INFRASTRUCTURE-BLOCKED', cleanup='REFUSED_OR_INCOMPLETE',
                          cleanup_error=type(error).__name__)
        result['finished_at_unix_ms'] = time.time_ns() // 1_000_000
        result['evidence'] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                              for p in owner.evidence.iterdir() if p.is_file() and p.name != 'result.json'
                              and p.suffix in ('.json', '.jsonl', '.txt', '.log', '.gpx')}
        (owner.evidence / 'result.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    print(f"{result['status']}: {', '.join(result['reasons'])}", flush=True)
    return 3 if result['status'] == 'NOT-COVERED' else 2


if __name__ == '__main__':
    sys.exit(main())
