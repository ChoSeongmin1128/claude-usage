import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "homebrew_cask", Path(__file__).parents[1] / "lib" / "homebrew_cask.py"
)
homebrew = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(homebrew)


class HomebrewCaskTests(unittest.TestCase):
    def setUp(self):
        self.manifest = homebrew.build_manifest(
            "ChoSeongmin1128/claude-usage",
            "v2.5.3",
            "2.5.3",
            20506,
            "https://github.com/ChoSeongmin1128/claude-usage/releases/download/v2.5.3/ClaudeUsage.dmg",
            6157946,
            "5" * 64,
            "com.seongmin.ClaudeUsage",
            "https://choseongmin1128.github.io/claude-usage/appcast.xml",
            "ABC123DEF4",
            "14.0",
        )

    def test_manifest_roundtrip_is_canonical_and_strict(self):
        encoded = homebrew.canonical_json(self.manifest)
        self.assertEqual(json.loads(encoded), self.manifest)
        changed = json.loads(encoded)
        changed["unexpected"] = True
        with self.assertRaises(ValueError):
            homebrew.validate_manifest(changed)

    def test_manifest_rejects_non_production_identity(self):
        cases = [
            ("repository", "someone/fork"),
            ("tag", "v2.5.3-stg.4"),
            ("channel", "staging"),
        ]
        for key, value in cases:
            with self.subTest(key=key):
                changed = json.loads(homebrew.canonical_json(self.manifest))
                changed[key] = value
                with self.assertRaises(ValueError):
                    homebrew.validate_manifest(changed)

    def test_manifest_rejects_changed_asset_or_app_contract(self):
        changes = [
            ("asset", "url", "https://example.com/ClaudeUsage.dmg"),
            ("asset", "sha256", "A" * 64),
            ("app", "bundleIdentifier", "com.example.Other"),
            ("app", "feedURL", "https://example.com/appcast.xml"),
            ("app", "minimumSystemVersion", "15.0"),
        ]
        for section, key, value in changes:
            with self.subTest(section=section, key=key):
                changed = json.loads(homebrew.canonical_json(self.manifest))
                changed[section][key] = value
                with self.assertRaises(ValueError):
                    homebrew.validate_manifest(changed)

    def test_renderer_emits_versioned_self_updating_cask(self):
        rendered = homebrew.render_cask(self.manifest)
        self.assertIn('version "2.5.3"', rendered)
        self.assertIn('sha256 "' + "5" * 64 + '"', rendered)
        self.assertIn("strategy :sparkle, &:short_version", rendered)
        self.assertIn("auto_updates true\n  depends_on macos: :sonoma\n\n  app", rendered)
        self.assertNotIn("version :latest", rendered)

    def test_cask_state_classification_rejects_drift_and_digest_conflict(self):
        with tempfile.TemporaryDirectory() as directory:
            cask = Path(directory) / "claude-usage.rb"
            self.assertEqual(homebrew.classify_cask(cask, self.manifest), "absent")
            cask.write_text(homebrew.render_cask(self.manifest))
            self.assertEqual(homebrew.classify_cask(cask, self.manifest), "matching")
            cask.write_text(homebrew.render_cask_values("2.5.3", "6" * 64))
            self.assertEqual(homebrew.classify_cask(cask, self.manifest), "conflicting-sha")
            cask.write_text(homebrew.render_cask_values("2.5.2", "4" * 64))
            self.assertEqual(homebrew.classify_cask(cask, self.manifest), "outdated")
            cask.write_text(homebrew.render_cask_values("2.5.4", "7" * 64))
            self.assertEqual(homebrew.classify_cask(cask, self.manifest), "newer")
            cask.write_text(homebrew.render_cask(self.manifest) + "# local edit\n")
            self.assertEqual(homebrew.classify_cask(cask, self.manifest), "unexpected")

    def test_manifest_loader_rejects_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "manifest.json"
            target.write_text(homebrew.canonical_json(self.manifest))
            link = root / "link.json"
            link.symlink_to(target)
            with self.assertRaises(ValueError):
                homebrew.load_manifest(link)

    def test_manifest_loader_rejects_duplicate_json_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            path.write_text('{"schemaVersion":1,"schemaVersion":1}\n')
            with self.assertRaises(ValueError):
                homebrew.load_manifest(path)


if __name__ == "__main__":
    unittest.main()
