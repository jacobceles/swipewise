#!/usr/bin/env python3
"""One NEW owned AVD: real GMS -> normal default dwell -> muted/no-post and post.

No arbitrary serial, saved manifest, existing AVD or injected receiver lane.
Private evidence stays outside the checkout; --output is a sanitized CI summary.
"""

import argparse
import base64
import hashlib
import json
import math
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import play_gpx_route as player  # noqa: E402
from geofence_qualification.build_fixture import build_fixture  # noqa: E402
from geofence_qualification.build_observer import ROOT, build, sha, source_identity  # noqa: E402
from geofence_qualification.owned_avd import InfrastructureError, new_owned_avd  # noqa: E402
from geofence_qualification import probe_device as probe  # noqa: E402

PACKAGE = 'com.appsoflife.swipewise.dev'
FENCE = 'm_qualification-restaurant-v1'
LAT, LON = probe.LAT, probe.LON
DWELL_SECONDS = 30
# Actual default's attempt life + overdue grace + acquisition + observer margin.
WINDOW_NS = ((2 * DWELL_SECONDS + 120) + 30 + 8 + 5) * 1_000_000_000


class SmokeFailure(RuntimeError):
    pass


def require(value, code):
    if not value:
        raise SmokeFailure(code)


def read_native(owner):
    text = owner.run_adb(['shell', f"run-as {PACKAGE} sh -c 'if [ -f files/qualification.jsonl ]; "
                         "then cat files/qualification.jsonl; fi'"])
    events = probe.trace_events(text, owner.run_id)
    (owner.evidence / 'native-observations.jsonl').write_text(text + '\n')
    require(not any(e['stage'] in ('fixture_error', 'native_error', 'instrumentation_timeout') for e in events),
            'FIXTURE_OR_NATIVE_FAILURE')
    return events


def wait_native(owner, predicate, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            events = read_native(owner)
        except json.JSONDecodeError:
            time.sleep(0.2)
            continue
        if predicate(events):
            return events
        time.sleep(1)
    raise InfrastructureError('NATIVE_STAGE_TIMEOUT')


def command_fixture(owner, seq, action):
    data = base64.b64encode(json.dumps({'run_id': owner.run_id, 'seq': seq, 'action': action}).encode()).decode()
    # Fixed file names + base64 alphabet; atomic rename avoids partially read JSON.
    script = (f'echo {data} | base64 -d > files/qualification-command.tmp && '
              'mv files/qualification-command.tmp files/qualification-command.json')
    owner.run_adb(['shell', f"run-as {PACKAGE} sh -c '{script}'"])


def install(owner, apk, package):
    result = owner.run_adb(['install', '--no-incremental', '-t', str(apk)], timeout=90)
    require('Success' in result.splitlines(), 'APK_INSTALL_UNCONFIRMED')
    path = owner.run_adb(['shell', 'pm', 'path', package])
    require(re.fullmatch(r'package:/data/app/[^\s]+/base\.apk', path), 'INSTALLED_PATH_UNAVAILABLE')
    digest = owner.run_adb(['shell', 'sha256sum', path.removeprefix('package:')]).split()[0]
    require(digest == sha(apk), 'INSTALLED_APK_HASH_MISMATCH')
    return digest


def static(owner, name, lat, lon, duration):
    duration = max(4, math.ceil(duration / 4) * 4)
    path = owner.evidence / f'{name}.gpx'
    require(not path.exists(), 'ROUTE_ALREADY_EXISTS')
    # Static coordinate stimulus, not walking or a claim about real sensor AR.
    # W3 is the sole parser, motion formatter, scheduler and guarded sender.
    import datetime
    start = datetime.datetime(2020, 1, 1, tzinfo=datetime.timezone.utc)
    points = ''.join(f'<trkpt lat="{lat}" lon="{lon}"><time>'
                     f'{(start + datetime.timedelta(seconds=t)).isoformat()}</time></trkpt>'
                     for t in range(0, duration + 1, 4))
    path.write_text(f'<gpx><trk><trkseg>{points}</trkseg></trk></gpx>')
    replay = player.parse_gpx(path)
    at = time.monotonic_ns()
    player.replay_route(replay, owner.serial, 'fix', sender=owner.send_location)
    record = {'file': path.name, 'sha256': sha(path), 'points_sent': len(replay),
              'duration_s': duration, 'host_start_ns': at, 'host_end_ns': time.monotonic_ns(),
              'nominal_speed_mps': 0.0, 'commanded_accuracy_m': None, 'completed': True}
    require(record['host_end_ns'] - at >= duration * 1_000_000_000, 'INCOMPLETE_REPLAY')
    (owner.evidence / f'{name}-replay.json').write_text(json.dumps(record, indent=2) + '\n')
    return record


def capture_state(owner, label):
    # Only this synthetic AVD. Raw dumps are private and never CI uploads.
    for kind in ('location', 'activity broadcasts', 'alarm'):
        try:
            output = owner.run_adb(['shell', 'dumpsys', *kind.split()], timeout=30)
            (owner.evidence / f'{label}-{kind.replace(" ", "-")}.txt').write_text(output + '\n')
        except Exception as e:
            (owner.evidence / f'{label}-{kind.replace(" ", "-")}.txt').write_text(f'DUMP_FAILED: {e}\n')
    try:
        output = owner.run_adb(['logcat', '-d', '-t', '2000'], timeout=30)
        (owner.evidence / f'{label}-logcat.txt').write_text(output + '\n')
    except Exception as e:
        (owner.evidence / f'{label}-logcat.txt').write_text(f'LOGCAT_FAILED: {e}\n')


def arms(events, since):
    return [e for e in events if e['stage'] == 'attempts' and e['elapsed_ns'] > since and
            FENCE in e['data'] and e['data'][FENCE]['phase'] == 'ARMED']


def episode(native, listener, since, baseline_seq, end_seq, muted):
    """Raw, ordered, run-bound collector evidence; no missing-stage no-post pass."""
    require(native and listener, 'EMPTY_OBSERVATIONS')
    items = [e for e in native if e['elapsed_ns'] > since]
    seed = [e for e in items if e['stage'] == 'seed_readback']
    require(len(seed) == 1, 'SEED_READBACK_MISSING_OR_DUPLICATED')
    data = seed[0]['data']
    require(data == {'action': 'seed-muted' if muted else 'unmute-register',
                     'wallet_count': 2, 'dwell_seconds': DWELL_SECONDS, 'card_name': 'Qualification Dining',
                     'rate': 3.0, 'currency': 'USD', 'muted': muted,
                     'cache_current_complete': True, 'remote_search_calls': 0,
                     'remote_catalog_disabled': True}, 'NORMAL_RANKING_OR_SEED')
    payloads = [e for e in items if e['stage'] == 'ranking_payload']
    require(len(payloads) == 1 and len(payloads[0]['data']['zones']) == 1, 'RANKING_PAYLOAD')
    zone = payloads[0]['data']['zones'][0]
    require(zone['geofence_id'] == FENCE and zone['dwell_seconds'] == DWELL_SECONDS and
            zone['lat'] == LAT and zone['lng'] == LON and zone['radius_m'] == 100 and
            len(zone['options']) == 1 and zone['options'][0]['best_card_name'] == 'Qualification Dining' and
            zone['options'][0]['best_rate'] == 3 and zone['options'][0]['best_currency'] == 'USD' and
            zone['options'][0].get('muted', False) is muted, 'NORMAL_MANAGER_PAYLOAD')
    results = [e for e in items if e['stage'] == 'register_result']
    require(len(results) == 1 and results[0]['data']['count'] == 1 and
            results[0]['data']['diagnostics'].count('REGISTRATION_OK value=1') == (1 if muted else 2),
            'ACTUAL_GMS_TASK_COMPLETION')
    armed = arms(items, since)
    require(len(armed) == 1, 'NO_UNIQUE_REAL_ENTER_ARM')
    arm = armed[0]
    attempt = arm['data'][FENCE]
    require(type(attempt['token']) is int and -(1 << 63) <= attempt['token'] < (1 << 63) and
            attempt['token'] != 0, 'SIGNED_ATTEMPT_TOKEN')
    require(attempt['scheduledDueElapsedNanos'] - attempt['createdAtElapsedNanos'] == DWELL_SECONDS * 1_000_000_000 and
            attempt['deadlineElapsedNanos'] - attempt['createdAtElapsedNanos'] == (DWELL_SECONDS * 2 + 120) * 1_000_000_000 and
            attempt['accountEpoch'] == payloads[0]['data']['account_epoch'] and
            attempt['metadataGeneration'] >= 1 and attempt['bootCount'] >= 0,
            'NORMAL_DWELL_OR_ATTEMPT_IDENTITY')
    requests = [e for e in items if e['stage'] == 'verification_request']
    samples = [e for e in items if e['stage'] == 'verification_sample']
    require(len(requests) == len(samples) == 1, 'DEFAULT_VERIFICATION_MISSING_OR_RECHECK')
    req, verification = requests[0], samples[0]
    require(req['data']['delegate'] == 'DefaultLocationProvider' and req['data']['priority'] == 102 and
            req['data']['duration_ms'] == 8000 and req['data']['max_age_ms'] == 15000 and
            req['data']['attempts'][FENCE]['token'] == attempt['token'] and
            verification['data']['attempts'][FENCE]['token'] == attempt['token'], 'DEFAULT_BALANCED_VERIFIER')
    fix = verification['data']['sample']
    require(fix.get('available') is True and fix['provider'] == 'fused' and fix['is_mock'] is False and
            0 <= fix['observed_elapsed_ns'] - fix['elapsed_realtime_ns'] <= 15_000_000_000 and
            0 < fix['accuracy_m'] <= 50 and (fix['speed_mps'] is None or 0 <= fix['speed_mps'] <= 2),
            'PRECISE_CONSOLE_FLP_VERIFICATION')
    distance = math.hypot(math.radians(fix['lat'] - LAT) * 6371000,
                          math.radians(fix['lon'] - LON) * 6371000 * math.cos(math.radians(LAT)))
    require(distance <= 100 and req['elapsed_ns'] >= attempt['scheduledDueElapsedNanos'] - 1_000_000_000,
            'PREMATURE_OR_OUTSIDE_VERIFICATION')
    logs = [e['data']['text'] for e in items if e['stage'] == 'walkin']
    require(logs, 'NATIVE_LOG_MISSING')
    log = logs[-1]
    require(f'fence ENTER {FENCE} acc=' in log and
            'verdict=VERIFIED, outcome=POSTED' in log, 'REAL_ENTER_OR_PRECISE_DECISION_MISSING')
    require(log.count(f'fence ENTER {FENCE} acc=') == (1 if muted else 2), 'REAL_ENTER_COUNT')
    outcome = 'MUTED' if muted else 'POSTED'
    require(f'dwell {FENCE}: {outcome.lower()} Qualification Restaurant' in log, 'TERMINAL_OUTCOME_MISSING')
    diagnostics = [e['data']['text'] for e in items if e['stage'] == 'diagnostics']
    require(diagnostics and diagnostics[-1].splitlines()[-1].endswith(f'OUTCOME_{outcome}'),
            'TERMINAL_DIAGNOSTIC_MISMATCH')
    poster = [e for e in items if e['stage'] == 'poster_call']
    returned = [e for e in items if e['stage'] == 'poster_result']
    require(len(poster) == len(returned) == (0 if muted else 1), 'NATIVE_POSTER_COUNT')
    if not muted:
        require(poster[0]['data']['approximate'] is False and
                poster[0]['data']['fence'] == FENCE and
                poster[0]['data']['attempts'][FENCE]['token'] == attempt['token'] and
                returned[0]['data']['submitted'] is True, 'ACTUAL_NATIVE_SUBMISSION')
    require(seed[0]['seq'] < payloads[0]['seq'] < results[0]['seq'] < arm['seq'] < req['seq'] < verification['seq'],
            'CAUSAL_STAGE_ORDER')
    require(sum(e['stage'] == 'listener_connected' for e in listener) == 1 and
            not any(e['stage'] == 'listener_disconnected' for e in listener), 'LISTENER_GAP')
    baseline = listener[baseline_seq]
    end = listener[end_seq]
    require(baseline['stage'] == end['stage'] == 'listener_snapshot' and
            baseline['data'] == {'connected': True, 'active': []} and
            baseline['elapsed_ns'] < seed[0]['elapsed_ns'] and
            end['data']['connected'] is True and
            end['elapsed_ns'] >= attempt['createdAtElapsedNanos'] + WINDOW_NS,
            'BASELINE_OR_COMPLETE_WINDOW')
    require(any(e['stage'] == 'heartbeat' and 0 <= end['elapsed_ns'] - e['elapsed_ns'] <= 12_000_000_000
                for e in items), 'NATIVE_OBSERVER_GAP_AT_END')
    observed = [e for e in listener[baseline_seq + 1:end_seq] if e['stage'] in ('listener_post', 'listener_remove')]
    require(len(observed) == (0 if muted else 1), 'ANDROID_NOTIFICATION_EVENT_COUNT')
    if not muted:
        post = observed[0]
        item = post['data'].get('notification', {})
        require(post['stage'] == 'listener_post' and post['data']['change'] == 'post' and
                {k: item.get(k) for k in ('package', 'channel', 'tag', 'id', 'title', 'text', 'big_text')} ==
                {'package': PACKAGE, 'channel': 'swipewise_dwell', 'tag': 'swipewise.arrival', 'id': 0,
                 'title': "You're near Qualification Restaurant", 'text': 'Use Qualification Dining for 3%',
                 'big_text': 'Use Qualification Dining for 3%'} and
                len(end['data']['active']) == 1 and
                end['data']['active'][0]['key'] == item['key'], 'CORRECT_ANDROID_NOTIFICATION')
    else:
        require(end['data']['active'] == [], 'NEGATIVE_ACTIVE_NOTIFICATION')
    require(any(e['stage'] == 'attempts' and e['data'] == {} and
                e['elapsed_ns'] > verification['elapsed_ns'] for e in items), 'ATTEMPT_NOT_CLEARED')
    return {'status': 'PASS', 'terminal': outcome, 'native_poster_calls': len(poster),
            'android_post_callbacks': len(observed), 'observation_after_arm_ms':
            (end['elapsed_ns'] - attempt['createdAtElapsedNanos']) // 1_000_000,
            'verification_fix_age_ms': (fix['observed_elapsed_ns'] - fix['elapsed_realtime_ns']) // 1_000_000}


def snapshot(owner):
    before = probe.read_events(owner)
    count = sum(e['stage'] == 'listener_snapshot' for e in before)
    probe.start_activity(owner, 'snapshot')
    events = probe.wait_events(owner, lambda es: sum(e['stage'] == 'listener_snapshot' for e in es) > count, 15)
    snapshots = [e for e in events if e['stage'] == 'listener_snapshot']
    require(snapshots, 'SNAPSHOT_UNAVAILABLE')
    return events, snapshots[-1]['seq']


def run(owner, fixture_apk, instrumentation_apk, observer_apk, result):
    owner.start()
    result['environment'] = {'image': owner.image, 'abi': owner.abi,
                             'image_properties_sha256': sha(owner.sdk / f'system-images/android-36.1/google_apis/{owner.abi}/source.properties'),
                             'fingerprint': owner.run_adb(['shell', 'getprop', 'ro.build.fingerprint']),
                             'adb_sha256': sha(owner.adb)}
    gms = owner.run_adb(['shell', 'dumpsys', 'package', 'com.google.android.gms'])
    result['environment']['gms_version'] = re.findall(r'\bversionName=([^\s]+)', gms)[0]
    result['installed_readback'] = {
        'observer': install(owner, observer_apk, probe.PACKAGE),
        'fixture': install(owner, fixture_apk, PACKAGE),
        'instrumentation': install(owner, instrumentation_apk, PACKAGE + '.test')}
    for package in (probe.PACKAGE, PACKAGE):
        for permission in ('ACCESS_COARSE_LOCATION', 'ACCESS_FINE_LOCATION', 'ACCESS_BACKGROUND_LOCATION'):
            owner.run_adb(['shell', 'pm', 'grant', package, 'android.permission.' + permission])
    owner.run_adb(['shell', 'pm', 'grant', PACKAGE, 'android.permission.POST_NOTIFICATIONS'])
    owner.run_adb(['shell', 'appops', 'set', PACKAGE, 'SCHEDULE_EXACT_ALARM', 'allow'])
    owner.run_adb(['shell', 'cmd', 'location', 'set-location-enabled', 'true'])
    require(owner.run_adb(['shell', 'cmd', 'location', 'is-location-enabled']) == 'true', 'LOCATION_DISABLED')
    owner.run_adb(['shell', 'settings', 'put', 'secure', 'location_mode', '3'])
    owner.run_adb(['shell', 'su', '0', 'content', 'insert', '--uri', 'content://com.google.settings/partner',
                   '--bind', 'name:s:network_location_opt_in', '--bind', 'value:s:1'])
    owner.run_adb(['shell', 'su', '0', 'content', 'insert', '--uri', 'content://com.google.settings/partner',
                   '--bind', 'name:s:use_location_for_services', '--bind', 'value:s:1'])
    probe.start_activity(owner, 'init')
    owner.run_adb(['shell', 'cmd', 'notification', 'allow_listener', f'{probe.PACKAGE}/.ArrivalListener'])
    events = probe.wait_events(owner, lambda es: probe.has(es, 'listener_connected'), 20)
    require(probe.has(events, 'listener_connected'), 'LISTENER_NOT_CONNECTED')
    probe.start_activity(owner, 'observe')
    result['routes'] = [static(owner, 'outside-preflight', LAT - 0.003, LON, 4)]
    events = probe.wait_events(owner, lambda es: probe.has(es, 'location_observers_stopped'), 25)
    for stage in ('gps_sample', 'flp_sample'):
        require(probe.observed_fix(events, stage, LAT - 0.003, LON), f'MISSING_{stage.upper()}')
    settings_events = [e for e in events if e['stage'] == 'location_settings_status']
    require(settings_events and settings_events[0]['data'].get('status_code') == 0,
            'GMS_LOCATION_SETTINGS_UNSATISFIED')
    owner.run_adb(['shell', 'am', 'instrument', '-e', 'run_id', owner.run_id,
                   f'{PACKAGE}.test/com.appsoflife.swipewise.GeofenceSmokeInstrumentation'])
    native = wait_native(owner, lambda es: probe.has(es, 'fixture_ready'), 45)
    started = next(e['data'] for e in native if e['stage'] == 'instrumentation_started')
    require(started == {'exact_alarm_capable': True, 'firebase_initialized': False}, 'FIXTURE_PREREQUISITES')
    for index, (action, muted) in enumerate((('seed-muted', True), ('unmute-register', False))):
        if index:
            result['routes'].append(static(owner, 'outside-positive', LAT - 0.003, LON, 12))
        listener, baseline_seq = snapshot(owner)
        since = native[-1]['elapsed_ns']
        command_fixture(owner, index, action)
        native = wait_native(owner, lambda es: sum(e['stage'] == 'command_done' for e in es) > index, 60)
        result['routes'].append(static(owner, f'{action}-unassisted', LAT, LON, 120))
        native = read_native(owner)
        if not arms(native, since):
            capture_state(owner, f'{action}-no-enter-unassisted')
            if not result.get('companion_high_accuracy_demand'):
                probe.start_activity(owner, 'supply')
                result['companion_high_accuracy_demand'] = True
            result['routes'].append(static(owner, f'{action}-companion-demand', LAT, LON, 120))
            native = read_native(owner)
        armed = arms(native, since)
        if not armed:
            capture_state(owner, f'{action}-no-enter-with-demand')
            raise InfrastructureError('REAL_GMS_ADD_SUCCEEDED_BUT_NO_ENTER_WITHIN_BOUNDED_STIMULI')
        arm = armed[0]['data'][FENCE]
        now = native[-1]['elapsed_ns']
        remaining = (arm['createdAtElapsedNanos'] + WINDOW_NS - now) / 1e9 + 5
        if remaining > 0:
            result['routes'].append(static(owner, f'{action}-complete-window', LAT, LON, remaining))
        native = read_native(owner)
        listener, end_seq = snapshot(owner)
        result['muted_no_post' if muted else 'precise_post'] = episode(
            native, listener, since, baseline_seq, end_seq, muted)
        print(f'{action}: PASS', flush=True)
    command_fixture(owner, 2, 'stop')
    wait_native(owner, lambda es: probe.has(es, 'instrumentation_finished'), 15)
    if result.get('companion_high_accuracy_demand'):
        probe.start_activity(owner, 'stop-supply')
        probe.wait_events(owner, lambda es: probe.has(es, 'companion_demand_stopped'), 15)
    result.update(status='PASS', reasons=[], scope='debug-fixture-real-GMS-static-console-smoke')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='NEW sanitized summary file; parent must exist')
    args = parser.parse_args(argv)
    if args.output.exists() or not args.output.parent.is_dir():
        parser.error('output must be a new file in an existing directory')
    owner = new_owned_avd()
    print(f'Private run evidence: {owner.evidence}', flush=True)
    result = {'schema_version': 1, 'status': 'INFRASTRUCTURE-BLOCKED', 'scope': 'debug-fixture-real-GMS-smoke',
              'shipping_artifact': False, 'input_source': 'emulator-console-gps', 'run_id': owner.run_id,
              'started_at_unix_ms': time.time_ns() // 1_000_000, 'reasons': []}
    try:
        fixture, instrumentation, result['fixture_build'] = build_fixture(owner.evidence / 'fixture-build')
        observer, result['observer_build'] = build(owner.evidence / 'observer-build')
        result['source'] = {k: v for k, v in source_identity().items() if k != 'files'}
        result['classifier_sha256'] = hashlib.sha256(b''.join((ROOT / p).read_bytes() for p in
            ('assets/vocab/brands.json', 'assets/vocab/categories.json'))).hexdigest()
        result['seed_source_sha256'] = sha(ROOT / 'integration_test/geofence_fixture.dart')
        run(owner, fixture, instrumentation, observer, result)
        require({k: v for k, v in source_identity().items() if k != 'files'} == result['source'],
                'SOURCE_CHANGED_DURING_DEVICE_OBSERVATION')
    except KeyboardInterrupt:
        result['reasons'] = ['CANCELLED']
    except (InfrastructureError, SmokeFailure, RuntimeError, OSError, ValueError, subprocess.SubprocessError) as exc:
        result['status'] = 'FAIL' if isinstance(exc, SmokeFailure) else 'INFRASTRUCTURE-BLOCKED'
        result['reasons'] = [str(exc) if isinstance(exc, RuntimeError) else type(exc).__name__]
    finally:
        if owner.process and owner.process.poll() is None and owner.transport_id:
            for capture_fn in (lambda: capture_state(owner, 'final'),
                               lambda: read_native(owner),
                               lambda: probe.read_events(owner)):
                try:
                    capture_fn()
                except Exception:
                    result['failure_capture'] = 'PARTIAL'
        try:
            owner.close()
            result['cleanup'] = 'OWNED_PROCESS_STOPPED_AVD_RETAINED' if owner.process else 'NO_AVD_STARTED'
        except (InfrastructureError, OSError, subprocess.SubprocessError):
            result.update(status='INFRASTRUCTURE-BLOCKED', cleanup='REFUSED_OR_INCOMPLETE')
        result['finished_at_unix_ms'] = time.time_ns() // 1_000_000
        result['evidence_sha256'] = {p.name: sha(p) for p in owner.evidence.iterdir() if p.is_file()}
        (owner.evidence / 'result.json').write_text(json.dumps(result, sort_keys=True, indent=2) + '\n')
        # Raw logs, commands, paths, signing key and notification/location content
        # never leave private evidence. CI gets only binding digests and outcome codes.
        public = {k: v for k, v in result.items() if k not in ('fixture_build', 'observer_build', 'routes')}
        public['artifact_bindings'] = result.get('fixture_build', {}).get('artifacts', {})
        public['configuration_bindings'] = {'fixture': result.get('fixture_build', {}).get('config_sha256'),
                                            'observer': result.get('observer_build', {}).get('config_sha256')}
        public['observer_binding'] = {k: result.get('observer_build', {}).get(k) for k in
                                      ('artifact_sha256', 'signing_cert_sha256')}
        public['route_bindings'] = [{k: route[k] for k in ('sha256', 'points_sent', 'duration_s', 'completed')}
                                    for route in result.get('routes', [])]
        with args.output.open('x') as output:
            json.dump(public, output, sort_keys=True, indent=2)
            output.write('\n')
    print(f"{result['status']}: {', '.join(result['reasons'])}", flush=True)
    return {'PASS': 0, 'FAIL': 1, 'INFRASTRUCTURE-BLOCKED': 2}[result['status']]


if __name__ == '__main__':
    sys.exit(main())
