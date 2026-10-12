import base64
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class SparkleKeySetupTests(unittest.TestCase):
    def run_setup(self, mode, tracked_key=None, allow_new_key=False, adopt_key=""):
        source = (Path(__file__).parents[1] / 'setup-sparkle-keys.sh').read_text()
        block = source.split('# 2) 키 생성 또는 기존 공개키 추출', 1)[1].split('# 3) 로컬 xcconfig 작성/병합', 1)[0]
        key = base64.b64encode(bytes(range(32))).decode()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / 'generate_keys'
            calls = root / 'calls'
            executable.write_text('''#!/bin/bash
set -eu
printf '%s\\n' "${1:-generate}" >> "$FIXTURE_CALLS"
if [[ "${1:-}" == "-p" ]]; then
    case "$FIXTURE_MODE" in
        absent) echo 'ERROR: No existing signing key found!'; exit 1 ;;
        existing) echo "$FIXTURE_KEY" ;;
        denied) echo 'ERROR: Access denied.'; exit 1 ;;
        malformed) echo 'Unexpected success response' ;;
    esac
else
    printf 'A key has been generated.\\n    <key>SUPublicEDKey</key>\\n    <string>%s</string>\\n' "$FIXTURE_KEY"
fi
''')
            executable.chmod(0o700)
            tracked = root / 'Release.xcconfig'
            tracked.touch()
            if tracked_key:
                tracked.write_text('SUPublicEDKey = ' + tracked_key + '\n')
            environment = dict(os.environ, GEN_KEYS=str(executable), OVERWRITE_CONFIG='0',
                               FIXTURE_KEY=key, FIXTURE_MODE=mode, FIXTURE_CALLS=str(calls),
                               TRACKED_XCCONFIG=str(tracked), ALLOW_NEW_KEY='1' if allow_new_key else '0',
                               ADOPT_PUBLIC_KEY=adopt_key)
            result = subprocess.run(['/bin/bash', '-c', 'set -euo pipefail\n' + block],
                                    env=environment, capture_output=True, text=True, timeout=5)
            return result, calls.read_text().splitlines(), key

    def test_missing_key_creates_and_reads_public_key_from_official_xml_output(self):
        result, calls, key = self.run_setup('absent')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ['-p', 'generate'])
        self.assertIn(key, result.stdout)

    def test_missing_key_does_not_replace_a_committed_trust_root(self):
        committed = base64.b64encode(bytes(range(32, 64))).decode()
        result, calls, _ = self.run_setup('absent', tracked_key=committed)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, ['-p'])
        self.assertIn('--new-key', result.stderr)

    def test_explicit_new_key_replaces_a_committed_trust_root(self):
        committed = base64.b64encode(bytes(range(32, 64))).decode()
        result, calls, key = self.run_setup('absent', tracked_key=committed, allow_new_key=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ['-p', 'generate'])
        self.assertIn(key, result.stdout)

    def test_existing_key_is_reused_without_generation(self):
        result, calls, key = self.run_setup('existing')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ['-p'])
        self.assertIn(key, result.stdout)

    def test_keychain_failure_does_not_generate_or_replace_any_key(self):
        result, calls, _ = self.run_setup('denied')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, ['-p'])
        self.assertIn('Access denied', result.stderr)

    def test_unrecognized_success_cannot_be_treated_as_no_existing_key(self):
        result, calls, _ = self.run_setup('malformed')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, ['-p'])

    def test_existing_different_key_requires_explicit_adoption(self):
        committed = base64.b64encode(bytes(range(32, 64))).decode()
        result, calls, _ = self.run_setup('existing', tracked_key=committed)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, ['-p'])
        self.assertIn('--adopt-public-key', result.stderr)

    def test_adoption_requires_current_key(self):
        committed = base64.b64encode(bytes(range(32, 64))).decode()
        current = base64.b64encode(bytes(range(32))).decode()
        result, calls, _ = self.run_setup('existing', tracked_key=committed, adopt_key=current)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ['-p'])
        result, calls, _ = self.run_setup('existing', tracked_key=committed, adopt_key=committed)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, ['-p'])

    def test_full_script_key_mismatch_preserves_both_config_files(self):
        source = (Path(__file__).parents[1] / 'setup-sparkle-keys.sh').read_text()
        start = source.index('find_sparkle_binary() {')
        end = source.index('\nGEN_KEYS=', start)
        source = source[:start] + 'find_sparkle_binary() { printf "%s\\n" "$FIXTURE_TOOL"; }\n' + source[end:]
        current = base64.b64encode(bytes(range(32))).decode()
        committed = base64.b64encode(bytes(range(32, 64))).decode()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Scripts').mkdir()
            (root / 'Config').mkdir()
            script = root / 'Scripts/setup-sparkle-keys.sh'
            script.write_text(source)
            tool = root / 'generate_keys'
            tool.write_text('#!/bin/sh\nprintf "%s\\n" "$FIXTURE_KEY"\n')
            tool.chmod(0o700)
            tracked = root / 'Config/Release.xcconfig'
            local = root / 'Config/Sparkle.release.local.xcconfig'
            tracked.write_text('SUPublicEDKey = ' + committed + '\n')
            local.write_text('SUPublicEDKey = ' + committed + '\nNOTARY_PROFILE = Fixture\n')
            original = (tracked.read_bytes(), local.read_bytes())
            environment = dict(os.environ, FIXTURE_TOOL=str(tool), FIXTURE_KEY=current)
            for flags in [[], ['--force'], ['--new-key'], ['--adopt-public-key', committed],
                          ['--new-key', '--adopt-public-key', current]]:
                result = subprocess.run(['/bin/bash', str(script), '--feed-url', 'https://example.invalid/appcast.xml', *flags],
                                        env=environment, capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0, flags)
                self.assertEqual((tracked.read_bytes(), local.read_bytes()), original, flags)
            result = subprocess.run(
                ['/bin/bash', str(script), '--feed-url', 'https://example.invalid/appcast.xml',
                 '--adopt-public-key', current], env=environment, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('SUPublicEDKey = ' + current, tracked.read_text())
            self.assertIn('SUPublicEDKey = ' + current, local.read_text())
            self.assertIn('NOTARY_PROFILE = Fixture', local.read_text())


if __name__ == '__main__':
    unittest.main()
