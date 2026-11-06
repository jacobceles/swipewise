#!/usr/bin/env python3
"""Fail-closed geofence evidence oracle; device collection is not implemented yet.

This replaces the unsafe live-device runner. There is deliberately no ADB,
device autodetection, --serial, provider manipulation, app-data wipe or live
execution path here. An offline oracle pass is NOT device qualification.
See geofence_qualification/README.md for the test-only evidence contract.
"""

import argparse
import hashlib
import json
import math
import re
import sys
import time
from pathlib import Path

from play_gpx_route import parse_gpx

VERSION = 1
ROOT = Path(__file__).resolve().parent.parent
ROUTE = ROOT / 'test/fixtures/gpx/walkin_dwell.gpx'
MAX_BYTES = 256 * 1024
MAX_EVENTS = 256
MAX_RUN_MS = 600_000
MAX_EVIDENCE_AGE_MS = 30 * 60_000
PACKAGE = 'com.appsoflife.swipewise.dev'
MERCHANT = 'qualification-restaurant-v1'
CARD = 'qualification-dining-v1'
FENCE = f'm_{MERCHANT}'
TITLE = "You're near Qualification Restaurant"
TEXT = 'Use Qualification Dining for 3%'
SCENARIOS = {'precise_walkin', 'driveby', 'premature_exit', 'adjacent_nextdoor'}
SEED = {
    'version': 'geofence-qualification-v1',
    'user_id': 'qualification-user-v1',
    'cards': [
        {'id': CARD, 'name': 'Qualification Dining', 'dining_percent': 3, 'base_percent': 1,
         'currency': 'USD'},
        {'id': 'qualification-base-v1', 'name': 'Qualification Base', 'base_percent': 2,
         'currency': 'USD'},
    ],
    'merchant_id': MERCHANT,
    'merchant_name': 'Qualification Restaurant',
    'merchant_place_type': 'restaurant',
    'merchant_business_status': 'OPERATIONAL',
    'merchant_lat': 39.237148,
    'merchant_lon': -123.176090,
    'fence_radius_m': 100,
    'alerts_enabled': True,
    'dwell_seconds': 30,
}
HASH_FIELDS = {
    'config_sha256', 'artifact_sha256', 'signing_cert_sha256', 'seed_sha256',
    'classifier_sha256', 'route_sha256', 'observer_sha256',
}
IDENTITY_FIELDS = HASH_FIELDS | {
    'candidate_sha', 'entrypoint', 'build_mode', 'package', 'input_source', 'environment',
}
# A source denotes an observation boundary, not an assertion inferred from a
# nearby log substring. A future collector must actually implement each one.
SOURCES = {
    'adb_ready': 'command', 'log_ready': 'command', 'diagnostics_ready': 'command',
    'listener_start': 'android-notification-listener',
    'seed': 'dart-fixture', 'ranked': 'geofence-manager',
    'console_input': 'emulator-console', 'gps_sample': 'android-location',
    'flp_sample': 'gms-flp', 'gms_add': 'gms-task-completion',
    'route_start': 'w3-replay', 'route_end': 'w3-replay',
    'enter': 'platform-geofencing-event', 'armed': 'native-attempt-store',
    'verification': 'default-location-provider', 'decision': 'arrival-policy',
    'terminal': 'dwell-receiver-done',
    'android_post': 'android-notification-listener',
    'android_remove': 'android-notification-listener',
    'listener_end': 'android-notification-listener', 'observation_end': 'collector',
}
EPISODE_FIELDS = {'token', 'account_epoch', 'metadata_generation', 'boot_count', 'trigger_fence_id'}
SAMPLE_FIELDS = {
    'lat', 'lon', 'provider', 'elapsed_realtime_ns', 'observed_elapsed_ns',
    'accuracy_m', 'speed_mps', 'is_mock',
}


class EvidenceError(ValueError):
    def __init__(self, code, status='FAIL'):
        super().__init__(code)
        self.status = status


def require(condition, code, status='FAIL'):
    if not condition:
        raise EvidenceError(code, status)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'),
                                     allow_nan=False).encode()).hexdigest()


def integer(value, minimum=0):
    return type(value) is int and value >= minimum


def number(value, minimum=0):
    return type(value) in (int, float) and math.isfinite(value) and value >= minimum


def fields(value, expected):
    require(type(value) is dict and value.keys() == expected, 'INVALID_FIELDS')


def exact(value, expected, code, status='FAIL'):
    # Python otherwise considers True == 1. This protocol uses JSON types.
    require(digest(value) == digest(expected), code, status)


def checked_output(kind, returncode, stdout, stderr, run_id):
    """Exit zero alone is insufficient, including for native diagnostic dumps.

    Readiness markers are exact, run-specific command replies, not entire logcat
    buffers. No stdout/stderr is copied into result files or exception messages.
    """
    require(type(returncode) is int and returncode == 0 and
            type(stdout) is str and type(stderr) is str, 'COMMAND_UNAVAILABLE',
            'INFRASTRUCTURE-BLOCKED')
    bad = r'(?im)^\s*(?:KO\b|error\b|failure\b|exception\b|unknown\b|unrecognized\b)|' \
          r'(?i:permission denied|not found|no (?:matching|running) activities|' \
          r'no activities found|diagnostics unavailable|unable to resolve|can.t find service)'
    require(not re.search(bad, stdout + '\n' + stderr), 'COMMAND_SEMANTIC_FAILURE',
            'INFRASTRUCTURE-BLOCKED')
    expected = {
        'adb_ready': 'device',
        'log_ready': f'QUALIFICATION {run_id} logcat-ready',
        'diagnostics_ready': r'SwipeWise \S+ arrival diagnostics \(UTC epoch ms\)',
    }
    require(kind in expected, 'UNKNOWN_COMMAND')
    valid = (re.fullmatch(expected[kind], stdout.strip()) if kind == 'diagnostics_ready'
             else stdout.strip() == expected[kind])
    require(valid and not stderr.strip(), 'COMMAND_REPLY_UNAVAILABLE', 'INFRASTRUCTURE-BLOCKED')


def validate_context(context, now_ms, route_path):
    fields(context, {'schema_version', 'run_id', 'scenario', 'started_at_unix_ms', 'identity'})
    require(type(context['schema_version']) is int and context['schema_version'] == VERSION,
            'SCHEMA_VERSION')
    require(type(context['run_id']) is str and
            re.fullmatch(r'q-[a-f0-9]{32}', context['run_id']), 'RUN_ID')
    require(type(context['scenario']) is str and context['scenario'] in SCENARIOS, 'SCENARIO')
    start = context['started_at_unix_ms']
    require(integer(start, 1) and 0 <= now_ms - start <= MAX_EVIDENCE_AGE_MS, 'STALE_RUN')
    identity = context['identity']
    fields(identity, IDENTITY_FIELDS)
    for name in HASH_FIELDS:
        require(type(identity[name]) is str and re.fullmatch(r'[a-f0-9]{64}', identity[name]),
                'IDENTITY_HASH')
    require(type(identity['candidate_sha']) is str and
            re.fullmatch(r'[a-f0-9]{40}', identity['candidate_sha']), 'CANDIDATE_IDENTITY')
    require(identity['entrypoint'] == 'integration_test/geofence_fixture.dart' and
            identity['build_mode'] == 'debug-fixture' and identity['package'] == PACKAGE,
            'FIXTURE_BUILD_IDENTITY')
    require(identity['input_source'] == 'emulator-console-gps', 'INPUT_SOURCE')
    fields(identity['environment'], {'image', 'api', 'abi', 'gms_version'})
    require(identity['environment']['image'] == 'system-images;android-36.1;google_apis;arm64-v8a'
            and identity['environment']['api'] == '36.1'
            and identity['environment']['abi'] == 'arm64-v8a'
            and type(identity['environment']['gms_version']) is str
            and re.fullmatch(r'[0-9.]{1,40}', identity['environment']['gms_version']), 'ENVIRONMENT')
    require(identity['seed_sha256'] == digest(SEED), 'SEED_IDENTITY')
    require(identity['route_sha256'] == hashlib.sha256(route_path.read_bytes()).hexdigest(),
            'ROUTE_IDENTITY')
    # W3 owns timestamp/motion parsing. Never restore the old description-based
    # delays or a second parser here. Live replay must also reuse replay_route.
    return parse_gpx(route_path)


def validate_sample(sample, first_point=None):
    fields(sample, SAMPLE_FIELDS)
    require(type(sample['provider']) is str and sample['provider'] in {'gps', 'fused'},
            'SAMPLE_PROVIDER')
    require(integer(sample['elapsed_realtime_ns'], 1) and
            integer(sample['observed_elapsed_ns'], 1), 'SAMPLE_IDENTITY')
    age = sample['observed_elapsed_ns'] - sample['elapsed_realtime_ns']
    # This narrow fresh-fix smoke is not a reimplementation of all policy paths
    # (in particular the conditional 120 s coalesced-fix exception).
    require(0 <= age <= 15_000_000_000, 'SAMPLE_AGE')
    require(number(sample['accuracy_m']) and 0 < sample['accuracy_m'] <= 50, 'SAMPLE_ACCURACY')
    require(sample['speed_mps'] is None or number(sample['speed_mps']), 'SAMPLE_SPEED')
    require(sample['is_mock'] is None or type(sample['is_mock']) is bool, 'SAMPLE_MOCK_FIELD')
    require(type(sample['lat']) in (int, float) and math.isfinite(sample['lat']) and
            -90 <= sample['lat'] <= 90 and type(sample['lon']) in (int, float) and
            math.isfinite(sample['lon']) and -180 <= sample['lon'] <= 180, 'SAMPLE_COORDINATES')
    if first_point:
        require(all(abs(sample[k] - first_point[k]) <= 0.00001 for k in ('lat', 'lon')),
                'INJECTION_NOT_OBSERVED')


def check_walkin(context, events, points):
    require(type(events) is list and 0 < len(events) <= MAX_EVENTS, 'NO_BOUNDED_EVENTS')
    by_stage = {}
    last_ms = -1
    for seq, event in enumerate(events):
        fields(event, {'seq', 'run_id', 'context_sha256', 'elapsed_ms', 'stage', 'source', 'data'})
        require(type(event['seq']) is int and event['seq'] == seq, 'EVENT_SEQUENCE')
        require(event['run_id'] == context['run_id'] and event['context_sha256'] == digest(context),
                'EVENT_RUN_IDENTITY')
        at = event['elapsed_ms']
        require(integer(at) and last_ms <= at <= MAX_RUN_MS, 'EVENT_TIME_ORDER')
        last_ms = at
        stage = event['stage']
        require(type(stage) is str and stage in SOURCES, 'UNKNOWN_STAGE')
        require(event['source'] == SOURCES[stage], 'OBSERVATION_SOURCE')
        # Includes repeated Android post/update callbacks: one active item must
        # not conceal multiple submissions, removals or listener reconnections.
        require(stage not in by_stage, 'DUPLICATE_STAGE')
        require(type(event['data']) is dict, 'EVENT_DATA')
        by_stage[stage] = event

    def one(stage):
        require(stage in by_stage, f'MISSING_{stage.upper()}')
        return by_stage[stage]['data']

    def before(*stages):
        for a, b in zip(stages, stages[1:]):
            one(a)
            one(b)
            require(by_stage[a]['seq'] < by_stage[b]['seq'], 'STAGE_ORDER')

    for kind in ('adb_ready', 'log_ready', 'diagnostics_ready'):
        reply = one(kind)
        fields(reply, {'returncode', 'stdout', 'stderr'})
        checked_output(kind, **reply, run_id=context['run_id'])
        before(kind, 'listener_start')
    listener = one('listener_start')
    exact(listener, {'session_id': context['run_id'], 'callback_seq': 0, 'active_arrivals': 0},
          'LISTENER_BASELINE', 'INFRASTRUCTURE-BLOCKED')
    seed = one('seed')
    exact(seed, {'seed_sha256': digest(SEED),
                 'classifier_sha256': context['identity']['classifier_sha256'],
                 'wallet_card_ids': [CARD, 'qualification-base-v1'],
                 'synthetic_user_id': SEED['user_id'], 'alerts_enabled': True,
                 'dwell_seconds': 30, 'cache_complete': True, 'cache_current': True,
                 'remote_catalog_disabled': True}, 'SEED_PREREQUISITES')
    advice = {'merchant_id': MERCHANT, 'card_id': CARD, 'rate_percent': 3,
              'trigger_fence_id': FENCE, 'owner_fence_id': FENCE}
    exact(one('ranked'), advice, 'RANKED_ADVICE')
    first = points[0]
    exact(one('console_input'), {'lat': first['lat'], 'lon': first['lon'],
                                 'nominal_speed_mps': first['speed_mps'],
                                 'commanded_speed_mps': first['speed_mps'],
                                 'commanded_accuracy_m': None}, 'COMMANDED_INPUT')
    for stage, provider in (('gps_sample', 'gps'), ('flp_sample', 'fused')):
        sample = one(stage)
        validate_sample(sample, first)
        require(sample['provider'] == provider, 'SAMPLE_PROVIDER')
    exact(one('gms_add'), {'operation': 'addGeofences', 'success': True,
                          'merchant_fence_ids': [FENCE]}, 'GMS_ADD_NOT_OBSERVED')
    exact(one('enter'), {'trigger_fence_id': FENCE}, 'WRONG_ENTER')
    arm = one('armed')
    fields(arm, EPISODE_FIELDS | {'created_elapsed_ns', 'due_elapsed_ns', 'expires_elapsed_ns'})
    require(arm['trigger_fence_id'] == FENCE and
            type(arm['token']) is int and -(1 << 63) <= arm['token'] < (1 << 63) and
            arm['token'] != 0 and
            all(integer(arm[k]) for k in ('account_epoch', 'metadata_generation', 'boot_count')),
            'ATTEMPT_IDENTITY')
    require(integer(arm['created_elapsed_ns'], 1) and integer(arm['due_elapsed_ns'], 1) and
            integer(arm['expires_elapsed_ns'], 1) and
            arm['due_elapsed_ns'] - arm['created_elapsed_ns'] == 30_000_000_000 and
            arm['expires_elapsed_ns'] - arm['created_elapsed_ns'] == 180_000_000_000,
            'ATTEMPT_DEADLINES')
    episode = {key: arm[key] for key in EPISODE_FIELDS}
    verification = one('verification')
    fields(verification, EPISODE_FIELDS | {'sample', 'priority', 'is_recheck'})
    exact({key: verification[key] for key in EPISODE_FIELDS}, episode, 'VERIFICATION_OWNERSHIP')
    require(verification['priority'] == 'BALANCED_POWER_ACCURACY' and
            verification['is_recheck'] is False, 'DEFAULT_VERIFIER')
    sample = verification['sample']
    validate_sample(sample)
    # Independent local-plane check for this fixed 100 m fixture only: require
    # an in-circle sample, not the policy's larger accuracy/slack reach. Do not
    # trust a claimed VERIFIED decision with incompatible geometry or speed.
    north_m = math.radians(sample['lat'] - SEED['merchant_lat']) * 6_371_000
    east_m = (math.radians(sample['lon'] - SEED['merchant_lon']) * 6_371_000 *
              math.cos(math.radians(SEED['merchant_lat'])))
    require(math.hypot(north_m, east_m) <= SEED['fence_radius_m'], 'VERIFICATION_GEOMETRY')
    require(sample['speed_mps'] is None or sample['speed_mps'] <= 2.0, 'VERIFICATION_MOTION')
    require(verification['sample']['provider'] == 'fused' and
            verification['sample']['observed_elapsed_ns'] >= arm['due_elapsed_ns'] and
            verification['sample']['observed_elapsed_ns'] <= arm['expires_elapsed_ns'] and
            by_stage['verification']['elapsed_ms'] - by_stage['armed']['elapsed_ms'] >= 29_000,
            'PREMATURE_VERIFICATION')
    # Keep Android elapsed sample identity separate from host run-relative time,
    # but require their observed deltas to agree within collection jitter.
    for stage in ('gps_sample', 'flp_sample', 'verification'):
        sample = one(stage)['sample'] if stage == 'verification' else one(stage)
        android_delta = sample['observed_elapsed_ns'] - arm['created_elapsed_ns']
        host_delta = (by_stage[stage]['elapsed_ms'] - by_stage['armed']['elapsed_ms']) * 1_000_000
        require(abs(android_delta - host_delta) <= 1_000_000_000, 'ELAPSED_CLOCK_MISMATCH')
    exact(one('decision'), {**episode, 'verdict': 'VERIFIED', 'outcome': 'POSTED'},
          'PRECISE_DECISION')
    # ArrivalDecision(outcome=POSTED) precedes muting/cooldown/notification checks.
    # Only the receiver's final outcome can satisfy this requirement.
    exact(one('terminal'), {**episode, **advice, 'outcome': 'POSTED'}, 'TERMINAL_OUTCOME')
    post = one('android_post')
    exact(post, {'session_id': context['run_id'], 'callback_seq': 1,
                 'package': PACKAGE, 'channel': 'swipewise_dwell',
                 'tag': 'swipewise.arrival', 'id': 0,
                 'title': TITLE, 'text': TEXT, 'big_text': TEXT}, 'ANDROID_NOTIFICATION')
    require('android_remove' not in by_stage, 'NOTIFICATION_REMOVED')
    exact(one('listener_end'), {'session_id': context['run_id'], 'callback_seq': 2,
                                'active_arrivals': 1, 'dropped_events': 0,
                                'connected': True}, 'LISTENER_CONTINUITY',
          'INFRASTRUCTURE-BLOCKED')
    exact(one('observation_end'), {'completed': True, 'adb_connected': True,
                                  'log_continuous': True}, 'INCOMPLETE_OBSERVATION',
          'INFRASTRUCTURE-BLOCKED')
    exact(one('route_start'), {'route_sha256': context['identity']['route_sha256']}, 'ROUTE_START')
    exact(one('route_end'), {'points_sent': len(points)}, 'ROUTE_INCOMPLETE')
    span_ms = round(points[-1]['time_offset_s'] * 1000)
    require(by_stage['route_end']['elapsed_ms'] - by_stage['route_start']['elapsed_ms'] >= span_ms,
            'ROUTE_TIMING')
    # Conservative once-only positive-post observation, not a universal delivery
    # deadline: attempt lifetime + overdue grace + outstanding fix + observer margin.
    required_end_ms = max(by_stage['route_end']['elapsed_ms'],
                          by_stage['armed']['elapsed_ms'] + 223_000)
    require(by_stage['observation_end']['elapsed_ms'] >= required_end_ms and
            by_stage['listener_end']['elapsed_ms'] >= required_end_ms and
            by_stage['observation_end']['elapsed_ms'] - by_stage['listener_end']['elapsed_ms'] <= 1_000,
            'PARTIAL_OBSERVATION_WINDOW')
    # Causal prerequisites, not a total order for independent observations. The
    # manager acquires its own location; a separate GPS/FLP observer may report
    # before or after ranking, and neither observer callback must precede the other.
    before('listener_start', 'seed')
    before('console_input', 'gps_sample')
    before('console_input', 'flp_sample')
    before('seed', 'ranked', 'gms_add', 'enter', 'armed', 'verification', 'decision', 'terminal')
    before('listener_start', 'android_post', 'listener_end', 'observation_end')
    before('decision', 'android_post')
    before('gms_add', 'route_start', 'route_end', 'listener_end')
    before('route_start', 'enter')
    before('terminal', 'listener_end')
    require(events[-1]['stage'] == 'observation_end', 'UNOBSERVED_TAIL')


def evaluate(context, events, *, now_ms=None, route_path=ROUTE):
    """Validate synthetic evidence only. Never produces qualified device PASS."""
    result = {
        'schema_version': VERSION, 'scope': 'offline-oracle',
        'status': 'FAIL', 'oracle_status': 'FAIL', 'identity_verified': False,
        'run_id': None, 'identity': None, 'scenario': None,
        'started_at_unix_ms': None, 'observed_stages': [], 'ordered_outcomes': [],
        'expected': [], 'evidence': [], 'reasons': [],
    }
    try:
        points = validate_context(context, now_ms if now_ms is not None else time.time_ns() // 1_000_000,
                                  route_path)
        result.update(run_id=context['run_id'], identity=context['identity'],
                      scenario=context['scenario'], started_at_unix_ms=context['started_at_unix_ms'])
        require(context['scenario'] == 'precise_walkin', 'SCENARIO_NOT_IMPLEMENTED', 'NOT-COVERED')
        result['expected'] = ['terminal:POSTED', 'android_post:1']
        check_walkin(context, events, points)
        require(context['started_at_unix_ms'] + events[-1]['elapsed_ms'] <=
                (now_ms if now_ms is not None else time.time_ns() // 1_000_000), 'FUTURE_EVENTS')
        result.update(status='NOT-COVERED', oracle_status='PASS',
                      reasons=['OFFLINE_EVIDENCE_IS_NOT_DEVICE_QUALIFICATION'])
    except EvidenceError as exc:
        result.update(status=exc.status, reasons=[str(exc)])
    except (OSError, ValueError, TypeError, KeyError, SyntaxError, OverflowError):
        result['reasons'] = ['INVALID_OR_UNAVAILABLE_EVIDENCE']
    # Store only fixed stage/outcome codes and times, never raw log/notification
    # text, coordinates, account state, command output, or arbitrary input fields.
    sanitized = []
    if type(events) is list and len(events) <= MAX_EVENTS:
        for event in events:
            if type(event) is not dict or type(event.get('stage')) is not str:
                continue
            stage, at = event['stage'], event.get('elapsed_ms')
            if stage not in SOURCES or not integer(at) or at > MAX_RUN_MS:
                continue
            item = {'stage': stage, 'elapsed_ms': at}
            data = event.get('data')
            if stage in ('decision', 'terminal') and type(data) is dict:
                outcome = data.get('outcome')
                if outcome in ('POSTED', 'POSTED_APPROXIMATE', 'MUTED', 'MOVING_RECHECK'):
                    item['outcome'] = outcome
                    result['ordered_outcomes'].append(dict(item))
            sanitized.append(item)
    result['observed_stages'] = sanitized
    result['evidence'] = [{'kind': 'sanitized-stage-summary', 'sha256': digest(sanitized)}]
    return result


def _unique_object(pairs):
    obj = {}
    for key, value in pairs:
        require(key not in obj, 'DUPLICATE_JSON_KEY')
        obj[key] = value
    return obj


def read_json(path):
    with path.open('rb') as handle:
        data = handle.read(MAX_BYTES + 1)
    require(len(data) <= MAX_BYTES, 'EVIDENCE_TOO_LARGE')
    return json.loads(data, object_pairs_hook=_unique_object,
                      parse_constant=lambda _: (_ for _ in ()).throw(EvidenceError('NONFINITE_JSON')))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest='command', required=True)
    offline = subparsers.add_parser('evaluate', help='Check synthetic evidence, never qualify a device')
    offline.add_argument('--context', type=Path, required=True)
    offline.add_argument('--trace', type=Path, required=True)
    offline.add_argument('--output', type=Path, required=True)
    blocked = subparsers.add_parser('device', help='Report the unimplemented, blocked live lane')
    blocked.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(argv)
    result = {'schema_version': VERSION, 'scope': 'device-qualification',
              'status': 'INFRASTRUCTURE-BLOCKED', 'identity_verified': False,
              'run_id': None, 'scenario': None, 'started_at_unix_ms': None,
              'identity': None, 'observed_stages': [], 'ordered_outcomes': [], 'evidence': [],
              'reasons': ['RUN_OWNED_LAUNCHER_FIXTURE_AND_OBSERVER_NOT_IMPLEMENTED']}
    try:
        if args.command == 'evaluate':
            context, events = read_json(args.context), read_json(args.trace)
            result = evaluate(context, events)
    except (OSError, ValueError, TypeError, RecursionError):
        result.update(scope='offline-oracle', status='FAIL', reasons=['INVALID_OR_UNAVAILABLE_INPUT'])
    except KeyboardInterrupt:
        result.update(status='INFRASTRUCTURE-BLOCKED', reasons=['CANCELLED'])
    try:
        # Exclusive creation prevents overwriting prior/owner evidence, including
        # a context/trace accidentally supplied as the result path or a symlink.
        with args.output.open('x') as handle:
            json.dump(result, handle, sort_keys=True, indent=2, allow_nan=False)
            handle.write('\n')
    except OSError:
        print('Result could not be saved (existing or unavailable output path).', file=sys.stderr)
        return 2
    print(f"{result['status']}: {', '.join(result['reasons'])}")
    return {'PASS': 0, 'FAIL': 1, 'INFRASTRUCTURE-BLOCKED': 2, 'NOT-COVERED': 3}[result['status']]


if __name__ == '__main__':
    sys.exit(main())
