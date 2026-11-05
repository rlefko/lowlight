# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Keep parallel CI complete and execute its real fail-closed merge gate."""
from collections import Counter
import json
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = {"quality", "build", "native", "audio_debug", "audio", "size", "codeql"}


class WorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Ruby/Psych is already used by the repository and available on the Quality runner.
        # Read the actual YAML without adding a Python dependency or approximating its syntax.
        cls.workflow = json.loads(subprocess.check_output([
            "ruby", "-rjson", "-ryaml", "-e",
            'puts JSON.generate(YAML.load_file(ARGV.fetch(0)))',
            str(ROOT / ".github/workflows/ci.yml"),
        ], text=True))
        cls.jobs = cls.workflow["jobs"]

    def test_every_existing_test_command_runs_once_without_filters_or_allow_failure(self):
        expected = {
            "build": ["scripts/build test"],
            "native": ["scripts/test-planner", "scripts/test-planner release",
                       "scripts/test-dsp", "scripts/test-audio release"],
            "audio_debug": ["scripts/test-audio"],
        }
        all_commands = Counter(step.get("run", "").strip()
                               for job in self.jobs.values() for step in job["steps"])
        for name, commands in expected.items():
            job = self.jobs[name]
            self.assertNotIn("needs", job, name)
            self.assertNotIn("if", job, name)
            self.assertFalse(job.get("continue-on-error", False), name)
            self.assertEqual(job["runs-on"], "macos-26")
            self.assertEqual([s["run"] for s in job["steps"] if "run" in s], commands)
            for step in job["steps"]:
                self.assertFalse(step.get("continue-on-error", False), step)
                if "run" in step:
                    self.assertNotIn("if", step)
            for command in commands:
                self.assertEqual(all_commands[command], 1, command)

    def test_reference_audio_waits_for_its_unique_release_artifact_producer(self):
        self.assertEqual(self.jobs["audio"]["needs"], "native")
        producers = [(name, step) for name, job in self.jobs.items() for step in job["steps"]
                     if step.get("uses", "").startswith("actions/upload-artifact@")
                     and step.get("with", {}).get("name") == "native-tonal-candidates"]
        self.assertEqual(len(producers), 1)
        name, upload = producers[0]
        self.assertEqual(name, "native")
        self.assertEqual(upload["with"]["path"], ".build/tonal-native")
        self.assertEqual(upload["with"]["if-no-files-found"], "error")
        release = next(s for s in self.jobs[name]["steps"]
                       if s.get("run") == "scripts/test-audio release")
        self.assertEqual(release["env"]["LOWLIGHT_AUDIO_OUTPUT"],
                         "${{ github.workspace }}/.build/tonal-native")
        downloads = [s for s in self.jobs["audio"]["steps"]
                     if s.get("uses", "").startswith("actions/download-artifact@")]
        self.assertEqual(len(downloads), 1)
        self.assertEqual(downloads[0]["with"]["name"], "native-tonal-candidates")
        self.assertEqual(downloads[0]["with"]["path"], ".build/tonal-native")

    def test_gate_depends_on_every_job_and_runs_after_failures(self):
        gate = self.jobs["gate"]
        self.assertEqual(set(self.jobs), REQUIRED | {"gate"})
        self.assertEqual(set(gate["needs"]), REQUIRED)
        self.assertEqual(gate["if"], "always()")
        self.assertEqual(gate["steps"][0]["env"]["RESULTS"], "${{ toJSON(needs) }}")
        self.assertFalse(gate.get("continue-on-error", False))
        self.assertFalse(gate["steps"][0].get("continue-on-error", False))
        self.assertNotIn("if", gate["steps"][0])

    def run_gate(self, results):
        return subprocess.run(
            ["bash", "-euo", "pipefail", "-c", self.jobs["gate"]["steps"][0]["run"]],
            env={**os.environ, "RESULTS": json.dumps(results)},
            text=True, capture_output=True).returncode

    def test_real_gate_accepts_only_complete_success(self):
        success = {name: {"result": "success"} for name in REQUIRED}
        self.assertEqual(self.run_gate(success), 0)
        for name in REQUIRED:
            for result in ["failure", "cancelled", "skipped", "timed_out", "", None]:
                with self.subTest(job=name, result=result):
                    self.assertNotEqual(self.run_gate({**success, name: {"result": result}}), 0)
            missing = {key: value for key, value in success.items() if key != name}
            with self.subTest(missing=name):
                self.assertNotEqual(self.run_gate(missing), 0)
                self.assertNotEqual(self.run_gate({**missing, "unexpected": {"result": "success"}}), 0)
        self.assertNotEqual(self.run_gate({**success, "unexpected": {"result": "success"}}), 0)
        self.assertNotEqual(self.run_gate({}), 0)


if __name__ == "__main__":
    unittest.main()
