"""요금제 목록 커버리지 검사.

Fixtures/Plans/plan-values.json의 요금제 값마다 그 값을 다루는 fixture가 하나 이상 있어야 한다.
`python3 Scripts/tests/test_plan_coverage.py --refresh`는 설치된 Codex와 Claude Code 실행 파일에서
요금제처럼 보이는 새 문자열을 찾아 목록에 없는 값을 알려준다(배포 게이트에서는 실행하지 않음).
"""

import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import unittest

PLANS = Path(__file__).resolve().parents[2] / "ClaudeUsageTests" / "Fixtures" / "Plans"


def load_plan_values():
    return json.loads((PLANS / "plan-values.json").read_text(encoding="utf-8"))


def covered_plans(provider):
    covered = {}
    for path in sorted((PLANS / provider).glob("*.json")):
        meta = json.loads(path.read_text(encoding="utf-8")).get("meta", {})
        for plan in meta.get("plans", []):
            covered.setdefault(plan, []).append(path.name)
    return covered


class PlanCoverageTests(unittest.TestCase):
    def test_every_known_plan_value_has_a_fixture(self):
        values = load_plan_values()
        for provider in ("claude", "codex"):
            covered = covered_plans(provider)
            missing = [value for value in values[provider]["values"] if value not in covered]
            self.assertEqual(missing, [], f"{provider} 요금제 값에 fixture가 없음")

    def test_fixtures_only_name_known_plan_values(self):
        values = load_plan_values()
        for provider in ("claude", "codex"):
            unknown = sorted(set(covered_plans(provider)) - set(values[provider]["values"]))
            self.assertEqual(unknown, [], f"{provider} fixture가 목록에 없는 요금제 값을 씀")

    def test_every_fixture_states_its_source(self):
        for provider in ("claude", "codex"):
            for path in sorted((PLANS / provider).glob("*.json")):
                fixture = json.loads(path.read_text(encoding="utf-8"))
                self.assertIn(fixture["meta"].get("source"), {"measured", "docs", "assumed"}, path.name)
                self.assertIn("expected", fixture, path.name)
                self.assertTrue(path.name.startswith(f"{provider}-"), path.name)


def refresh():
    values = load_plan_values()
    patterns = {
        "codex": re.compile(
            r"^(?:[a-z0-9]+_)*(?:free|go|plus|pro|prolite|promax|team|business|enterprise|edu|education|k12|quorum|ent\d+)"
            r"(?:_[a-z0-9]+)*$"
        ),
        "claude": re.compile(r"^claude_(?:free|pro|max|team|enterprise)[a-z0-9_]*$"),
    }
    binaries = {"codex": shutil.which("codex"), "claude": shutil.which("claude")}
    for provider, binary in binaries.items():
        if not binary:
            print(f"{provider}: 실행 파일 없음")
            continue
        strings = subprocess.run(["strings", "-a", binary], capture_output=True, text=True).stdout.splitlines()
        known = set(values[provider]["values"])
        if provider == "claude":
            known |= {f"claude_{value}" for value in known}
        candidates = sorted({s for s in strings if len(s) <= 40 and patterns[provider].match(s)} - known)
        print(f"{provider} ({binary}): 목록에 없는 후보 {len(candidates)}개")
        for candidate in candidates:
            print(f"  {candidate}")


if __name__ == "__main__":
    if "--refresh" in sys.argv:
        refresh()
    else:
        unittest.main()
