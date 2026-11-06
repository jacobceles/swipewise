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


if __name__ == '__main__':
    unittest.main()
