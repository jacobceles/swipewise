"""Offline oracle controls; these are never reported as Android execution."""

import copy
import hashlib
import json
import sys
import types
import unittest
from pathlib import Path
from unittest import mock

from geofence_qualification import os_smoke as smoke
from geofence_qualification import owned_avd


def example(muted):
    dwell = smoke.DWELL_SECONDS
    created = 100_000_000_000
    due = created + dwell * 1_000_000_000
    arm = {'token': -42, 'phase': 'ARMED', 'accountEpoch': 1, 'metadataGeneration': 1,
           'bootCount': 1, 'createdAtElapsedNanos': created, 'scheduledDueElapsedNanos': due,
           'deadlineElapsedNanos': created + (dwell * 2 + 120) * 1_000_000_000}
    seed = {'action': 'seed-muted' if muted else 'unmute-register', 'wallet_count': 2,
            'dwell_seconds': dwell, 'card_name': 'Qualification Dining', 'rate': 3.0,
            'currency': 'USD', 'muted': muted, 'cache_current_complete': True,
            'remote_search_calls': 0, 'remote_catalog_disabled': True}
    zone = {'geofence_id': smoke.FENCE, 'dwell_seconds': dwell, 'lat': smoke.LAT,
            'lng': smoke.LON, 'radius_m': 100, 'options': [{'best_card_name': 'Qualification Dining',
            'best_rate': 3, 'best_currency': 'USD', 'muted': muted}]}
    fix = {'available': True, 'provider': 'fused', 'is_mock': False, 'lat': smoke.LAT,
           'lon': smoke.LON, 'accuracy_m': 5, 'speed_mps': 0,
           'elapsed_realtime_ns': due, 'observed_elapsed_ns': due}
    pairs = [
        ('seed_readback', seed, 2_000_000_000),
        ('ranking_payload', {'account_epoch': 1, 'zones': [zone]}, 3_000_000_000),
        ('register_result', {'count': 1, 'diagnostics': 'REGISTRATION_OK value=1\n' * (1 if muted else 2)}, 4_000_000_000),
        ('attempts', {smoke.FENCE: arm}, created),
        ('verification_request', {'delegate': 'DefaultLocationProvider', 'priority': 102,
                                 'duration_ms': 8000, 'max_age_ms': 15000,
                                 'attempts': {smoke.FENCE: arm}}, due),
        ('verification_sample', {'sample': fix, 'attempts': {smoke.FENCE: arm}}, due + 1),
    ]
    if not muted:
        pairs += [('poster_call', {'approximate': False, 'fence': smoke.FENCE,
                                  'attempts': {smoke.FENCE: arm}}, due + 2),
                  ('poster_result', {'submitted': True}, due + 3)]
    outcome = 'MUTED' if muted else 'POSTED'
    end = created + smoke.WINDOW_NS + 5_000_000_000
    pairs += [('walkin', {'text': f'fence ENTER {smoke.FENCE} acc=5\n' * (1 if muted else 2) +
                         f'verdict=VERIFIED, outcome=POSTED\ndwell {smoke.FENCE}: '
                         f'{outcome.lower()} Qualification Restaurant'}, due + 4),
              ('diagnostics', {'text': 'OUTCOME_' + outcome}, due + 5),
              ('attempts', {}, due + 6), ('heartbeat', {}, end - 1)]
    native = [{'seq': i, 'stage': stage, 'data': data, 'elapsed_ns': at}
              for i, (stage, data, at) in enumerate(pairs)]
    item = {'package': smoke.PACKAGE, 'channel': 'swipewise_dwell', 'tag': 'swipewise.arrival',
            'id': 0, 'title': "You're near Qualification Restaurant", 'text': 'Use Qualification Dining for 3%',
            'big_text': 'Use Qualification Dining for 3%', 'key': 'synthetic-key'}
    listener = [
        {'seq': 0, 'stage': 'listener_connected', 'data': {'active': []}, 'elapsed_ns': 1},
        {'seq': 1, 'stage': 'listener_snapshot', 'data': {'connected': True, 'active': []}, 'elapsed_ns': 1_000_000_000},
    ]
    if not muted:
        listener.append({'seq': 2, 'stage': 'listener_post', 'data': {'change': 'post', 'notification': item},
                         'elapsed_ns': due + 2})
    listener.append({'seq': len(listener), 'stage': 'listener_snapshot',
                     'data': {'connected': True, 'active': [] if muted else [item]}, 'elapsed_ns': end})
    return native, listener


class EpisodeTests(unittest.TestCase):
    def check(self, native, listener, muted):
        return smoke.episode(native, listener, 0, 1, len(listener) - 1, muted)

    def test_positive_and_causally_active_muted_control(self):
        for muted in (True, False):
            with self.subTest(muted=muted):
                result = self.check(*example(muted), muted)
                self.assertEqual(result['status'], 'PASS')
                self.assertEqual(result['native_poster_calls'], 0 if muted else 1)

    def test_empty_or_unexercised_negative_never_passes(self):
        for stage in ('seed_readback', 'ranking_payload', 'register_result', 'attempts',
                      'verification_request', 'verification_sample', 'walkin', 'diagnostics', 'heartbeat'):
            native, listener = example(True)
            with self.subTest(stage=stage), self.assertRaises(smoke.SmokeFailure):
                self.check([e for e in native if e['stage'] != stage], listener, True)
        with self.assertRaises(smoke.SmokeFailure):
            self.check([], [], True)

    def test_both_cases_require_complete_window(self):
        for muted in (True, False):
            native, listener = example(muted)
            listener[-1]['elapsed_ns'] = 100_000_000_000 + smoke.WINDOW_NS - 1
            with self.subTest(muted=muted), self.assertRaisesRegex(smoke.SmokeFailure, 'COMPLETE_WINDOW'):
                self.check(native, listener, muted)

    def test_negative_requires_zero_callbacks_and_poster_calls(self):
        for source in ('native', 'android'):
            native, listener = example(True)
            if source == 'native':
                native.insert(6, {'stage': 'poster_call', 'data': {}, 'elapsed_ns': 110_000_000_002})
            else:
                listener.insert(2, {'stage': 'listener_post', 'data': {}, 'elapsed_ns': 110_000_000_002})
            with self.subTest(source=source), self.assertRaises(smoke.SmokeFailure):
                self.check(native, listener, True)

    def test_intermediate_verified_posted_then_muted_is_not_positive(self):
        native, listener = example(False)
        next(e for e in native if e['stage'] == 'diagnostics')['data']['text'] = 'OUTCOME_MUTED'
        with self.assertRaisesRegex(smoke.SmokeFailure, 'TERMINAL_DIAGNOSTIC'):
            self.check(native, listener, False)

    def test_wrong_android_content_removal_update_duplicate_and_listener_gap_fail(self):
        for change in ('content', 'remove', 'update', 'duplicate', 'gap', 'late-baseline'):
            native, listener = example(False)
            if change == 'content':
                listener[2]['data']['notification']['text'] = 'another card'
            elif change == 'remove':
                listener[2]['stage'] = 'listener_remove'
            elif change == 'update':
                listener[2]['data']['change'] = 'update'
            elif change == 'duplicate':
                listener.insert(3, copy.deepcopy(listener[2]))
            elif change == 'gap':
                listener.insert(3, {'stage': 'listener_disconnected', 'data': {}, 'elapsed_ns': 110_000_000_004})
            else:
                listener[1]['elapsed_ns'] = native[0]['elapsed_ns'] + 1
            with self.subTest(change=change), self.assertRaises(smoke.SmokeFailure):
                self.check(native, listener, False)

    def test_default_verifier_token_geometry_freshness_and_mock_are_not_overridden(self):
        for change in ('priority', 'token', 'geometry', 'stale', 'mock', 'moving', 'dwell', 'gms', 'enter'):
            native, listener = example(False)
            request = next(e for e in native if e['stage'] == 'verification_request')
            fix = next(e for e in native if e['stage'] == 'verification_sample')['data']['sample']
            if change == 'priority':
                request['data']['priority'] = 100
            elif change == 'token':
                request['data']['attempts'] = {smoke.FENCE: {'token': 99}}
            elif change == 'geometry':
                fix['lat'] = 0
            elif change == 'stale':
                fix['elapsed_realtime_ns'] -= 16_000_000_000
            elif change == 'mock':
                fix['is_mock'] = True
            elif change == 'moving':
                fix['speed_mps'] = 3
            elif change == 'dwell':
                native[0]['data']['dwell_seconds'] += 1
            elif change == 'gms':
                native[2]['data']['diagnostics'] = ''
            else:
                next(e for e in native if e['stage'] == 'walkin')['data']['text'] = 'verdict=VERIFIED, outcome=POSTED'
            with self.subTest(change=change), self.assertRaises(smoke.SmokeFailure):
                self.check(native, listener, False)

    def test_signed_long_limits_are_valid_zero_bool_and_overflow_are_not(self):
        for token in (-(1 << 63), -42, (1 << 63) - 1, 0, True, 1 << 63):
            native, listener = example(True)
            native[3]['data'][smoke.FENCE]['token'] = token
            if type(token) is int and token != 0 and -(1 << 63) <= token < (1 << 63):
                self.assertEqual(self.check(native, listener, True)['status'], 'PASS')
            else:
                with self.subTest(token=token), self.assertRaisesRegex(smoke.SmokeFailure, 'SIGNED_ATTEMPT_TOKEN'):
                    self.check(native, listener, True)


class HostTests(unittest.TestCase):
    def test_only_installed_platform_allowlist_is_selected(self):
        for system, machine, abi in [('Darwin', 'arm64', 'arm64-v8a'), ('Linux', 'x86_64', 'x86_64')]:
            with mock.patch.object(owned_avd.platform, 'system', return_value=system), \
                    mock.patch.object(owned_avd.platform, 'machine', return_value=machine):
                self.assertEqual(owned_avd.image_spec()[1], abi)
        with mock.patch.object(owned_avd.platform, 'system', return_value='Windows'):
            with self.assertRaises(owned_avd.InfrastructureError):
                owned_avd.image_spec()


def oracle_mutations():
    path = Path(smoke.__file__)
    before = hashlib.sha256(path.read_bytes()).hexdigest()
    source = path.read_text()
    cases = [
        ('full-window', "end['elapsed_ns'] >= attempt['createdAtElapsedNanos'] + WINDOW_NS", 'True',
         'test_both_cases_require_complete_window'),
        ('negative-no-callback', "len(observed) == (0 if muted else 1)", '(muted or len(observed) == 1)',
         'test_negative_requires_zero_callbacks_and_poster_calls'),
        ('terminal-not-intermediate', "diagnostics[-1].splitlines()[-1].endswith(f'OUTCOME_{outcome}')", 'True',
         'test_intermediate_verified_posted_then_muted_is_not_positive'),
        ('actual-add-not-metadata', "results[0]['data']['diagnostics'].count('REGISTRATION_OK value=1') == (1 if muted else 2)",
         'True', 'test_default_verifier_token_geometry_freshness_and_mock_are_not_overridden'),
        ('default-balanced', "req['data']['priority'] == 102", 'True',
         'test_default_verifier_token_geometry_freshness_and_mock_are_not_overridden'),
        ('listener-no-gap', "not any(e['stage'] == 'listener_disconnected' for e in listener)", 'True',
         'test_wrong_android_content_removal_update_duplicate_and_listener_gap_fail'),
    ]
    results = []
    module = sys.modules[__name__]
    for name, find, replace, test in cases:
        if source.count(find) != 1:
            raise AssertionError('mutation target missing: ' + name)
        mutant = types.ModuleType('smoke_mutant')
        mutant.__file__ = str(path)
        exec(compile(source.replace(find, replace), str(path), 'exec'), mutant.__dict__)
        outcome = unittest.TestResult()
        with mock.patch.object(module, 'smoke', mutant):
            unittest.TestSuite([EpisodeTests('test_positive_and_causally_active_muted_control'),
                                EpisodeTests(test)]).run(outcome)
        results.append({'mutation': name, 'detected': bool(outcome.failures) and not outcome.errors and
                        all(test in case.id() for case, _ in outcome.failures)})
    return {'status': 'PASS' if all(r['detected'] for r in results) else 'FAIL', 'mutations': results,
            'source_unchanged': hashlib.sha256(path.read_bytes()).hexdigest() == before}


class MutationTests(unittest.TestCase):
    def test_actual_oracle_mutations_fail_with_passing_controls(self):
        result = oracle_mutations()
        self.assertEqual(result['status'], 'PASS', json.dumps(result))
        self.assertTrue(result['source_unchanged'])
