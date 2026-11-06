#!/usr/bin/env python3
"""Mutate actual oracle assertions in memory; never edit source or touch a device."""

import argparse
import hashlib
import io
import json
import sys
import types
import unittest
from pathlib import Path
from unittest import mock

TOOL = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TOOL))
import test_geofence_e2e_runner as tests  # noqa: E402

MUTATIONS = [
    ('observer-before-seed',
     "before('listener_start', 'seed')", 'pass',
     'test_listener_must_be_live_before_seeding'),
    ('route-before-enter',
     "before('route_start', 'enter')", 'pass',
     'test_enter_before_replay_cannot_prove_route_arrival'),
    ('terminal-outcome',
     "exact(one('terminal'), {**episode, **advice, 'outcome': 'POSTED'}, 'TERMINAL_OUTCOME')",
     "one('terminal')",
     'test_intermediate_verified_posted_followed_by_terminal_muted_fails'),
    ('android-content',
     "'title': TITLE, 'text': TEXT, 'big_text': TEXT}, 'ANDROID_NOTIFICATION')",
     "'title': post['title'], 'text': post['text'], 'big_text': post['big_text']}, 'ANDROID_NOTIFICATION')",
     'test_wrong_full_android_identity_merchant_or_card_text_fails'),
    ('duplicate-post',
     "require(stage not in by_stage, 'DUPLICATE_STAGE')", 'pass',
     'test_duplicate_android_posts_including_update_callback_fail'),
    ('full-observation-window',
     "require(by_stage['observation_end']['elapsed_ms'] >= required_end_ms and\n"
     "            by_stage['listener_end']['elapsed_ms'] >= required_end_ms and\n"
     "            by_stage['observation_end']['elapsed_ms'] - by_stage['listener_end']['elapsed_ms'] <= 1_000,",
     'require(True,',
     'test_partial_window_even_after_correct_post_fails'),
    ('run-binding',
     "require(event['run_id'] == context['run_id'] and event['context_sha256'] == digest(context),",
     'require(True,',
     'test_wrong_run_or_wrong_context_evidence_fails'),
    ('causal-order',
     "require(by_stage[a]['seq'] < by_stage[b]['seq'], 'STAGE_ORDER')", 'pass',
     'test_resorted_sequences_do_not_hide_causal_reversal'),
    ('elapsed-sample-identity',
     "require(abs(android_delta - host_delta) <= 1_000_000_000, 'ELAPSED_CLOCK_MISMATCH')", 'pass',
     'test_sample_elapsed_identity_cannot_silently_change_clock_origin'),
    ('semantic-command-check',
     "    bad = r'(?im)", "    return\n    bad = r'(?im)",
     'test_result_does_not_copy_raw_input_errors_logs_or_coordinates'),
    ('signed-long-token',
     "type(arm['token']) is int and -(1 << 63) <= arm['token'] < (1 << 63) and\n"
     "            arm['token'] != 0", "integer(arm['token'], 1)",
     'test_signed_long_nonzero_attempt_tokens_pass'),
    ('token-range',
     "-(1 << 63) <= arm['token'] < (1 << 63)", 'True',
     'test_zero_boolean_noninteger_and_out_of_range_tokens_fail'),
    ('scenario-privacy',
     " and context['scenario'] in SCENARIOS", '',
     'test_unknown_scenario_text_is_rejected_without_retention'),
    ('verification-geometry',
     "require(math.hypot(north_m, east_m) <= SEED['fence_radius_m'], 'VERIFICATION_GEOMETRY')", 'pass',
     'test_verification_outside_fixture_circle_cannot_claim_verified'),
    ('verification-motion',
     "require(sample['speed_mps'] is None or sample['speed_mps'] <= 2.0, 'VERIFICATION_MOTION')", 'pass',
     'test_definite_high_speed_cannot_claim_verified'),
]


def check_mutations():
    paths = [TOOL / 'test_geofence_e2e.py', TOOL / 'test_geofence_e2e_runner.py']
    before = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    source = paths[0].read_text()
    results = []
    for name, find, replace, test_name in MUTATIONS:
        if source.count(find) != 1:
            raise RuntimeError(f'Mutation no longer matches exactly once: {name}')
        mutant = types.ModuleType('geofence_oracle_mutant')
        mutant.__file__ = str(paths[0])
        exec(compile(source.replace(find, replace), str(paths[0]), 'exec'), mutant.__dict__)
        # The positive control must still pass, and the targeted assertion must
        # fail (not error). No copying the predicate or testing a fake verdict.
        suite = unittest.TestSuite([
            tests.OracleTests('test_complete_trace_passes_oracle_but_never_device_qualification'),
            tests.OracleTests(test_name),
        ])
        with mock.patch.object(tests, 'runner', mutant):
            outcome = unittest.TextTestRunner(stream=io.StringIO()).run(suite)
        # A table-driven target can produce several failing subtests. Only its
        # assertion failures count; an error or failing positive control does not.
        detected = (outcome.testsRun == 2 and not outcome.errors and bool(outcome.failures)
                    and all(test_name in failed.id() for failed, _ in outcome.failures))
        results.append({'mutation': name, 'tests_run': outcome.testsRun,
                        'failures': len(outcome.failures), 'errors': len(outcome.errors),
                        'detected': detected})
    after = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    return {'schema_version': 1, 'scope': 'offline-oracle-mutations',
            'status': 'PASS' if before == after and all(r['detected'] for r in results) else 'FAIL',
            'mutation_mode': 'in-memory actual source; original module restored after each case',
            'source_hashes_before': before, 'source_hashes_after': after, 'mutations': results}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    report = check_mutations()
    with args.output.open('x') as handle:
        json.dump(report, handle, indent=2, sort_keys=True)
        handle.write('\n')
    print(f"{report['status']}: {sum(r['detected'] for r in report['mutations'])}/{len(MUTATIONS)} mutations detected")
    return 0 if report['status'] == 'PASS' else 1


if __name__ == '__main__':
    sys.exit(main())
