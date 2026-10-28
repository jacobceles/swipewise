"""Offline tests for the catalog freshness gate; never contact the live API."""

import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import check_catalog_floor as gate


class CatalogFloorTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.keys = Path(directory.name) / "keys.json"
        self.catalog = Path(directory.name) / "catalog.json"
        self.keys.write_text(json.dumps({"R2_BASE_URL": "https://assets.example"}))
        self.catalog.write_text('{"dataVersion": 12}')
        self.real_run = subprocess.run
        self.fetch = self.enterContext(patch.object(gate.subprocess, "run"))
        self.sleep = self.enterContext(patch.object(gate.time, "sleep"))
        self.enterContext(contextlib.redirect_stdout(io.StringIO()))
        self.fetch.return_value = subprocess.CompletedProcess(
            [], 0, '{"dataVersion": 12}', ""
        )

    def run_gate(self):
        return gate.main(keys_file=self.keys, catalog_file=self.catalog)

    def test_equal_versions_pass(self):
        self.assertEqual(self.run_gate(), 0)
        self.assertEqual(self.fetch.call_count, 1)
        self.sleep.assert_not_called()

    def test_both_older_and_newer_bundle_fail(self):
        for live in (11, 13):
            with self.subTest(live=live):
                self.fetch.return_value.stdout = json.dumps({"dataVersion": live})
                self.assertEqual(self.run_gate(), 1)

    def test_transport_failures_exhaust_retries_then_fail(self):
        for error in (
            subprocess.CalledProcessError(22, "curl"),
            subprocess.TimeoutExpired("curl", 20),
            OSError("curl unavailable"),
        ):
            with self.subTest(error=type(error).__name__):
                self.fetch.reset_mock()
                self.sleep.reset_mock()
                self.fetch.side_effect = error
                self.assertEqual(self.run_gate(), 1)
                self.assertEqual(self.fetch.call_count, 3)
                self.assertEqual(self.sleep.call_count, 2)

    def test_transient_failure_recovers(self):
        success = self.fetch.return_value
        self.fetch.side_effect = [subprocess.CalledProcessError(22, "curl"), success]
        self.assertEqual(self.run_gate(), 0)
        self.assertEqual(self.fetch.call_count, 2)
        self.sleep.assert_called_once_with(2)

    def test_malformed_response_can_recover(self):
        self.fetch.side_effect = [
            subprocess.CompletedProcess([], 0, "{broken", ""),
            self.fetch.return_value,
        ]
        self.assertEqual(self.run_gate(), 0)
        self.assertEqual(self.fetch.call_count, 2)

    def test_invalid_live_data_never_passes(self):
        for body in (
            "",
            "not-json",
            "null",
            "[]",
            "{}",
            '{"dataVersion":true}',
            '{"dataVersion":"12"}',
            '{"dataVersion":0}',
            '{"dataVersion":-1}',
            '{"dataVersion":12.0}',
        ):
            with self.subTest(body=body):
                self.fetch.reset_mock()
                self.fetch.return_value.stdout = body
                self.assertEqual(self.run_gate(), 1)
                self.assertEqual(self.fetch.call_count, 3)

    def test_invalid_bundle_fails_before_network(self):
        for body in ("{broken", "{}", '{"dataVersion":true}'):
            with self.subTest(body=body):
                self.catalog.write_text(body)
                self.assertEqual(self.run_gate(), 1)
                self.fetch.assert_not_called()

    def test_invalid_config_fails_before_network(self):
        for config in (
            {},
            {"R2_BASE_URL": ""},
            {"R2_BASE_URL": None},
            {"R2_BASE_URL": "file:///secret"},
            {"R2_BASE_URL": "https:///catalog"},
            [],
        ):
            with self.subTest(config=config):
                self.keys.write_text(json.dumps(config))
                self.assertEqual(self.run_gate(), 1)
                self.fetch.assert_not_called()

    def test_missing_inputs_fail(self):
        self.keys.unlink()
        self.assertEqual(self.run_gate(), 1)
        self.fetch.assert_not_called()

    def test_each_fetch_has_network_and_process_time_bounds(self):
        self.assertEqual(self.run_gate(), 0)
        args, options = self.fetch.call_args
        command = args[0]
        self.assertEqual(command[0], "curl")
        self.assertIn("--fail", command)
        self.assertEqual(command[command.index("--connect-timeout") + 1], "5")
        self.assertEqual(command[command.index("--max-time") + 1], "15")
        self.assertEqual(command[-1], "https://assets.example/catalog.json")
        self.assertEqual(options["timeout"], 20)
        self.assertTrue(options["check"])

    def test_workflow_runs_tests_and_gate_and_triggers_for_config(self):
        workflow = (
            Path(__file__).resolve().parents[1] / ".github/workflows/app.yml"
        ).read_text()
        self.assertIn("python3 -m unittest discover -s tool -p 'test_*.py'", workflow)
        self.assertIn("run: python3 tool/check_catalog_floor.py", workflow)
        self.assertEqual(workflow.count("- 'keys.free.json'"), 2)
        self.assertEqual(workflow.count("- '.github/workflows/app.yml'"), 2)

    def test_cli_exit_status_matches_freshness_result(self):
        directory = self.keys.parent
        (directory / "keys.free.json").write_text(self.keys.read_text())
        catalog = directory / "assets/catalog/free.json"
        catalog.parent.mkdir(parents=True)
        catalog.write_text(self.catalog.read_text())
        fake_curl = directory / "curl"
        script = Path(gate.__file__).resolve()
        # Use the real process runner; only the external curl executable is fake.
        for live, expected in ((12, 0), (13, 1)):
            with self.subTest(live=live):
                fake_curl.write_text(
                    f"#!/bin/sh\nprintf '%s' '{{\"dataVersion\":{live}}}'\n"
                )
                fake_curl.chmod(0o755)
                result = self.real_run(
                    [os.sys.executable, str(script)],
                    cwd=directory,
                    env={
                        **os.environ,
                        "PATH": str(directory) + os.pathsep + os.environ["PATH"],
                    },
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
                self.assertEqual(
                    result.returncode, expected, result.stdout + result.stderr
                )


if __name__ == "__main__":
    unittest.main()
