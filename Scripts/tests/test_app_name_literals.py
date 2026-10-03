"""앱 이름 리터럴 검사.

앱 이름은 바뀔 수 있다. 화면 문구, User-Agent, 배포 자산 이름에 "ClaudeUsage" 문자열을 새로 쓰지 않고
AppDistribution(표시 이름)과 AppIdentifiers(고정 식별자)를 거치게 한다.
"""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
ALLOWED = {
    ROOT / "ClaudeUsage" / "App" / "AppDistribution.swift",
    ROOT / "ClaudeUsage" / "App" / "AppIdentifiers.swift",
}
LITERAL = re.compile(r'"[^"\n]*ClaudeUsage[^"\n]*"')


def offending_lines():
    found = []
    for path in sorted((ROOT / "ClaudeUsage").rglob("*.swift")):
        if path in ALLOWED:
            continue
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            if line.lstrip().startswith("//"):
                continue
            if LITERAL.search(line):
                found.append(f"{path.relative_to(ROOT)}:{number}: {line.strip()}")
    return found


class AppNameLiteralTests(unittest.TestCase):
    def test_app_name_literals_stay_in_identity_files(self):
        self.assertEqual(offending_lines(), [], "AppDistribution 또는 AppIdentifiers를 쓰세요")


if __name__ == "__main__":
    unittest.main()


class AppIdentityConsistencyTests(unittest.TestCase):
    def test_shell_and_python_identity_files_agree(self):
        shell = (ROOT / "Scripts" / "lib" / "app-identity.sh").read_text(encoding="utf-8")
        values = dict(re.findall(r'^([A-Z_]+)="([^"$]*)"$', shell, re.MULTILINE))
        python = {}
        exec((ROOT / "Scripts" / "lib" / "app_identity.py").read_text(encoding="utf-8"), python)
        self.assertEqual(values["APP_PRODUCT_NAME"], python["APP_PRODUCT_NAME"])
        self.assertEqual(values["APP_PROD_BUNDLE_IDENTIFIER"], python["APP_PROD_BUNDLE_IDENTIFIER"])

    def test_swift_identifiers_match_release_scripts(self):
        swift = (ROOT / "ClaudeUsage" / "App" / "AppIdentifiers.swift").read_text(encoding="utf-8")
        shell = (ROOT / "Scripts" / "lib" / "app-identity.sh").read_text(encoding="utf-8")
        for name in ("productionBundleIdentifier", "stagingBundleIdentifier"):
            value = re.search(rf'{name} = "([^"]+)"', swift).group(1)
            self.assertIn(f'"{value}"', shell, name)
        zip_name = re.search(r'releaseAssetZipName = "([^"]+)"', swift).group(1)
        product = re.search(r'^APP_PRODUCT_NAME="([^"]+)"$', shell, re.MULTILINE).group(1)
        self.assertEqual(zip_name, f"{product}.zip")
