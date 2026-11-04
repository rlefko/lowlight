# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Exercise the real pinned formatters and pre-commit hook in disposable repositories."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = "native code.cpp"
GOOD = "int value() {\n    return 1;\n}\n"
BAD = "int  value(){return 1;}\n"
EXCLUDED = (
    "Packages/LowlightAudio/Sources/CLowlightDSP/NumpyRandom.cpp",
    "Packages/LowlightAudio/Sources/CLowlightDSP/NumpyZiggurat.h",
)


class QualityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run([str(ROOT / "scripts/toolchain")], cwd=ROOT, check=True)

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="lowlight quality ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        for name in (
            "scripts/quality", "scripts/toolchain", "config/toolchain.env",
            ".githooks/pre-commit", ".clang-format", ".clang-format-ignore",
            ".swift-format", ".swiftlint.yml",
        ):
            destination = self.root / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, destination)
        (self.root / ".tools").symlink_to(ROOT / ".tools", target_is_directory=True)
        self.write(".gitignore", ".tools/\n")
        self.write(SOURCE, GOOD)
        self.write("removed.h", "int value();\n")
        self.git("init", "-q")
        self.git("config", "user.name", "Quality Test")
        self.git("config", "user.email", "quality@example.invalid")
        self.git("config", "core.hooksPath", ".githooks")
        self.git("add", ".")
        self.git("-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
                 "commit", "-qm", "Test baseline")

    def run_command(self, *args, success=True):
        result = subprocess.run(args, cwd=self.root, env=self.env, text=True, capture_output=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def git(self, *args):
        return self.run_command("git", *args).stdout

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def hook(self, success=True):
        tree = self.git("write-tree")
        self.run_command(str(self.root / ".githooks/pre-commit"), success=success)
        self.assertEqual(self.git("write-tree"), tree, "The hook must never stage or rewrite files")

    def test_bad_index_is_rejected_despite_formatted_working_copy(self):
        self.write(SOURCE, BAD)
        self.git("add", "--", SOURCE)
        self.write(SOURCE, GOOD)
        self.hook(success=False)
        self.assertEqual(self.git("show", ":" + SOURCE), BAD)
        self.assertEqual((self.root / SOURCE).read_text(), GOOD)

    def test_good_index_passes_despite_unformatted_unstaged_and_untracked_files(self):
        staged = GOOD.replace("1", "2")
        working = BAD.replace("1", "3")
        self.write(SOURCE, staged)
        self.git("add", "--", SOURCE)
        self.write(SOURCE, working)
        self.write("untracked.cpp", BAD)
        self.hook()
        self.assertEqual(self.git("show", ":" + SOURCE), staged)
        self.assertEqual((self.root / SOURCE).read_text(), working)
        self.assertEqual((self.root / "untracked.cpp").read_text(), BAD)

    def test_staged_style_and_ignore_file_control_the_snapshot(self):
        self.write(SOURCE, GOOD.replace("1", "2"))
        for name in EXCLUDED:
            self.write(name, BAD)
        self.git("add", ".")
        style = (self.root / ".clang-format").read_text()
        self.write(".clang-format", style.replace("IndentWidth: 4", "IndentWidth: 2"))
        self.write(".clang-format-ignore", "")
        self.hook()
        self.assertEqual((self.root / ".clang-format-ignore").read_text(), "")
        # Stage that narrower indentation rule: the same staged code must now fail.
        self.git("add", ".clang-format")
        self.hook(success=False)

    def test_renames_deletions_and_spaces_are_checked_without_staging_working_edits(self):
        renamed = "directory with spaces/renamed file.cpp"
        (self.root / "directory with spaces").mkdir()
        self.git("mv", "--", SOURCE, renamed)
        self.git("rm", "--", "removed.h")
        self.write(renamed, BAD)
        self.hook()
        self.assertEqual((self.root / renamed).read_text(), BAD)
        self.git("add", "--", renamed)
        self.hook(success=False)

    def test_style_only_changes_check_all_index_files_and_cannot_remove_the_config(self):
        style = (self.root / ".clang-format").read_text()
        self.write(".clang-format", style.replace("IndentWidth: 4", "IndentWidth: 2"))
        self.git("add", ".clang-format")
        self.hook(success=False)
        self.write(".clang-format", style)
        self.git("add", ".clang-format")
        self.git("rm", ".clang-format")
        self.hook(success=False)

    def test_nested_style_and_exclusion_only_changes_check_affected_index_files(self):
        self.write("nested/sample.cpp", GOOD)
        self.git("add", ".")
        self.git("-c", "core.hooksPath=/dev/null", "commit", "-qm", "Nested source")
        self.write("nested/.clang-format", "BasedOnStyle: InheritParentConfig\nIndentWidth: 2\n")
        self.git("add", "nested/.clang-format")
        self.hook(success=False)
        self.write("nested/.clang-format", "BasedOnStyle: InheritParentConfig\n")
        self.write("nested/.clang-format-ignore", "sample.cpp\n")
        self.write("nested/sample.cpp", BAD)
        self.git("add", "nested")
        self.git("-c", "core.hooksPath=/dev/null", "commit", "-qm", "Nested exclusion")
        self.write("nested/.clang-format-ignore", "")
        self.git("add", "nested/.clang-format-ignore")
        self.hook(success=False)

    def test_explicit_fix_only_changes_tracked_working_files_and_is_idempotent(self):
        self.write(SOURCE, BAD)
        self.write("nested/header.hpp", "inline int answer(){return 2;}\n")
        self.write("bridge.c", "int bridge(void){return 3;}\n")
        for name in EXCLUDED:
            self.write(name, BAD)
        self.git("add", ".")
        self.write("untracked.cpp", BAD)
        tree = self.git("write-tree")
        self.run_command("scripts/quality", success=False)
        self.run_command("scripts/quality", "fix")
        self.assertEqual(self.git("write-tree"), tree)
        self.assertEqual((self.root / SOURCE).read_text(), GOOD)
        self.assertEqual((self.root / "untracked.cpp").read_text(), BAD)
        for name in EXCLUDED:
            self.assertEqual((self.root / name).read_text(), BAD)
        paths = [SOURCE, "nested/header.hpp", "bridge.c"]
        before = [(self.root / name).read_bytes() for name in paths]
        self.run_command("scripts/quality")
        self.run_command("scripts/quality", "fix")
        self.assertEqual([(self.root / name).read_bytes() for name in paths], before)
        self.assertEqual(self.git("write-tree"), tree)

    def test_swift_and_native_both_participate_in_the_hook(self):
        self.write("Example.swift", "let value = 1\n")
        self.git("add", "Example.swift")
        self.hook()
        self.write("Example.swift", "let value=1\n")
        self.git("add", "Example.swift")
        self.hook(success=False)

    def test_style_preserves_include_using_order_and_comments(self):
        text = ('#include "z.h"\n#include "a.h"\nusing z::Last;\nusing a::First;\n'
                '// ' + ('License text remains exactly as supplied. ' * 4).rstrip() + '\n' + GOOD)
        self.write(SOURCE, text)
        self.run_command("scripts/quality", "fix")
        self.assertEqual((self.root / SOURCE).read_text(), text)

    def test_wrong_formatter_pin_fails_before_any_rewrite(self):
        path = self.root / "config/toolchain.env"
        path.write_text(path.read_text() + "\nCLANG_FORMAT_VERSION='wrong version'\n")
        self.write(SOURCE, BAD)
        result = self.run_command("scripts/quality", "fix", success=False)
        self.assertIn("Use the clang-format bundled with Xcode", result.stderr)
        self.assertEqual((self.root / SOURCE).read_text(), BAD)


if __name__ == "__main__":
    unittest.main()
