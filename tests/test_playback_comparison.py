# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
import copy
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from uuid import UUID

TOOLS = Path(__file__).resolve().parents[1] / "tools/playback-comparison"
sys.path.insert(0, str(TOOLS))
import trial_records
import trials


class TrialReportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.path = self.root / "operator.json"
        self.data = trial_records.template("older")
        self.write("manifest.json", {"schema_version": 1, "codec": "aac", "sample_rate": 32000,
                   "channels": 2, "frames": 2400 * 32000, "duration_seconds": 2400, "seed": 91031,
                   "preset": "Focus", "aac_sha256": "c" * 64})
        for n, row in enumerate(self.data["trials"]):
            mode = row["mode"]
            warm = datetime(2026, 11, 1, tzinfo=timezone.utc) + timedelta(hours=n)
            start = warm + timedelta(minutes=5)
            end = start + timedelta(minutes=30)
            trace = f"synthetic test trace {n}".encode()
            (self.root / row["trace"]).write_bytes(trace)
            row.update(
                trial_id=str(UUID(int=n + 1)), device="test", model="iPhone test", os_build="test OS",
                build_commit="a" * 40, app_sha256="b" * 64, fixture_sha256="c" * 64,
                route="speaker", volume=0.5, low_power=False, screen="locked", charging="unplugged",
                thermal="nominal", capture="on_device_power_profiler",
                warmup_start=warm.isoformat(), measured_start=start.isoformat(), measured_end=end.isoformat(),
                metric="whole_system_battery_drain", unit="percentage_points_per_hour",
                rate={"generator": 3.1, "aac": 3, "idle": 1}[mode], uncertainty=0.015,
                uncertainty_source="synthetic bound", trace_sha256=hashlib.sha256(trace).hexdigest(),
            )
            sample = {"formatVersion": 1, "platform": "device", "appSHA256": "b" * 64, "bundleID": trial_records.BUNDLE, "trialID": row["trial_id"],
                      "mode": mode, "state": "running" if mode == "idle" else "playing", "seed": 91031,
                      "preset": "Focus", "generatedFrames": 0, "observedAt": warm.isoformat(),
                      "reason": "start", "startCount": 1}
            if mode == "aac":
                sample["aacSHA256"] = row["fixture_sha256"]
            self.write(row["start_snapshot"], sample)
            sample.update(reason="refresh", observedAt=end.isoformat(),
                          generatedFrames=0 if mode == "idle" else 2100 * 32000)
            self.write(row["end_snapshot"], sample)

    def write(self, name, data):
        (self.root / name).write_text(json.dumps(data))

    def analyze(self, data=None):
        self.write(self.path.name, self.data if data is None else data)
        return trial_records.report(self.path)

    def test_normalized_absolute_costs_paired_delta_and_uncertainty(self):
        row = self.data["trials"][0]
        row.update(unit="fraction_per_hour", rate=row["rate"] / 100, uncertainty=row["uncertainty"] / 100)
        report = self.analyze()
        self.assertEqual(report["status"], "comparable")
        self.assertEqual(report["absolute_by_block"][0], {"generator": 3.1, "aac": 3.0, "idle": 1.0})
        self.assertEqual(report["above_idle_by_block"][1]["aac"], 2)
        self.assertAlmostEqual(report["median_paired_difference_percent"], 5)
        self.assertEqual(len(report["windows"]), 9)
        self.assertEqual(report["windows"][0], {"block": 1, "mode": "generator",
                                               "offset_seconds": 300, "duration_seconds": 1800})
        lower, upper = report["paired_difference_envelope_percent"]
        self.assertLess(lower, 5)
        self.assertGreater(upper, 5)

    def test_missing_mismatched_duplicate_or_ineligible_conditions_have_no_comparison(self):
        for key, value in [
            ("mode", "idle"), ("block", 2), ("build_commit", "d" * 40), ("app_sha256", "e" * 64),
            ("fixture_sha256", "d" * 64), ("device", "other"), ("model", "other"),
            ("os_build", "other"), ("route", "Bluetooth"), ("volume", 0), ("low_power", True),
            ("screen", "on"), ("charging", "wired"), ("thermal", "serious"), ("capture", "simulator"),
            ("unit", "mW"), ("metric", "battery_percent_drop"), ("uncertainty_source", ""),
            ("uncertainty", 0), ("rate", float("nan")), ("trial_id", "wrong"), ("trace", "../missing"),
            ("trace_sha256", "d" * 64), ("warmup_start", "2026-11-01T00:01:00+00:00"),
            ("measured_end", "2026-11-01T00:34:59+00:00"), ("warmup_start", "2026-11-01T00:00:00"),
        ]:
            with self.subTest(key=key):
                data = copy.deepcopy(self.data)
                data["trials"][0][key] = value
                result = self.analyze(data)
                self.assertEqual(result["status"], "inconclusive")
                self.assertNotIn("absolute_by_block", result)
        self.assertEqual(self.analyze({**self.data, "trials": self.data["trials"][:-1]})["status"], "inconclusive")
        for key in ["trace", "trace_sha256"]:
            self.data["trials"][1][key] = self.data["trials"][0][key]
        self.assertIn("reused", self.analyze()["reason"])

    def test_late_start_wrong_mode_stale_snapshot_and_failed_progress(self):
        for role, key, value in [
            ("start", "observedAt", "2026-11-01T00:00:02+00:00"), ("start", "reason", "refresh"),
            ("end", "observedAt", "2026-11-01T00:34:58+00:00"), ("end", "trialID", str(UUID(int=42))),
            ("start", "appSHA256", "d" * 64), ("end", "appSHA256", "d" * 64),
            ("start", "platform", "simulator"), ("end", "platform", "simulator"), ("end", "state", "paused"), ("end", "reason", "pause"), ("end", "startCount", 2), ("start", "startCount", 0), ("end", "generatedFrames", 0), ("end", "mode", "aac"), ("end", "state", "failed"),
            ("end", "bundleID", "com.rlefko.lowlight"), ("end", "error", "unexpected interruption"),
        ]:
            with self.subTest(role=role, key=key):
                p = self.root / self.data["trials"][0][role + "_snapshot"]
                original = p.read_text()
                self.write(p.name, {**json.loads(original), key: value})
                self.assertIn("inconclusive", self.analyze()["status"])
                p.write_text(original)
        idle = self.root / self.data["trials"][2]["end_snapshot"]
        original = idle.read_text()
        self.write(idle.name, {**json.loads(original), "state": "paused", "reason": "pause"})
        self.assertEqual(self.analyze()["status"], "inconclusive")
        idle.write_text(original)
        sample = self.root / self.data["trials"][1]["end_snapshot"]
        self.write(sample.name, {**json.loads(sample.read_text()), "aacSHA256": "d" * 64})
        self.assertEqual(self.analyze()["status"], "inconclusive")

    def test_all_windows_match_both_duration_and_effective_start_within_five_seconds(self):
        row = self.data["trials"][0]
        first, last = self.root / row["start_snapshot"], self.root / row["end_snapshot"]
        start_image, end_image = json.loads(first.read_text()), json.loads(last.read_text())
        for shift, status in [(5, "comparable"), (6, "inconclusive")]:
            # Advance both endpoint counters: timing and progress are individually valid
            # but this row can otherwise measure a different passage than the other eight.
            self.write(first.name, {**start_image, "generatedFrames": shift * 32000})
            self.write(last.name, {**end_image, "generatedFrames": (2100 + shift) * 32000})
            self.assertEqual(self.analyze()["status"], status)
        self.write(first.name, start_image)
        for shift, status in [(5, "comparable"), (6, "inconclusive")]:
            finish = (datetime.fromisoformat(end_image["observedAt"]) + timedelta(seconds=shift)).isoformat()
            row["measured_end"] = finish
            self.write(last.name, {**end_image, "observedAt": finish, "generatedFrames": (2100 + shift) * 32000})
            self.assertEqual(self.analyze()["status"], status)

    def test_unstable_baseline_or_generator_bound_retains_absolutes_without_ratio(self):
        for mode, updates in [("aac", {"rate": 1.001}), ("aac", {"uncertainty": 0.5}),
                              ("generator", {"uncertainty": 2.0}), ("generator", {"rate": 3.9})]:
            with self.subTest(mode=mode, updates=updates):
                data = copy.deepcopy(self.data)
                next(row for row in data["trials"] if row["mode"] == mode).update(updates)
                result = self.analyze(data)
                self.assertEqual(result["status"], "inconclusive")
                self.assertIn("absolute_by_block", result)
                self.assertNotIn("median_paired_difference_percent", result)


class RehearsalTests(unittest.TestCase):
    def test_actual_installed_fixture_bytes_after_xctest(self):
        with tempfile.TemporaryDirectory() as tmp:
            support = Path(tmp)
            trials.check_installed_fixture(support, {})
            for name in trials.FIXTURE:
                (support / name).write_bytes(name.encode())
            expected = {name: trials.digest(support / name) for name in trials.FIXTURE}
            trials.check_installed_fixture(support, expected)
            for content in [b"changed", None]:
                sample = support / "reference.m4a"
                if content is None:
                    sample.unlink()
                else:
                    sample.write_bytes(content)
                with self.assertRaises(ValueError):
                    trials.check_installed_fixture(support, expected)

    def test_exact_results_reject_skip_substitution_and_duplicate(self):
        names = trials.GOOD
        nodes = [{"nodeType": "Test Case", "nodeIdentifier": "ComparisonTests/" + name + "()",
                  "result": "Passed"} for name in names]
        tree = {"testNodes": [{"nodeType": "Test Suite", "children": nodes}]}
        summary = {"result": "Passed", "passedTests": 4, "totalTestCount": 4, "skippedTests": 0,
                   "failedTests": 0, "expectedFailures": 0}
        trials.check_tests(tree, summary, names)
        for altered_tree, changed in [
            (tree, {"skippedTests": 1}), (tree, {"totalTestCount": 0}),
            ({"testNodes": nodes[:-1] + nodes[:1]}, {}),
            ({"testNodes": [{**nodes[0], "result": "Skipped"}] + nodes[1:]}, {}),
        ]:
            with self.assertRaises(ValueError):
                trials.check_tests(altered_tree, {**summary, **changed}, names)

    def test_simulator_stage_verifies_before_replacing_only_the_pair(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fixture, support = root / "source", root / "container"
            fixture.mkdir()
            support.mkdir()
            (support / "snapshot.json").write_text("retained")
            for name in trials.FIXTURE:
                (fixture / name).write_text(name)
            with patch.object(trials, "fixture_tool") as validate, patch.object(trials, "sim_support", return_value=support):
                validate.side_effect = ValueError("corrupt")
                with self.assertRaises(ValueError):
                    trials.stage(fixture, "unused", None)
                self.assertFalse((support / "reference.m4a").exists())
                validate.side_effect = None
                trials.stage(fixture, "unused", None)
                for name in trials.FIXTURE:
                    self.assertEqual((support / name).read_text(), name)
                self.assertEqual((support / "snapshot.json").read_text(), "retained")
