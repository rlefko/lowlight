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


class CppCoverageTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="lowlight-cpp-coverage-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        self.source = self.root / "Packages/LowlightAudio/Sources/CLowlightDSP/VoiceMixer.cpp"
        self.header = self.source.parent / "include/LowlightDSP.h"
        self.header.parent.mkdir(parents=True)
        self.source.write_text('#include "LowlightDSP.h"\n')
        self.header.write_text("void render(void);\n")
        subprocess.run(["git", "-C", str(self.root), "add", "Packages"], check=True)
        self.payload = {"#select": {
            "columns": [{"kind": "Entity"}, {"kind": "String"}],
            "tuples": [[{"label": str(path)}, "File successfully extracted."] for path in (self.source, self.header)],
        }}

    def test_complete_native_inventory_includes_public_header(self):
        self.assertEqual(VERIFY(self.payload, self.root, "cpp"), 2)

    def test_missing_implementation_or_public_header_fails(self):
        for missing in (self.source, self.header):
            payload = copy.deepcopy(self.payload)
            payload["#select"]["tuples"] = [r for r in payload["#select"]["tuples"] if r[0]["label"] != str(missing)]
            with self.subTest(missing=missing), self.assertRaisesRegex(ValueError, missing.name):
                VERIFY(payload, self.root, "cpp")

    def test_other_checkout_cannot_supply_kernel_coverage(self):
        self.payload["#select"]["tuples"][0][0]["label"] = str(self.root.parent / self.source.name)
        with self.assertRaisesRegex(ValueError, "VoiceMixer.cpp"):
            VERIFY(self.payload, self.root, "cpp")

    def test_requires_both_tracked_implementation_and_header(self):
        for path in (self.source, self.header):
            subprocess.run(["git", "-C", str(self.root), "rm", "--cached", "-q", str(path)], check=True)
            with self.subTest(path=path), self.assertRaisesRegex(ValueError, "nonempty C/C\\+\\+"):
                VERIFY(self.payload, self.root, "cpp")
            subprocess.run(["git", "-C", str(self.root), "add", str(path)], check=True)
        subprocess.run(["git", "-C", str(self.root), "rm", "--cached", "-q", str(self.source), str(self.header)], check=True)
        with self.assertRaisesRegex(ValueError, "nonempty C/C\\+\\+"):
            VERIFY(self.payload, self.root, "cpp")

    def test_deleted_tracked_source_fails_even_with_extraction_row(self):
        self.source.unlink()
        with self.assertRaisesRegex(ValueError, "Missing tracked source: .*VoiceMixer.cpp"):
            VERIFY(self.payload, self.root, "cpp")

    def test_unsupported_language_cannot_disable_inventory(self):
        with self.assertRaisesRegex(ValueError, "Unsupported CodeQL language"):
            VERIFY(self.payload, self.root, "rust")


if __name__ == "__main__":
    unittest.main()
