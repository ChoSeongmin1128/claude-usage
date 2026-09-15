#!/usr/bin/env python3
"""Check changed Swift ranges with Xcode's formatter and changed shell files.

Usage: Scripts/check-changes.py --base main [--fix]
Release checks use HEAD^ because releases are published from one squash commit.
"""

import argparse
import difflib
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
SHELLCHECK_VERSION = "0.11.0"


def git(*arguments):
    return subprocess.check_output(["git", "-C", str(ROOT), *arguments])


def changed_ranges(diff):
    return [(int(start), int(start) + int(count or "1") - 1)
            for start, count in re.findall(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", diff, re.M)
            if int(count or "1") > 0]


def check(base, fix=False):
    commit = git("rev-parse", "--verify", "--end-of-options", base + "^{commit}").decode().strip()
    tracked = git("diff", "--name-only", "-z", "--diff-filter=ACMR", commit, "--")
    untracked = git("ls-files", "--others", "--exclude-standard", "-z")
    new_files = set(untracked.decode().split("\0"))
    paths = sorted(set((tracked + untracked).decode().split("\0")) - {""})
    swift_files = [path for path in paths if path.endswith(".swift")]
    shell_files = [path for path in paths if path.endswith(".sh")]
    for path in swift_files + shell_files:
        if (ROOT / path).is_symlink():
            raise ValueError("검사 대상에 심볼릭 링크가 있습니다: " + path)
    failures = 0
    if swift_files:
        formatter = subprocess.check_output(["xcrun", "--find", "swift-format"]).decode().strip()
        for path in swift_files:
            file = ROOT / path
            original = file.read_bytes()
            if path in new_files:
                ranges = [(1, max(1, len(original.splitlines())))]
            else:
                diff = git("diff", "--no-ext-diff", "--no-textconv", "--unified=0", commit, "--", path).decode()
                ranges = changed_ranges(diff)
            if not ranges:
                continue
            command = [formatter, "format", "--configuration", str(ROOT / ".swift-format")]
            for start, end in ranges:
                command += ["--lines", str(start) + ":" + str(end)]
            formatted = subprocess.check_output(command + [str(file)])
            if formatted == original:
                continue
            if fix:
                file.write_bytes(formatted)
                print("포맷 수정: " + path)
            else:
                failures += 1
                print("".join(difflib.unified_diff(original.decode().splitlines(True),
                                                 formatted.decode().splitlines(True),
                                                 fromfile=path, tofile=path + " (formatted)")))
    if shell_files:
        version = subprocess.check_output(["shellcheck", "--version"]).decode()
        if not re.search(r"^version: " + re.escape(SHELLCHECK_VERSION) + r"$", version, re.M):
            raise ValueError("ShellCheck " + SHELLCHECK_VERSION + "이 필요합니다")
        result = subprocess.run(["shellcheck", "--external-sources", *shell_files], cwd=ROOT)
        failures += result.returncode != 0
    print(f"변경 코드 검사: Swift {len(swift_files)}개, shell {len(shell_files)}개, 실패 {failures}개")
    return 1 if failures else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True)
    parser.add_argument("--fix", action="store_true", help="변경 Swift 범위만 포맷 수정")
    args = parser.parse_args()
    return check(args.base, args.fix)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit("변경 코드 검사 실패: " + str(error))
