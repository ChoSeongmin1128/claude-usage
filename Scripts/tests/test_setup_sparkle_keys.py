import base64
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class SparkleKeySetupTests(unittest.TestCase):
    def run_setup(self, mode):
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
            environment = dict(os.environ, GEN_KEYS=str(executable), OVERWRITE_CONFIG='0',
                               FIXTURE_KEY=key, FIXTURE_MODE=mode, FIXTURE_CALLS=str(calls))
            result = subprocess.run(['/bin/bash', '-c', 'set -euo pipefail\n' + block],
                                    env=environment, capture_output=True, text=True, timeout=5)
            return result, calls.read_text().splitlines(), key

    def test_missing_key_creates_and_reads_public_key_from_official_xml_output(self):
        result, calls, key = self.run_setup('absent')
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


if __name__ == '__main__':
    unittest.main()
