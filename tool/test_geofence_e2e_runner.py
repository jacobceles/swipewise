"""Discoverable, entirely offline tests. The positive trace is synthetic, not OS evidence."""

import copy
import hashlib
import json
import subprocess
import tempfile
import time
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path
from unittest import mock

import test_geofence_e2e as runner


def synthetic_run():
    # Relative to now: evidence freshness must not become a fixed-date time bomb.
    now = time.time_ns() // 1_000_000
    points = runner.parse_gpx(runner.ROUTE)
    identity = {key: 'a' * 64 for key in runner.HASH_FIELDS}
    identity.update(candidate_sha='f' * 40, entrypoint='integration_test/geofence_fixture.dart',
                    build_mode='debug-fixture', package=runner.PACKAGE,
                    input_source='emulator-console-gps',
                    seed_sha256=runner.digest(runner.SEED),
                    route_sha256=hashlib.sha256(runner.ROUTE.read_bytes()).hexdigest(),
                    environment={'image': 'system-images;android-36.1;google_apis;arm64-v8a',
                                 'api': '36.1', 'abi': 'arm64-v8a', 'gms_version': '26.40.32'})
    context = {'schema_version': runner.VERSION, 'run_id': 'q-' + 'b' * 32,
               'scenario': 'precise_walkin', 'started_at_unix_ms': now - 300_000,
               'identity': identity}
    events = []

    def emit(stage, at, data):
        events.append({'seq': len(events), 'run_id': context['run_id'],
                       'context_sha256': runner.digest(context), 'elapsed_ms': at,
                       'stage': stage, 'source': runner.SOURCES[stage], 'data': data})

    emit('adb_ready', 0, {'returncode': 0, 'stdout': 'device\n', 'stderr': ''})
    emit('log_ready', 10, {'returncode': 0,
                         'stdout': f"QUALIFICATION {context['run_id']} logcat-ready\n", 'stderr': ''})
    emit('diagnostics_ready', 20, {'returncode': 0,
                                 'stdout': 'SwipeWise 1.0.22+32 arrival diagnostics (UTC epoch ms)',
                                 'stderr': ''})
    emit('listener_start', 30, {'session_id': context['run_id'], 'callback_seq': 0, 'active_arrivals': 0})
    emit('seed', 40, {'seed_sha256': runner.digest(runner.SEED),
                      'classifier_sha256': identity['classifier_sha256'],
                      'wallet_card_ids': [runner.CARD, 'qualification-base-v1'],
                      'synthetic_user_id': runner.SEED['user_id'], 'alerts_enabled': True,
                      'dwell_seconds': 30, 'cache_complete': True, 'cache_current': True,
                      'remote_catalog_disabled': True})
    advice = {'merchant_id': runner.MERCHANT, 'card_id': runner.CARD, 'rate_percent': 3,
              'trigger_fence_id': runner.FENCE, 'owner_fence_id': runner.FENCE}
    emit('console_input', 50, {'lat': points[0]['lat'], 'lon': points[0]['lon'],
                               'nominal_speed_mps': points[0]['speed_mps'],
                               'commanded_speed_mps': points[0]['speed_mps'],
                               'commanded_accuracy_m': None})
    for stage, provider, at in [('gps_sample', 'gps', 60), ('flp_sample', 'fused', 70)]:
        emit(stage, at, {'lat': points[0]['lat'], 'lon': points[0]['lon'], 'provider': provider,
                        'elapsed_realtime_ns': (100_000 + at) * 1_000_000,
                        'observed_elapsed_ns': (100_000 + at) * 1_000_000,
                        'accuracy_m': 5.0, 'speed_mps': None, 'is_mock': None})
    emit('ranked', 80, advice)
    emit('gms_add', 90, {'operation': 'addGeofences', 'success': True,
                         'merchant_fence_ids': [runner.FENCE]})
    emit('route_start', 1_000, {'route_sha256': identity['route_sha256']})
    emit('enter', 60_000, {'trigger_fence_id': runner.FENCE})
    episode = {'trigger_fence_id': runner.FENCE, 'token': 42, 'account_epoch': 1,
               'metadata_generation': 1, 'boot_count': 1}
    emit('armed', 60_100, {**episode, 'created_elapsed_ns': 160_100_000_000,
                           'due_elapsed_ns': 190_100_000_000,
                           'expires_elapsed_ns': 340_100_000_000})
    emit('verification', 90_100, {**episode, 'priority': 'BALANCED_POWER_ACCURACY', 'is_recheck': False,
                                 'sample': {'lat': 39.237148, 'lon': -123.176090, 'provider': 'fused',
                                            'elapsed_realtime_ns': 190_100_000_000,
                                            'observed_elapsed_ns': 190_100_000_000,
                                            'accuracy_m': 5.0, 'speed_mps': 0.0, 'is_mock': False}})
    emit('decision', 90_200, {**episode, 'verdict': 'VERIFIED', 'outcome': 'POSTED'})
    # notify() runs before done(); listener delivery may be before OR after done.
    emit('android_post', 90_300, {'session_id': context['run_id'], 'callback_seq': 1,
                                'package': runner.PACKAGE, 'channel': 'swipewise_dwell',
                                'tag': 'swipewise.arrival', 'id': 0,
                                'title': runner.TITLE, 'text': runner.TEXT, 'big_text': runner.TEXT})
    emit('terminal', 90_400, {**episode, **advice, 'outcome': 'POSTED'})
    emit('route_end', 209_000, {'points_sent': len(points)})
    emit('listener_end', 283_100, {'session_id': context['run_id'], 'callback_seq': 2,
                                  'active_arrivals': 1, 'dropped_events': 0, 'connected': True})
    emit('observation_end', 283_100, {'completed': True, 'adb_connected': True, 'log_continuous': True})
    return context, events, now


class OracleTests(unittest.TestCase):
    def setUp(self):
        self.context, self.events, self.now = synthetic_run()

    def event(self, stage):
        return next(event for event in self.events if event['stage'] == stage)

    def result(self):
        return runner.evaluate(self.context, self.events, now_ms=self.now)

    def assert_rejected(self, code=None, status=None):
        result = self.result()
        self.assertNotEqual(result['oracle_status'], 'PASS', result)
        self.assertNotEqual(result['status'], 'PASS', result)
        if code:
            self.assertEqual(result['reasons'], [code])
        if status:
            self.assertEqual(result['status'], status)
        return result

    def rebind(self):
        for event in self.events:
            event['context_sha256'] = runner.digest(self.context)

    def resequence(self):
        for seq, event in enumerate(self.events):
            event['seq'] = seq

    def test_complete_trace_passes_oracle_but_never_device_qualification(self):
        result = self.result()
        self.assertEqual(result['oracle_status'], 'PASS', result)
        self.assertEqual(result['status'], 'NOT-COVERED')
        self.assertFalse(result['identity_verified'])
        self.assertEqual(result['scope'], 'offline-oracle')
        self.assertEqual(result['ordered_outcomes'][-1]['stage'], 'terminal')

    def test_actual_notification_callback_may_follow_terminal(self):
        a, b = self.events.index(self.event('android_post')), self.events.index(self.event('terminal'))
        self.events[a], self.events[b] = self.events[b], self.events[a]
        self.events[a]['elapsed_ms'], self.events[b]['elapsed_ms'] = 90_300, 90_400
        self.resequence()
        self.assertEqual(self.result()['oracle_status'], 'PASS')

    def test_independent_setup_observations_need_no_total_order(self):
        original = copy.deepcopy(self.events)
        slots = [i for i, event in enumerate(original) if event['stage'] in
                 {'seed', 'ranked', 'console_input', 'gps_sample', 'flp_sample'}]
        by_stage = {event['stage']: event for event in original}
        for order in [('seed', 'console_input', 'flp_sample', 'gps_sample', 'ranked'),
                      ('console_input', 'gps_sample', 'seed', 'ranked', 'flp_sample')]:
            with self.subTest(order=order):
                self.events = copy.deepcopy(original)
                for index, stage in zip(slots, order):
                    self.events[index] = copy.deepcopy(by_stage[stage])
                    self.events[index]['elapsed_ms'] = original[index]['elapsed_ms']
                self.resequence()
                self.assertEqual(self.result()['oracle_status'], 'PASS')

    def test_original_walkin_unrelated_approximate_probe_fails(self):
        self.events = [{'log': 'fence ENTER other\ndwell arm other\nother posted_approximate'}]
        self.assert_rejected()

    def test_listener_must_be_live_before_seeding(self):
        a, b = self.events.index(self.event('listener_start')), self.events.index(self.event('seed'))
        self.events[a], self.events[b] = self.events[b], self.events[a]
        self.events[a]['elapsed_ms'], self.events[b]['elapsed_ms'] = 30, 40
        self.resequence()
        self.assert_rejected('STAGE_ORDER')

    def test_enter_before_replay_cannot_prove_route_arrival(self):
        a, b = self.events.index(self.event('route_start')), self.events.index(self.event('enter'))
        self.events[a], self.events[b] = self.events[b], self.events[a]
        self.events[a]['elapsed_ms'], self.events[b]['elapsed_ms'] = 1_000, 60_000
        self.event('route_end')['elapsed_ms'] = 268_000
        self.resequence()
        self.assert_rejected('STAGE_ORDER')

    def test_original_driveby_empty_probe_is_not_covered_not_passed(self):
        self.context['scenario'] = 'driveby'
        self.events = []
        self.assert_rejected('SCENARIO_NOT_IMPLEMENTED', 'NOT-COVERED')

    def test_original_bounce_empty_probe_is_not_covered_not_passed(self):
        self.context['scenario'] = 'premature_exit'
        self.events = []
        self.assert_rejected('SCENARIO_NOT_IMPLEMENTED', 'NOT-COVERED')

    def test_original_adjacent_one_unrelated_enter_probe_is_not_passed(self):
        self.context['scenario'] = 'adjacent_nextdoor'
        self.events = [{'log': 'fence ENTER other'}]
        self.assert_rejected('SCENARIO_NOT_IMPLEMENTED', 'NOT-COVERED')

    def test_no_events_cannot_pass_precise_case(self):
        self.events = []
        self.assert_rejected('NO_BOUNDED_EVENTS')

    def test_every_required_stage_is_non_vacuous(self):
        original = copy.deepcopy(self.events)
        for stage in [event['stage'] for event in original]:
            with self.subTest(stage=stage):
                self.events = [copy.deepcopy(event) for event in original if event['stage'] != stage]
                self.resequence()
                self.assert_rejected(f'MISSING_{stage.upper()}')

    def test_empty_wallet_disabled_settings_or_incomplete_cache_fail(self):
        seed = self.event('seed')['data']
        for key, value in [('wallet_card_ids', []), ('alerts_enabled', False),
                           ('cache_complete', False), ('cache_current', False),
                           ('remote_catalog_disabled', False), ('synthetic_user_id', 'owner')]:
            with self.subTest(key=key):
                original = seed[key]
                seed[key] = value
                self.assert_rejected('SEED_PREREQUISITES')
                seed[key] = original

    def test_missing_or_stored_registration_count_is_not_gms_add(self):
        self.event('gms_add')['data'] = {'stored_count': 1}
        self.assert_rejected('GMS_ADD_NOT_OBSERVED')

    def test_failed_gms_add_is_not_success(self):
        self.event('gms_add')['data']['success'] = False
        self.assert_rejected('GMS_ADD_NOT_OBSERVED')

    def test_wrong_ranked_merchant_card_rate_or_fence_fails(self):
        advice = self.event('ranked')['data']
        for key, value in [('merchant_id', 'other'), ('card_id', 'other'), ('rate_percent', 2),
                           ('trigger_fence_id', 'other'), ('owner_fence_id', 'other')]:
            with self.subTest(key=key):
                original = advice[key]
                advice[key] = value
                self.assert_rejected('RANKED_ADVICE')
                advice[key] = original

    def test_wrong_platform_enter_fails(self):
        self.event('enter')['data']['trigger_fence_id'] = 'other'
        self.assert_rejected('WRONG_ENTER')

    def test_episode_token_epoch_generation_or_boot_mismatch_fails(self):
        for stage in ('verification', 'decision', 'terminal'):
            for field in ('token', 'account_epoch', 'metadata_generation', 'boot_count'):
                with self.subTest(stage=stage, field=field):
                    data = self.event(stage)['data']
                    data[field] += 1
                    self.assert_rejected()
                    data[field] -= 1

    def test_signed_long_nonzero_attempt_tokens_pass(self):
        for token in (-42, -(1 << 63), (1 << 63) - 1):
            with self.subTest(token=token):
                for stage in ('armed', 'verification', 'decision', 'terminal'):
                    self.event(stage)['data']['token'] = token
                result = self.result()
                self.assertEqual(result['oracle_status'], 'PASS', result)
                self.assertEqual(result['status'], 'NOT-COVERED')

    def test_zero_boolean_noninteger_and_out_of_range_tokens_fail(self):
        for token in (0, True, False, -(1 << 63) - 1, 1 << 63, 42.0):
            with self.subTest(token=token):
                for stage in ('armed', 'verification', 'decision', 'terminal'):
                    self.event(stage)['data']['token'] = token
                self.assert_rejected('ATTEMPT_IDENTITY')

    def test_negative_token_must_still_match_each_episode_event(self):
        for stage in ('armed', 'verification', 'decision', 'terminal'):
            self.event(stage)['data']['token'] = -42
        for stage in ('verification', 'decision', 'terminal'):
            with self.subTest(stage=stage):
                self.event(stage)['data']['token'] = 42
                self.assert_rejected()
                self.event(stage)['data']['token'] = -42

    def test_intermediate_verified_posted_followed_by_terminal_muted_fails(self):
        self.event('terminal')['data']['outcome'] = 'MUTED'
        result = self.assert_rejected('TERMINAL_OUTCOME')
        self.assertEqual([o['outcome'] for o in result['ordered_outcomes']], ['POSTED', 'MUTED'])

    def test_intermediate_posted_alone_cannot_satisfy_terminal_outcome(self):
        self.events.remove(self.event('terminal'))
        self.resequence()
        self.assert_rejected('MISSING_TERMINAL')

    def test_approximate_outcome_or_verdict_cannot_satisfy_precise(self):
        for stage, key, value in [('terminal', 'outcome', 'POSTED_APPROXIMATE'),
                                  ('decision', 'verdict', 'FALLBACK')]:
            with self.subTest(stage=stage):
                data = self.event(stage)['data']
                original = data[key]
                data[key] = value
                self.assert_rejected()
                data[key] = original

    def test_wrong_full_android_identity_merchant_or_card_text_fails(self):
        data = self.event('android_post')['data']
        for key, value in [('package', 'other'), ('channel', 'other'), ('tag', 'other'), ('id', 1),
                           ('title', "You're near Other"), ('text', 'Use Other for 3%'),
                           ('big_text', 'Use Other for 3%')]:
            with self.subTest(key=key):
                original = data[key]
                data[key] = value
                self.assert_rejected('ANDROID_NOTIFICATION')
                data[key] = original

    def test_snapshot_cannot_replace_android_post_callback(self):
        self.event('android_post')['stage'] = 'android_snapshot'
        self.assert_rejected('UNKNOWN_STAGE')

    def test_duplicate_android_posts_including_update_callback_fail(self):
        index = self.events.index(self.event('android_post'))
        self.events.insert(index + 1, copy.deepcopy(self.events[index]))
        self.resequence()
        self.assert_rejected('DUPLICATE_STAGE')

    def test_post_then_remove_cannot_be_reported_as_active(self):
        event = copy.deepcopy(self.event('android_post'))
        event['stage'] = 'android_remove'
        self.events.insert(self.events.index(self.event('terminal')), event)
        self.resequence()
        self.assert_rejected('NOTIFICATION_REMOVED')

    def test_missing_listener_baseline_or_continuity_blocks(self):
        for stage, key, value in [('listener_start', 'active_arrivals', 1),
                                  ('listener_end', 'dropped_events', 1),
                                  ('listener_end', 'connected', False),
                                  ('listener_end', 'callback_seq', 3),
                                  ('listener_end', 'session_id', 'other')]:
            with self.subTest(stage=stage, key=key):
                data = self.event(stage)['data']
                original = data[key]
                data[key] = value
                self.assert_rejected(status='INFRASTRUCTURE-BLOCKED')
                data[key] = original

    def test_interrupted_adb_log_or_observation_blocks(self):
        for key in ('adb_connected', 'log_continuous', 'completed'):
            with self.subTest(key=key):
                data = self.event('observation_end')['data']
                data[key] = False
                self.assert_rejected('INCOMPLETE_OBSERVATION', 'INFRASTRUCTURE-BLOCKED')
                data[key] = True

    def test_partial_window_even_after_correct_post_fails(self):
        self.event('listener_end')['elapsed_ms'] -= 1
        self.event('observation_end')['elapsed_ms'] -= 1
        self.assert_rejected('PARTIAL_OBSERVATION_WINDOW')

    def test_late_collector_end_does_not_extend_an_early_listener_window(self):
        self.event('listener_end')['elapsed_ms'] = self.event('route_end')['elapsed_ms']
        self.assert_rejected('PARTIAL_OBSERVATION_WINDOW')

    def test_raw_sequence_reversal_or_timestamp_reversal_fails(self):
        self.events.reverse()
        self.assert_rejected('EVENT_SEQUENCE')
        self.events.reverse()
        self.event('enter')['elapsed_ms'] = 1
        self.assert_rejected('EVENT_TIME_ORDER')

    def test_resorted_sequences_do_not_hide_causal_reversal(self):
        a, b = self.events.index(self.event('armed')), self.events.index(self.event('enter'))
        self.events[a], self.events[b] = self.events[b], self.events[a]
        self.events[b]['elapsed_ms'], self.events[a]['elapsed_ms'] = 60_000, 60_100
        self.resequence()
        self.assert_rejected('STAGE_ORDER')

    def test_required_prerequisite_edges_reject_reversed_events(self):
        original = copy.deepcopy(self.events)
        for first, second in [('console_input', 'gps_sample'), ('console_input', 'flp_sample'),
                              ('seed', 'ranked'), ('ranked', 'gms_add'), ('gms_add', 'enter'),
                              ('listener_start', 'android_post')]:
            with self.subTest(edge=(first, second)):
                self.events = copy.deepcopy(original)
                a, b = self.events.index(self.event(first)), self.events.index(self.event(second))
                self.events[a], self.events[b] = self.events[b], self.events[a]
                self.events[a]['elapsed_ms'] = original[a]['elapsed_ms']
                self.events[b]['elapsed_ms'] = original[b]['elapsed_ms']
                self.resequence()
                self.assert_rejected('STAGE_ORDER')

    def test_wrong_run_or_wrong_context_evidence_fails(self):
        self.event('terminal')['run_id'] = 'q-' + 'c' * 32
        self.assert_rejected('EVENT_RUN_IDENTITY')
        self.event('terminal')['run_id'] = self.context['run_id']
        self.event('terminal')['context_sha256'] = '0' * 64
        self.assert_rejected('EVENT_RUN_IDENTITY')

    def test_candidate_config_artifact_and_seed_mismatch_fail(self):
        for key in ('candidate_sha', 'config_sha256', 'artifact_sha256', 'seed_sha256'):
            with self.subTest(key=key):
                original = self.context['identity'][key]
                self.context['identity'][key] = '0' * len(original)
                self.assert_rejected()
                self.context['identity'][key] = original

    def test_stale_run_and_future_events_fail(self):
        self.context['started_at_unix_ms'] = self.now - runner.MAX_EVIDENCE_AGE_MS - 1
        self.assert_rejected('STALE_RUN')
        self.context['started_at_unix_ms'] = self.now - 1
        self.rebind()
        self.assert_rejected('FUTURE_EVENTS')

    def test_wrong_entrypoint_build_image_or_source_fails(self):
        for key, value in [('entrypoint', 'lib/main.dart'), ('build_mode', 'release'),
                           ('input_source', 'controlled-flp-mock')]:
            with self.subTest(key=key):
                original = self.context['identity'][key]
                self.context['identity'][key] = value
                self.rebind()
                self.assert_rejected()
                self.context['identity'][key] = original
        self.context['identity']['environment']['image'] = 'owner-avd'
        self.assert_rejected('ENVIRONMENT')

    def test_unknown_scenario_text_is_rejected_without_retention(self):
        secret = 'SECRET_SENTINEL_DO_NOT_RETAIN'
        self.context['scenario'] = secret
        result = self.result()
        self.assertNotIn(secret, json.dumps(result))
        self.assertIsNone(result['scenario'])
        self.assertEqual(result['status'], 'FAIL')
        self.assertEqual(result['reasons'], ['SCENARIO'])

    def test_other_caller_supplied_context_text_is_not_retained(self):
        original = copy.deepcopy(self.context)
        paths = [('run_id',)] + [('identity', key) for key in runner.IDENTITY_FIELDS
                                if key != 'environment'] + [
            ('identity', 'environment', key) for key in ('image', 'api', 'abi', 'gms_version')]
        for path in paths:
            with self.subTest(path=path):
                self.context = copy.deepcopy(original)
                target = self.context
                for key in path[:-1]:
                    target = target[key]
                target[path[-1]] = 'SECRET_SENTINEL_DO_NOT_RETAIN'
                result = self.result()
                self.assertNotIn('SECRET_SENTINEL_DO_NOT_RETAIN', json.dumps(result))
                self.assertEqual(result['status'], 'FAIL')

    def test_unknown_schema_or_missing_identity_fails(self):
        self.context['schema_version'] = 2
        self.assert_rejected('SCHEMA_VERSION')
        self.context['schema_version'] = runner.VERSION
        del self.context['identity']['observer_sha256']
        self.assert_rejected('INVALID_FIELDS')

    def test_missing_accuracy_speed_and_age_remain_distinct(self):
        data = self.event('verification')['data']['sample']
        data['speed_mps'] = None
        self.assertEqual(self.result()['oracle_status'], 'PASS')
        for key, value in [('accuracy_m', None), ('accuracy_m', 100),
                           ('elapsed_realtime_ns', 1), ('elapsed_realtime_ns', 0),
                           ('elapsed_realtime_ns', data['observed_elapsed_ns'] + 1),
                           ('speed_mps', -1), ('speed_mps', float('nan'))]:
            with self.subTest(key=key, value=value):
                original = data[key]
                data[key] = value
                self.assert_rejected()
                data[key] = original

    def test_seed_pins_restaurant_inputs_geometry_and_cashback_currency(self):
        expected = {'merchant_lat': 39.237148, 'merchant_lon': -123.176090,
                    'fence_radius_m': 100, 'merchant_place_type': 'restaurant',
                    'merchant_business_status': 'OPERATIONAL'}
        self.assertEqual({key: runner.SEED.get(key) for key in expected}, expected)
        self.assertEqual([card.get('currency') for card in runner.SEED['cards']], ['USD', 'USD'])

    def test_verification_outside_fixture_circle_cannot_claim_verified(self):
        sample = self.event('verification')['data']['sample']
        for lat, lon in [(0, 0), (39.238148, -123.176090), (39.237148, -123.174090)]:
            with self.subTest(lat=lat, lon=lon):
                sample['lat'], sample['lon'] = lat, lon
                self.assert_rejected('VERIFICATION_GEOMETRY')

    def test_in_circle_verification_and_speed_boundary_pass(self):
        sample = self.event('verification')['data']['sample']
        # About 70 m from the fixed restaurant; not a centre-only equality test.
        sample['lat'], sample['lon'] = 39.237648, -123.175590
        for speed in (None, 0.0, 2.0):
            with self.subTest(speed=speed):
                sample['speed_mps'] = speed
                self.assertEqual(self.result()['oracle_status'], 'PASS')

    def test_definite_high_speed_cannot_claim_verified(self):
        for speed in (2.000001, 12.0):
            with self.subTest(speed=speed):
                self.event('verification')['data']['sample']['speed_mps'] = speed
                self.assert_rejected('VERIFICATION_MOTION')

    def test_console_input_must_be_seen_by_gps_and_flp(self):
        for stage in ('gps_sample', 'flp_sample'):
            with self.subTest(stage=stage):
                self.event(stage)['data']['lat'] += 0.01
                self.assert_rejected('INJECTION_NOT_OBSERVED')
                self.event(stage)['data']['lat'] -= 0.01

    def test_console_accuracy_is_not_an_invented_default(self):
        self.event('console_input')['data']['commanded_accuracy_m'] = 5
        self.assert_rejected('COMMANDED_INPUT')

    def test_default_location_provider_is_required(self):
        self.event('verification')['source'] = 'controlled-location-provider'
        self.assert_rejected('OBSERVATION_SOURCE')

    def test_premature_alarm_and_modified_original_deadline_fail(self):
        self.event('verification')['data']['sample']['observed_elapsed_ns'] -= 1
        self.event('verification')['data']['sample']['elapsed_realtime_ns'] -= 1
        self.assert_rejected('PREMATURE_VERIFICATION')
        self.event('armed')['data']['due_elapsed_ns'] += 1
        self.assert_rejected('ATTEMPT_DEADLINES')

    def test_replay_count_span_and_shared_parser_route_identity_are_required(self):
        data = self.event('route_end')['data']
        data['points_sent'] -= 1
        self.assert_rejected('ROUTE_INCOMPLETE')
        data['points_sent'] += 1
        self.event('route_end')['elapsed_ms'] -= 1
        self.assert_rejected('ROUTE_TIMING')
        self.context['identity']['route_sha256'] = '0' * 64
        self.assert_rejected('ROUTE_IDENTITY')

    def test_size_and_time_bounds(self):
        self.events = self.events * (runner.MAX_EVENTS + 1)
        self.assert_rejected('NO_BOUNDED_EVENTS')
        self.context, self.events, self.now = synthetic_run()
        self.event('observation_end')['elapsed_ms'] = runner.MAX_RUN_MS + 1
        self.assert_rejected('EVENT_TIME_ORDER')

    def test_json_booleans_are_not_interchangeable_with_integer_one(self):
        self.event('gms_add')['data']['success'] = 1
        self.assert_rejected('GMS_ADD_NOT_OBSERVED')

    def test_sample_elapsed_identity_cannot_silently_change_clock_origin(self):
        data = self.event('verification')['data']['sample']
        data['observed_elapsed_ns'] += 2_000_000_000
        data['elapsed_realtime_ns'] += 2_000_000_000
        self.assert_rejected('ELAPSED_CLOCK_MISMATCH')

    def test_result_does_not_copy_raw_input_errors_logs_or_coordinates(self):
        self.event('diagnostics_ready')['data']['stdout'] = 'SECRET-VALUE no matching activities'
        result = self.assert_rejected(status='INFRASTRUCTURE-BLOCKED')
        output = json.dumps(result)
        self.assertNotIn('SECRET-VALUE', output)
        self.assertNotIn(str(self.event('gps_sample')['data']['lat']), output)
        self.assertNotIn(runner.TITLE, output)
        self.assertEqual(result['evidence'][0]['sha256'], runner.digest(result['observed_stages']))


class CommandReplyTests(unittest.TestCase):
    def test_semantic_or_unknown_or_empty_success_is_blocked(self):
        for output in ('', 'OK', '  KO: rejected', 'Unknown command: dump',
                       'Error: no matching activities', 'No activities found',
                       'Diagnostics unavailable', 'Permission denied', 'Failure [not found]'):
            for kind in ('adb_ready', 'log_ready', 'diagnostics_ready'):
                with self.subTest(output=output, kind=kind), self.assertRaises(runner.EvidenceError) as caught:
                    runner.checked_output(kind, 0, output, '', 'q-' + 'a' * 32)
                self.assertEqual(caught.exception.status, 'INFRASTRUCTURE-BLOCKED')

    def test_nonzero_timeout_equivalent_stderr_ko_and_unknown_check_fail(self):
        for returncode, stdout, stderr in [(1, 'device', ''), (None, '', ''),
                                           (0, 'device', '  KO: failure'),
                                           (0, 'device', 'unknown status')]:
            with self.subTest(returncode=returncode, stderr=stderr), self.assertRaises(runner.EvidenceError):
                runner.checked_output('adb_ready', returncode, stdout, stderr, 'q-' + 'a' * 32)
        with self.assertRaises(runner.EvidenceError):
            runner.checked_output('unknown', 0, 'device', '', 'q-' + 'a' * 32)


class CLISafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.context, self.events, _ = synthetic_run()
        self.context_path = self.directory / 'context.json'
        self.trace_path = self.directory / 'trace.json'
        self.output_path = self.directory / 'result.json'
        self.context_path.write_text(json.dumps(self.context))
        self.trace_path.write_text(json.dumps(self.events))

    def args(self):
        return ['evaluate', '--context', str(self.context_path), '--trace', str(self.trace_path),
                '--output', str(self.output_path)]

    def invoke(self, args):
        with mock.patch.object(subprocess, 'run', side_effect=AssertionError('No device command allowed')), \
                mock.patch.object(subprocess, 'Popen', side_effect=AssertionError('No device process allowed')), \
                redirect_stdout(StringIO()), redirect_stderr(StringIO()):
            return runner.main(args)

    def test_device_lane_blocks_without_any_subprocess(self):
        self.assertEqual(self.invoke(['device', '--output', str(self.output_path)]), 2)
        result = json.loads(self.output_path.read_text())
        self.assertEqual(result['status'], 'INFRASTRUCTURE-BLOCKED')
        self.assertFalse(result['identity_verified'])

    def test_explicit_owner_serial_and_legacy_auto_targeting_are_rejected(self):
        for args in (['--serial', 'emulator-5554'], ['--serial', 'physical-device-sentinel'],
                     ['--scenario', 'all'], ['device', '--serial', 'emulator-5570',
                                            '--output', str(self.output_path)]):
            with self.subTest(args=args), self.assertRaises(SystemExit) as caught:
                self.invoke(args)
            self.assertEqual(caught.exception.code, 2)
        self.assertFalse(self.output_path.exists())

    def test_offline_positive_still_has_nonzero_not_covered_exit(self):
        self.assertEqual(self.invoke(self.args()), 3)
        result = json.loads(self.output_path.read_text())
        self.assertEqual(result['oracle_status'], 'PASS')
        self.assertEqual(result['status'], 'NOT-COVERED')

    def test_missing_input_and_malformed_json_get_failure_artifact(self):
        self.trace_path.unlink()
        self.assertEqual(self.invoke(self.args()), 1)
        self.assertEqual(json.loads(self.output_path.read_text())['status'], 'FAIL')
        self.output_path.unlink()
        self.trace_path.write_text('not-json SECRET-VALUE')
        self.assertEqual(self.invoke(self.args()), 1)
        self.assertNotIn('SECRET-VALUE', self.output_path.read_text())

    def test_cancelled_read_gets_block_artifact(self):
        with mock.patch.object(runner, 'read_json', side_effect=KeyboardInterrupt):
            self.assertEqual(self.invoke(self.args()), 2)
        self.assertEqual(json.loads(self.output_path.read_text())['reasons'], ['CANCELLED'])

    def test_output_never_overwrites_owner_input_existing_result_or_symlink(self):
        self.output_path.write_text('owner-evidence')
        self.assertEqual(self.invoke(self.args()), 2)
        self.assertEqual(self.output_path.read_text(), 'owner-evidence')
        self.output_path.unlink()
        self.output_path.symlink_to(self.context_path)
        before = self.context_path.read_bytes()
        self.assertEqual(self.invoke(self.args()), 2)
        self.assertEqual(self.context_path.read_bytes(), before)

    def test_oversized_duplicate_key_nonfinite_and_deep_json_rejected(self):
        for value in (' ' * (runner.MAX_BYTES + 1), '{"schema_version":1,"schema_version":1}',
                      '[NaN]', '[' * 2_000):
            with self.subTest(kind=value[:30]):
                self.trace_path.write_text(value)
                self.assertEqual(self.invoke(self.args()), 1)
                self.assertEqual(json.loads(self.output_path.read_text())['status'], 'FAIL')
                self.output_path.unlink()

    def test_missing_parent_output_path_fails_nonzero_without_raw_path(self):
        with redirect_stderr(StringIO()) as err, redirect_stdout(StringIO()):
            code = runner.main(['device', '--output', str(self.directory / 'missing' / 'out.json')])
        self.assertEqual(code, 2)
        self.assertNotIn(str(self.directory), err.getvalue())
