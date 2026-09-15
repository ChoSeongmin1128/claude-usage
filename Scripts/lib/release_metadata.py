#!/usr/bin/env python3
"""Release notes and appcast content shared by publishing and verification.

Notes stay UTF-8 plain text inside Sparkle's signed XML. The same Markdown
source is sent to GitHub; no second hand-edited/rendered copy is maintained.
"""

import argparse
import base64
import json
import hashlib
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
RELEASE = "https://choseongmin1128.github.io/claude-usage/release"
ET.register_namespace("claudeusage", RELEASE)


def notes_text(path, version):
    data = Path(path).read_bytes()
    if not 0 < len(data) <= 65536:
        raise ValueError("릴리스 노트는 1~65536 bytes여야 합니다")
    text = data.decode("utf-8")
    if "\r" in text or not text.endswith("\n") or text.startswith("\ufeff"):
        raise ValueError("릴리스 노트는 BOM 없는 UTF-8과 LF 줄바꿈으로 저장해 주세요")
    if any(ord(char) < 32 and char not in "\n\t" for char in text):
        raise ValueError("릴리스 노트에 제어 문자가 있습니다")
    lines = text.splitlines()
    if not re.fullmatch(r"# " + re.escape(version), lines[0]):
        raise ValueError("릴리스 노트 첫 줄은 '# 버전'이어야 합니다")
    if not any(line.startswith("- ") and line[2:].strip() for line in lines[1:]):
        raise ValueError("릴리스 노트에 사용자용 변경 내역을 적어 주세요")
    return text


def canonical_notes(root, version, path=None, commit=None):
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)", version):
        raise ValueError("유효한 X.Y.Z 버전이 필요합니다")
    root = Path(root).resolve()
    expected = root / "docs" / "release-notes" / (version + ".md")
    selected = Path(path) if path else expected
    if not selected.is_absolute():
        selected = root / selected
    if selected.is_symlink() or selected.resolve() != expected or expected.resolve() != expected:
        raise ValueError("버전에 해당하는 저장소 docs/release-notes 파일을 지정해 주세요")
    notes_text(selected, version)
    if commit:
        committed = subprocess.check_output(
            ["git", "-C", str(root), "show", commit + ":" + str(expected.relative_to(root))],
            stderr=subprocess.DEVNULL,
        )
        if committed != selected.read_bytes():
            raise ValueError("릴리스 노트가 배포 커밋의 내용과 다릅니다")
    return expected


def appcast_item(path):
    data = sys.stdin.buffer.read(2 * 1024 * 1024 + 1) if str(path) == "-" else Path(path).read_bytes()
    if b"<!DOCTYPE" in data or len(data) > 2 * 1024 * 1024:
        raise ValueError("appcast 크기가 제한을 초과했습니다")
    tree = ET.ElementTree(ET.fromstring(data))
    items = tree.findall("./channel/item")
    if len(items) != 1:
        raise ValueError("채널 appcast에는 정확히 한 개의 item이 필요합니다")
    return tree, items[0]


def embed_notes(appcast, notes, version):
    text = notes_text(notes, version)
    tree, item = appcast_item(appcast)
    for tag in ["description", "{" + SPARKLE + "}releaseNotesLink"]:
        for existing in item.findall(tag):
            item.remove(existing)
    description = ET.SubElement(item, "description", {"{" + SPARKLE + "}format": "plain-text"})
    description.text = text
    ET.indent(tree, space="    ")
    tree.write(appcast, encoding="utf-8", xml_declaration=True)


def verify_notes(appcast, notes, version, release_json=None):
    text = notes_text(notes, version)
    _, item = appcast_item(appcast)
    descriptions = item.findall("description")
    if len(descriptions) != 1 or item.find("{" + SPARKLE + "}releaseNotesLink") is not None:
        raise ValueError("appcast 노트는 한 개의 내장 description이어야 합니다")
    description = descriptions[0]
    if description.get("{" + SPARKLE + "}format") != "plain-text" or description.text != text:
        raise ValueError("appcast 노트가 정본과 다릅니다")
    if release_json:
        release = json.loads(Path(release_json).read_text(encoding="utf-8"))
        if release.get("body", "").rstrip("\n") != text.rstrip("\n"):
            raise ValueError("GitHub Release 본문이 노트 정본과 다릅니다")


def zip_digest(path):
    with Path(path).open("rb") as archive:
        digest = hashlib.sha256()
        for chunk in iter(lambda: archive.read(1024 * 1024), b""):
            digest.update(chunk)
        return digest.hexdigest()


def bind_zip(appcast, archive):
    tree, item = appcast_item(appcast)
    tag = "{" + RELEASE + "}zipSHA256"
    for existing in item.findall(tag):
        item.remove(existing)
    ET.SubElement(item, tag).text = zip_digest(archive)
    ET.indent(tree, space="    ")
    tree.write(appcast, encoding="utf-8", xml_declaration=True)


def verify_zip(appcast, archive):
    _, item = appcast_item(appcast)
    hashes = item.findall("{" + RELEASE + "}zipSHA256")
    if len(hashes) != 1 or hashes[0].text != zip_digest(archive):
        raise ValueError("ZIP이 서명된 feed의 SHA-256과 다릅니다")


def appcast_fields(path):
    _, item = appcast_item(path)
    enclosures = item.findall("enclosure")
    if len(enclosures) != 1:
        raise ValueError("appcast에 정확히 한 개의 enclosure가 필요합니다")
    enclosure = enclosures[0]
    values = [item.findtext("{" + SPARKLE + "}" + key) for key in ["shortVersionString", "version"]]
    values += [enclosure.get(key) for key in ["url", "{" + SPARKLE + "}edSignature", "length"]]
    if any(not value or any(char in value for char in "\r\n\t") for value in values):
        raise ValueError("appcast 메타데이터가 누락되었거나 잘못되었습니다")
    return "\t".join(values)


def channel_feed_state(path, channel):
    version, build, url, _, length = appcast_fields(path).split("\t")
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)", version):
        raise ValueError("유효한 feed 버전이 필요합니다")
    major, minor, patch = map(int, version.split("."))
    expected_build = major * 10000 + minor * 100 + patch
    if not re.fullmatch(r"[1-9][0-9]*", build) or not re.fullmatch(r"[1-9][0-9]*", length):
        raise ValueError("feed 버전·빌드·크기가 일치하지 않습니다")
    # Earlier published versions used a different build-number convention.
    if (major, minor, patch) >= (2, 4, 0) and build != str(expected_build):
        raise ValueError("feed 버전과 빌드가 일치하지 않습니다")
    tag = "v" + version + ("-staging" if channel == "staging" else "")
    archive = "ClaudeUsage.dmg" if (major, minor, patch) >= (2, 4, 15) else "ClaudeUsage.zip"
    expected_url = "https://github.com/ChoSeongmin1128/claude-usage/releases/download/" + tag + "/" + archive
    if url != expected_url:
        raise ValueError("feed의 채널·태그·업데이트 자산이 일치하지 않습니다")
    return "\t".join([version, build, tag])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    validate = commands.add_parser("notes-path")
    validate.add_argument("--root", required=True)
    validate.add_argument("--version", required=True)
    validate.add_argument("--path")
    validate.add_argument("--commit")
    for name in ["embed-notes", "verify-notes", "validate-notes"]:
        command = commands.add_parser(name)
        if name != "validate-notes":
            command.add_argument("--appcast", required=True)
        command.add_argument("--notes-file", required=True)
        command.add_argument("--version", required=True)
        if name == "verify-notes":
            command.add_argument("--release-json")
    for name in ["bind-zip", "verify-zip"]:
        command = commands.add_parser(name)
        command.add_argument("--appcast", required=True)
        command.add_argument("--zip-file", required=True)
    commands.add_parser("appcast-fields").add_argument("appcast")
    feed_state = commands.add_parser("channel-feed-state")
    feed_state.add_argument("--appcast", required=True)
    feed_state.add_argument("--channel", required=True, choices=["prod", "staging"])
    commands.add_parser("validate-public-key").add_argument("key")
    args = parser.parse_args()
    if args.command == "validate-public-key":
        if len(base64.b64decode(args.key, validate=True)) != 32:
            raise ValueError("32-byte Ed25519 공개키가 필요합니다")
    elif args.command == "bind-zip":
        bind_zip(args.appcast, args.zip_file)
    elif args.command == "verify-zip":
        verify_zip(args.appcast, args.zip_file)
    elif args.command == "notes-path":
        print(canonical_notes(args.root, args.version, args.path, args.commit))
    elif args.command == "validate-notes":
        notes_text(args.notes_file, args.version)
    elif args.command == "embed-notes":
        embed_notes(args.appcast, args.notes_file, args.version)
    elif args.command == "verify-notes":
        verify_notes(args.appcast, args.notes_file, args.version, args.release_json)
    elif args.command == "channel-feed-state":
        print(channel_feed_state(args.appcast, args.channel))
    else:
        print(appcast_fields(args.appcast))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, ET.ParseError, subprocess.CalledProcessError):
        # Never echo file contents, server text, or git output into diagnostics.
        sys.exit("릴리스 메타데이터 검증 실패: 파일 경로·버전·내용·배포 커밋을 확인해 주세요")
