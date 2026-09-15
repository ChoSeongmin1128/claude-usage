import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "release_metadata", Path(__file__).parents[1] / "lib" / "release_metadata.py"
)
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)


class ReleaseMetadataTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.notes = self.root / "docs/release-notes/2.4.15.md"
        self.notes.parent.mkdir(parents=True)
        self.text = '# 2.4.15\n\n- 계정 조회를 개선했습니다.\n- <tag> & "quotes" / $() `code` ]]>\n'
        self.notes.write_text(self.text, encoding="utf-8")
        self.appcast = self.root / "appcast.xml"
        self.appcast.write_text(
            '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
            '<channel><item><sparkle:shortVersionString>2.4.15</sparkle:shortVersionString>'
            '<sparkle:version>20415</sparkle:version><enclosure url="https://test/ClaudeUsage.zip" '
            'sparkle:edSignature="fixture" length="12"/></item></channel></rss>'
        )

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args], stderr=subprocess.DEVNULL)

    def test_notes_must_match_version_and_contain_change(self):
        for text in ["", "# 2.4.15\n", "# 2.4.14\n- change\n", "# 2.4.15\r\n- change\r\n"]:
            with self.subTest(text=text):
                with self.notes.open("w", newline="", encoding="utf-8") as note:
                    note.write(text)
                with self.assertRaises(ValueError):
                    metadata.canonical_notes(self.root, "2.4.15")

    def test_uncommitted_or_changed_notes_cannot_be_published(self):
        self.git("init", "-q")
        with self.assertRaises(subprocess.CalledProcessError):
            metadata.canonical_notes(self.root, "2.4.15", commit="HEAD")
        self.git("add", ".")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit", "-qm", "fixture")
        self.assertEqual(metadata.canonical_notes(self.root, "2.4.15", commit="HEAD"), self.notes)
        self.notes.write_text(self.text + "- unreviewed\n")
        with self.assertRaises(ValueError):
            metadata.canonical_notes(self.root, "2.4.15", commit="HEAD")

    def test_notes_outside_canonical_path_and_symlinks_are_rejected(self):
        other = self.root / "other.md"
        other.write_text(self.text)
        with self.assertRaises(ValueError):
            metadata.canonical_notes(self.root, "2.4.15", other)
        self.notes.unlink()
        self.notes.symlink_to(other)
        with self.assertRaises(ValueError):
            metadata.canonical_notes(self.root, "2.4.15")

    def test_plain_text_roundtrip_preserves_markup_without_injecting_xml(self):
        metadata.embed_notes(self.appcast, self.notes, "2.4.15")
        metadata.verify_notes(self.appcast, self.notes, "2.4.15")
        _, item = metadata.appcast_item(self.appcast)
        self.assertIsNone(item.find("tag"))
        self.assertEqual(metadata.appcast_fields(self.appcast).split("\t"),
                         ["2.4.15", "20415", "https://test/ClaudeUsage.zip", "fixture", "12"])

    def test_missing_or_different_remote_notes_fail(self):
        with self.assertRaises(ValueError):
            metadata.verify_notes(self.appcast, self.notes, "2.4.15")
        metadata.embed_notes(self.appcast, self.notes, "2.4.15")
        release = self.root / "release.json"
        release.write_text(json.dumps({"body": self.text}))
        metadata.verify_notes(self.appcast, self.notes, "2.4.15", release)
        release.write_text(json.dumps({"body": "automatic notes"}))
        with self.assertRaises(ValueError):
            metadata.verify_notes(self.appcast, self.notes, "2.4.15", release)

    def test_secondary_zip_digest_is_bound_before_extraction(self):
        archive = self.root / "ClaudeUsage.zip"
        archive.write_bytes(b"reviewed archive")
        metadata.bind_zip(self.appcast, archive)
        metadata.verify_zip(self.appcast, archive)
        archive.write_bytes(b"modified archive")
        with self.assertRaises(ValueError):
            metadata.verify_zip(self.appcast, archive)

    def test_public_key_override_rejects_malformed_keys(self):
        script = Path(__file__).parents[1] / "lib/release_metadata.py"
        for key, success in [("11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=", True),
                             ("invalid", False), ("", False)]:
            result = subprocess.run([sys.executable, script, "validate-public-key", key], capture_output=True)
            self.assertEqual(result.returncode == 0, success)

    def test_duplicate_items_are_rejected(self):
        self.appcast.write_text("<rss><channel><item/><item/></channel></rss>")
        with self.assertRaises(ValueError):
            metadata.appcast_item(self.appcast)

    def test_public_feed_state_supports_legacy_zip_and_current_dmg(self):
        for version, build, archive, channel in [("2.3.3", "20330", "zip", "prod"),
                                                  ("2.4.14", "20414", "zip", "staging"),
                                                  ("2.4.15", "20415", "dmg", "staging")]:
            with self.subTest(version=version):
                tag = "v" + version + ("-staging" if channel == "staging" else "")
                xml = ('<rss xmlns:sparkle="' + metadata.SPARKLE + '"><channel><item>'
                       '<sparkle:shortVersionString>' + version + '</sparkle:shortVersionString>'
                       '<sparkle:version>' + build + '</sparkle:version>'
                       '<enclosure\n length="100" sparkle:edSignature="fixture"\n url="'
                       'https://github.com/ChoSeongmin1128/claude-usage/releases/download/' + tag
                       + '/ClaudeUsage.' + archive + '"/></item></channel></rss>')
                self.appcast.write_text(xml)
                self.assertEqual(metadata.channel_feed_state(self.appcast, channel),
                                 "\t".join([version, build, tag]))
                # Exercise the same stdin path as the integrated driver.
                result = subprocess.run([sys.executable, spec.origin,
                                         "channel-feed-state", "--appcast", "-", "--channel", channel],
                                        input=xml.encode(), capture_output=True, check=True)
                self.assertEqual(result.stdout.decode().strip(), "\t".join([version, build, tag]))
                with self.assertRaises(ValueError):
                    metadata.channel_feed_state(self.appcast, "prod" if channel == "staging" else "staging")
                self.appcast.write_text(xml.replace("ClaudeUsage." + archive, "ClaudeUsage.pkg"))
                with self.assertRaises(ValueError):
                    metadata.channel_feed_state(self.appcast, channel)


if __name__ == "__main__":
    unittest.main()
