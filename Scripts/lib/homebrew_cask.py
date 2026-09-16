#!/usr/bin/env python3
"""Create and validate ClaudeUsage Homebrew Cask release metadata."""

import argparse
import json
from pathlib import Path
import re
import sys


SCHEMA_VERSION = 1
REPOSITORY = "ChoSeongmin1128/claude-usage"
CHANNEL = "prod"
ASSET_NAME = "ClaudeUsage.dmg"
APP_NAME = "ClaudeUsage.app"
BUNDLE_IDENTIFIER = "com.seongmin.ClaudeUsage"
FEED_URL = "https://choseongmin1128.github.io/claude-usage/appcast.xml"
MINIMUM_SYSTEM_VERSION = "14.0"
VERSION_PATTERN = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)")
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
TEAM_PATTERN = re.compile(r"[A-Z0-9]{10}")


def release_url(version):
    return f"https://github.com/{REPOSITORY}/releases/download/v{version}/{ASSET_NAME}"


def _exact_keys(value, expected, label):
    if not isinstance(value, dict) or set(value) != set(expected):
        raise ValueError(f"{label} 필드가 유효하지 않습니다")


def validate_manifest(value):
    _exact_keys(
        value,
        {
            "schemaVersion",
            "repository",
            "channel",
            "tag",
            "version",
            "build",
            "asset",
            "app",
        },
        "manifest",
    )
    if value["schemaVersion"] != SCHEMA_VERSION:
        raise ValueError("지원하지 않는 manifest schema입니다")
    if value["repository"] != REPOSITORY or value["channel"] != CHANNEL:
        raise ValueError("Homebrew 배포 대상이 운영 저장소가 아닙니다")

    version = value["version"]
    if not isinstance(version, str) or not VERSION_PATTERN.fullmatch(version):
        raise ValueError("유효한 운영 version이 필요합니다")
    if value["tag"] != f"v{version}":
        raise ValueError("운영 tag와 version이 일치하지 않습니다")
    build = value["build"]
    if isinstance(build, bool) or not isinstance(build, int) or not 0 < build <= 2147483647:
        raise ValueError("유효한 build가 필요합니다")

    asset = value["asset"]
    _exact_keys(asset, {"name", "url", "size", "sha256"}, "asset")
    if asset["name"] != ASSET_NAME or asset["url"] != release_url(version):
        raise ValueError("운영 DMG 경로가 tag와 일치하지 않습니다")
    if isinstance(asset["size"], bool) or not isinstance(asset["size"], int) or asset["size"] <= 0:
        raise ValueError("운영 DMG 크기가 유효하지 않습니다")
    if not isinstance(asset["sha256"], str) or not SHA256_PATTERN.fullmatch(asset["sha256"]):
        raise ValueError("운영 DMG SHA-256이 유효하지 않습니다")

    app = value["app"]
    _exact_keys(
        app,
        {
            "name",
            "bundleIdentifier",
            "feedURL",
            "teamIdentifier",
            "minimumSystemVersion",
        },
        "app",
    )
    if app["name"] != APP_NAME or app["bundleIdentifier"] != BUNDLE_IDENTIFIER:
        raise ValueError("운영 앱 identity가 유효하지 않습니다")
    if app["feedURL"] != FEED_URL:
        raise ValueError("운영 feed URL이 유효하지 않습니다")
    if not isinstance(app["teamIdentifier"], str) or not TEAM_PATTERN.fullmatch(app["teamIdentifier"]):
        raise ValueError("Developer ID team이 유효하지 않습니다")
    if app["minimumSystemVersion"] != MINIMUM_SYSTEM_VERSION:
        raise ValueError("Cask의 최소 macOS mapping을 갱신해야 합니다")
    return value


def build_manifest(repository, tag, version, build, asset_url, asset_size, asset_sha256,
                   bundle_identifier, feed_url, team_identifier, minimum_system_version):
    value = {
        "schemaVersion": SCHEMA_VERSION,
        "repository": repository,
        "channel": CHANNEL,
        "tag": tag,
        "version": version,
        "build": build,
        "asset": {
            "name": ASSET_NAME,
            "url": asset_url,
            "size": asset_size,
            "sha256": asset_sha256,
        },
        "app": {
            "name": APP_NAME,
            "bundleIdentifier": bundle_identifier,
            "feedURL": feed_url,
            "teamIdentifier": team_identifier,
            "minimumSystemVersion": minimum_system_version,
        },
    }
    return validate_manifest(value)


def load_manifest(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 65536:
        raise ValueError("manifest는 64KiB 이하의 일반 파일이어야 합니다")

    def reject_duplicates(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError("manifest에 중복 JSON key가 있습니다")
            value[key] = item
        return value

    return validate_manifest(
        json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=reject_duplicates)
    )


def canonical_json(value):
    validate_manifest(value)
    return json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def render_cask_values(version, sha256):
    if not VERSION_PATTERN.fullmatch(version) or not SHA256_PATTERN.fullmatch(sha256):
        raise ValueError("Cask version 또는 SHA-256이 유효하지 않습니다")
    return f'''cask "claude-usage" do
  version "{version}"
  sha256 "{sha256}"

  url "https://github.com/ChoSeongmin1128/claude-usage/releases/download/v#{{version}}/ClaudeUsage.dmg"
  name "ClaudeUsage"
  desc "Menu bar usage monitor for Claude, Codex, and Antigravity"
  homepage "https://github.com/ChoSeongmin1128/claude-usage"

  livecheck do
    url "https://choseongmin1128.github.io/claude-usage/appcast.xml"
    strategy :sparkle, &:short_version
  end

  auto_updates true
  depends_on macos: :sonoma

  app "ClaudeUsage.app"
end
'''


def render_cask(manifest):
    manifest = validate_manifest(manifest)
    return render_cask_values(manifest["version"], manifest["asset"]["sha256"])


def classify_cask(path, manifest):
    path = Path(path)
    if not path.exists():
        return "absent"
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 65536:
        return "unexpected"
    text = path.read_text(encoding="utf-8")
    version_matches = re.findall(r'^  version "([^"]+)"$', text, re.MULTILINE)
    sha_matches = re.findall(r'^  sha256 "([^"]+)"$', text, re.MULTILINE)
    if len(version_matches) != 1 or len(sha_matches) != 1:
        return "unexpected"
    current_version, current_sha = version_matches[0], sha_matches[0]
    try:
        if text != render_cask_values(current_version, current_sha):
            return "unexpected"
    except ValueError:
        return "unexpected"

    manifest = validate_manifest(manifest)
    expected_version = manifest["version"]
    expected_sha = manifest["asset"]["sha256"]
    current_tuple = tuple(map(int, current_version.split(".")))
    expected_tuple = tuple(map(int, expected_version.split(".")))
    if current_tuple == expected_tuple:
        return "matching" if current_sha == expected_sha else "conflicting-sha"
    return "outdated" if current_tuple < expected_tuple else "newer"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    manifest = commands.add_parser("manifest")
    manifest.add_argument("--repository", required=True)
    manifest.add_argument("--tag", required=True)
    manifest.add_argument("--version", required=True)
    manifest.add_argument("--build", required=True, type=int)
    manifest.add_argument("--asset-url", required=True)
    manifest.add_argument("--asset-size", required=True, type=int)
    manifest.add_argument("--asset-sha256", required=True)
    manifest.add_argument("--bundle-identifier", required=True)
    manifest.add_argument("--feed-url", required=True)
    manifest.add_argument("--team-identifier", required=True)
    manifest.add_argument("--minimum-system-version", required=True)

    for name in ["validate", "render"]:
        command = commands.add_parser(name)
        command.add_argument("--manifest", required=True)
    classify = commands.add_parser("classify")
    classify.add_argument("--manifest", required=True)
    classify.add_argument("--cask", required=True)

    args = parser.parse_args()
    if args.command == "manifest":
        value = build_manifest(
            args.repository,
            args.tag,
            args.version,
            args.build,
            args.asset_url,
            args.asset_size,
            args.asset_sha256,
            args.bundle_identifier,
            args.feed_url,
            args.team_identifier,
            args.minimum_system_version,
        )
        sys.stdout.write(canonical_json(value))
    elif args.command == "validate":
        sys.stdout.write(canonical_json(load_manifest(args.manifest)))
    elif args.command == "render":
        sys.stdout.write(render_cask(load_manifest(args.manifest)))
    else:
        print(classify_cask(args.cask, load_manifest(args.manifest)))


if __name__ == "__main__":
    try:
        main()
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
        sys.exit("Homebrew Cask 메타데이터 검증 실패")
