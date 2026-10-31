# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
import copy
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
VERIFY = runpy.run_path(str(ROOT / "scripts/verify-codeql-coverage.py"))["verify"]
APP = ROOT / "Lowlight/LowlightApp.swift"


class CoverageTests(unittest.TestCase):
    def setUp(self):
        self.files = sorted((ROOT / "Lowlight").rglob("*.swift")) + sorted(
            (ROOT / "Packages").glob("*/Package.swift")) + sorted(
            (ROOT / "Packages").glob("*/Sources/**/*.swift"))
        self.payload = {"#select": {
            "columns": [{"kind": "Entity"}, {"kind": "String"}],
            "tuples": [[{"label": str(path)}, "File successfully extracted."] for path in self.files],
        }}

    def test_complete_inventory_allows_generated_files(self):
        self.payload["#select"]["tuples"].append([{"label": str(ROOT / ".build/Generated.swift")}, "generated"])
        self.assertEqual(VERIFY(self.payload, ROOT), len(self.files))

    def test_missing_current_app_or_package_file_fails(self):
        for missing in self.files:
            with self.subTest(missing=missing):
                payload = copy.deepcopy(self.payload)
                payload["#select"]["tuples"] = [r for r in payload["#select"]["tuples"] if r[0]["label"] != str(missing)]
                with self.assertRaisesRegex(ValueError, missing.name):
                    VERIFY(payload, ROOT)

    def test_outside_same_basename_does_not_supply_coverage(self):
        row = next(row for row in self.payload["#select"]["tuples"] if row[0]["label"] == str(APP))
        row[0]["label"] = str(ROOT.parent / APP.name)
        with self.assertRaisesRegex(ValueError, APP.name):
            VERIFY(self.payload, ROOT)

    def test_absolute_file_urls_are_normalized(self):
        for row in self.payload["#select"]["tuples"]:
            row[0]["label"] = Path(row[0]["label"]).as_uri()
        self.assertEqual(VERIFY(self.payload, ROOT), len(self.files))

    def test_empty_tracked_inventory_fails(self):
        with tempfile.TemporaryDirectory(prefix="lowlight-coverage-") as directory:
            subprocess.run(["git", "init", "-q", directory], check=True)
            with self.assertRaisesRegex(ValueError, "nonempty app and package"):
                VERIFY(self.payload, directory)

    def test_invalid_extra_url_is_rejected(self):
        self.payload["#select"]["tuples"].append([{"label": "file:///tmp/invalid%00.swift"}, "extra"])
        with self.assertRaisesRegex(ValueError, "Invalid extracted file URL"):
            VERIFY(self.payload, ROOT)

    def test_malformed_or_partial_results_fail(self):
        for payload in [None, {}, {"#select": []}, {"#select": {"columns": [], "tuples": []}}]:
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                VERIFY(payload, ROOT)
        for key, value in [("tuples", []), ("tuples", [[{}]]), ("next", 2), ("columns", [{"kind": "String"}])]:
            payload = copy.deepcopy(self.payload)
            payload["#select"][key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                VERIFY(payload, ROOT)
        for label in [None, "Lowlight/LowlightApp.swift", "file://other-host/Lowlight.swift", "https://example.com/a.swift"]:
            payload = copy.deepcopy(self.payload)
            payload["#select"]["tuples"][0][0]["label"] = label
            with self.subTest(label=label), self.assertRaises(ValueError):
                VERIFY(payload, ROOT)


if __name__ == "__main__":
    unittest.main()
