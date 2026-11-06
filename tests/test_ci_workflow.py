# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Keep parallel CI complete and execute its real fail-closed merge gate."""
from collections import Counter
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
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

    def test_every_test_job_runs_once_without_skips_or_allow_failure(self):
        expected = {
            "build": ["scripts/build test"],
            "native": ["scripts/test-planner", "scripts/test-planner release",
                       "scripts/test-dsp", "scripts/test-audio release"],
            "audio_debug": ['scripts/test-audio debug "${{ matrix.partition }}"'],
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

    def test_debug_matrix_requires_every_named_partition_without_changing_other_jobs(self):
        job = self.jobs["audio_debug"]
        self.assertEqual(job["name"], "Debug Audio Tests (${{ matrix.partition }})")
        self.assertEqual(job["timeout-minutes"], 30)
        self.assertEqual(job["strategy"], {
            "fail-fast": False,
            "matrix": {"partition": ["core", "controls-transactions", "controls-workers"]},
        })
        for name in ["build", "native"]:
            self.assertNotIn("strategy", self.jobs[name])

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


class AudioPartitionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        temporary = tempfile.TemporaryDirectory(prefix="lowlight audio partitions ")
        cls.addClassCleanup(temporary.cleanup)
        cls.root = Path(temporary.name)
        (cls.root / "scripts").mkdir()
        (cls.root / "bin").mkdir()
        # Execute the real dispatcher, recording its Swift invocation without compiling
        # or replacing the audio suite. Toolchain validation has its own repository gate.
        shutil.copy2(ROOT / "scripts/test-audio", cls.root / "scripts/test-audio")
        toolchain = cls.root / "scripts/toolchain"
        toolchain.write_text("#!/bin/bash\nexit 0\n")
        toolchain.chmod(0o755)
        recorder = cls.root / "bin/xcrun"
        recorder.write_text(
            "#!/usr/bin/env python3\nimport json, sys\nprint(json.dumps(sys.argv[1:]))\n")
        recorder.chmod(0o755)
        cls.env = {**os.environ, "PATH": str(cls.root / "bin") + os.pathsep + os.environ["PATH"]}

    def invoke(self, *arguments):
        return subprocess.run(
            [str(self.root / "scripts/test-audio"), *arguments], env=self.env,
            text=True, capture_output=True)

    def command(self, *arguments):
        result = self.invoke(*arguments)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_default_and_release_still_run_the_entire_suite(self):
        for arguments in [(), ("debug",), ("debug", "all"), ("release",), ("release", "all")]:
            with self.subTest(arguments=arguments):
                self.assertEqual(self.command(*arguments), [
                    "swift", "test", "--configuration", arguments[0] if arguments else "debug",
                    "--package-path", "Packages/LowlightAudio", "--scratch-path", ".build/AudioTests",
                ])

    def test_unknown_extra_and_release_partition_arguments_fail_closed(self):
        for arguments in [
            ("unknown",), ("",), ("debug", ""), ("debug", "unknown"),
            ("debug", "all", "extra"),
            ("release", "core"), ("release", "controls-transactions"),
            ("release", "controls-workers"),
        ]:
            with self.subTest(arguments=arguments):
                result = self.invoke(*arguments)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, "", "Invalid scopes must not invoke Swift")
                self.assertIn("Usage:", result.stderr)

    def test_debug_filters_partition_every_suite_exactly_once(self):
        partitions = ["core", "controls-transactions", "controls-workers"]
        commands = {partition: self.command("debug", partition) for partition in partitions}
        for partition, command in commands.items():
            self.assertEqual(command[:-2], self.command("debug"))
            self.assertEqual(command[-2], "--skip" if partition == "core" else "--filter")
        # Include all current suites and future/core lookalikes so an unanchored or
        # broadened filter cannot silently exclude unrelated tests or run one twice.
        discovered = {
            match.group(1)
            for path in (ROOT / "Packages/LowlightAudio/Tests/LowlightAudioTests").glob("*.swift")
            for match in re.finditer(r"\b(?:struct|class)\s+(\w+Tests)\b", path.read_text())
        }
        expected = {
            "SessionControlsTransactionTests": "controls-transactions",
            "SessionControlsWorkerTests": "controls-workers",
            "SessionControlsCapacityFailureTests": "controls-workers",
        }
        self.assertTrue(set(expected) <= discovered,
                        "A renamed or removed partition suite must update the routing")
        suites = discovered | {
            "FutureTests", "OtherSessionControlsWorkerTests", "SessionControlsWorkerTestsExtra",
        }
        for suite in suites:
            identifier = f"LowlightAudioTests.{suite}/testExample()"
            selected = []
            for partition, command in commands.items():
                matches = re.search(command[-1], identifier) is not None
                if matches == (command[-2] == "--filter"):
                    selected.append(partition)
            with self.subTest(suite=suite):
                self.assertEqual(selected, [expected.get(suite, "core")])


if __name__ == "__main__":
    unittest.main()
