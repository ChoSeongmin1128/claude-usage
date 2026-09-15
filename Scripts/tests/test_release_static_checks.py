import importlib.util
import contextlib
import io
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("checks", Path(__file__).parents[1] / "check-changes.py")
checks = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checks)


class ChangedCodeChecksTests(unittest.TestCase):
    def test_ranges_include_insertions_and_skip_deletion_only_hunks(self):
        diff = "@@ -1 +1,3 @@\n@@ -40,2 +42,0 @@\n@@ -50 +50 @@\n"
        self.assertEqual(checks.changed_ranges(diff), [(1, 3), (50, 50)])

    def test_formatting_only_changes_the_edited_range_and_detects_it_read_only(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True)
            git("init")
            (root / ".swift-format").write_text('{"indentation":{"spaces":4}}')
            source = root / "fixture.swift"
            original = "let   untouched=1\n\nlet changed = 2\n"
            source.write_text(original)
            git("add", ".")
            git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit", "-m", "fixture")
            source.write_text(original.replace("let changed = 2", "let changed=3"))
            with patch.object(checks, "ROOT", root), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(checks.check("HEAD"), 1)
                self.assertIn("let changed=3", source.read_text())
                self.assertEqual(checks.check("HEAD", fix=True), 0)
                self.assertEqual(source.read_text(), "let   untouched=1\n\nlet changed = 3\n")
                self.assertEqual(checks.check("HEAD"), 0)


if __name__ == "__main__":
    unittest.main()
