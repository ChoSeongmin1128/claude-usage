import base64
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).parents[2]
PUBLIC_KEY = "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="


class ReleaseSignatureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        cls.root = Path(cls.directory.name)
        cls.verifier = cls.root / "verify"
        cls.signer = cls.root / "sign"
        for source, executable in [(ROOT / "Scripts/verify-sparkle-signature.swift", cls.verifier),
                                   (ROOT / "Scripts/tests/sign-release-fixture.swift", cls.signer)]:
            subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(cls.root / "modules"),
                            str(source), "-o", str(executable)], check=True, capture_output=True)

    def setUp(self):
        self.feed = self.root / "appcast.xml"
        self.feed.write_bytes(b'<?xml version="1.0"?><rss><channel><item>'
                              b'<description>approved</description></item></channel></rss>\n')
        subprocess.run([self.signer, self.feed], check=True, capture_output=True)

    def verify(self, key=PUBLIC_KEY):
        return subprocess.run([self.verifier, self.feed, key], capture_output=True).returncode

    def test_valid_feed_signature(self):
        self.assertEqual(self.verify(), 0)

    def test_embedded_notes_tampering_is_rejected(self):
        self.feed.write_bytes(self.feed.read_bytes().replace(b"approved", b"tampered"))
        self.assertNotEqual(self.verify(), 0)

    def test_wrong_key_is_rejected(self):
        wrong_key = base64.b64encode(bytes(range(32))).decode()
        self.assertNotEqual(self.verify(wrong_key), 0)

    def test_unsigned_and_truncated_feeds_are_rejected(self):
        signed = self.feed.read_bytes()
        for data in [signed.split(b"<!-- sparkle-signatures:")[0], signed[:-3], signed + b"<extra/>"]:
            with self.subTest(data_length=len(data)):
                self.feed.write_bytes(data)
                self.assertNotEqual(self.verify(), 0)

    def test_reserialized_xml_invalidates_signature(self):
        self.feed.write_bytes(self.feed.read_bytes().replace(b"<item>", b"<item >"))
        self.assertNotEqual(self.verify(), 0)


if __name__ == "__main__":
    unittest.main()
