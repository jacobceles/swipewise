"""Text-level trigger contract; not evidence that a workflow or device ran."""

import re
import unittest
from pathlib import Path


WORKFLOW = Path(__file__).resolve().parents[1] / '.github/workflows/geofence-e2e.yml'


class GeofenceWorkflowTriggerTests(unittest.TestCase):
    def triggers(self):
        match = re.search(r'^on:\n(.*?)(?=^[a-zA-Z][\w-]*:|\Z)',
                          WORKFLOW.read_text(), re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(match, 'Missing workflow trigger block')
        return match.group(1)

    def test_main_push_runs_qualification(self):
        self.assertRegex(self.triggers(), r'(?m)^  push:\n    branches: \[main\]$')

    def test_all_pull_requests_run_qualification(self):
        self.assertRegex(self.triggers(), r'(?m)^  pull_request: \{\}$')

    def test_manual_qualification_remains_available(self):
        self.assertRegex(self.triggers(), r'(?m)^  workflow_dispatch: \{\}$')

    def test_path_filters_cannot_omit_build_or_harness_inputs(self):
        self.assertNotRegex(self.triggers(), r'(?m)^\s+(?:paths|paths-ignore):')


class GeofenceWorkflowExecutionTests(unittest.TestCase):
    def test_device_job_uses_supported_ubuntu_runner(self):
        workflow = WORKFLOW.read_text()
        self.assertRegex(workflow, r'(?m)^    runs-on: ubuntu-24\.04$')
        self.assertNotIn('runs-on: macos-14', workflow)

    def test_device_job_runs_qualification_contract_not_removed_legacy_cli(self):
        workflow = WORKFLOW.read_text()
        self.assertIn('tool/geofence_qualification/check_oracle_mutations.py', workflow)
        self.assertIn('tool/geofence_qualification/observer', workflow)
        self.assertNotIn('python3 tool/test_geofence_e2e.py -v', workflow)
        self.assertNotIn('SCHEDULE_EXACT_ALARM 2>/dev/null || true', workflow)


if __name__ == '__main__':
    unittest.main()
