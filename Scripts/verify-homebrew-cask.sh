#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT_DIR/Scripts/lib/homebrew_cask.py"
MANIFEST=""
TAP="choseongmin1128/tap"
DRY_RUN=0

usage() {
    cat <<'USAGE'
사용법:
  Scripts/verify-homebrew-cask.sh \
    --manifest /absolute/path/manifest.json \
    [--tap choseongmin1128/tap] \
    [--dry-run]

설치된 tap의 Cask를 검증하며 앱을 설치·실행하지 않습니다.
USAGE
}

die() {
    echo "오류: $*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --manifest)
            [[ $# -ge 2 ]] || die "--manifest 값이 필요합니다."
            MANIFEST="$2"
            shift 2
            ;;
        --tap)
            [[ $# -ge 2 ]] || die "--tap 값이 필요합니다."
            TAP="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "알 수 없는 인자: $1"
            ;;
    esac
done

[[ "$MANIFEST" == /*.json && -f "$MANIFEST" && ! -L "$MANIFEST" ]] \
    || die "--manifest는 .json으로 끝나는 절대 일반 파일이어야 합니다."
[[ "$TAP" == "choseongmin1128/tap" ]] \
    || die "공식 Homebrew tap만 검증할 수 있습니다: $TAP"
[[ -f "$TOOL" ]] || die "Homebrew Cask metadata tool을 찾지 못했습니다."
for binary in jq python3; do
    command -v "$binary" >/dev/null 2>&1 || die "필수 명령을 찾지 못했습니다: $binary"
done
python3 "$TOOL" validate --manifest "$MANIFEST" >/dev/null

VERSION="$(jq -r '.version' "$MANIFEST")"
SHA256="$(jq -r '.asset.sha256' "$MANIFEST")"
ASSET_URL="$(jq -r '.asset.url' "$MANIFEST")"
FULL_CASK="$TAP/claude-usage"

if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN: tap 조회, livecheck, audit, fetch를 실행하지 않았습니다."
    echo "  cask:    $FULL_CASK"
    echo "  version: $VERSION"
    exit 0
fi

command -v brew >/dev/null 2>&1 || die "필수 명령을 찾지 못했습니다: brew"

TAP_REPOSITORY="$(brew --repository "$TAP")" \
    || die "Homebrew tap이 설치되지 않았습니다: $TAP"
[[ "$TAP_REPOSITORY" == /* && -d "$TAP_REPOSITORY" && ! -L "$TAP_REPOSITORY" ]] \
    || die "Homebrew tap 저장소 경로가 유효하지 않습니다."
CASK_PATH="$TAP_REPOSITORY/Casks/claude-usage.rb"
[[ -f "$CASK_PATH" && ! -L "$CASK_PATH" ]] \
    || die "공식 Cask 파일을 찾지 못했습니다: $CASK_PATH"

STATE="$(python3 "$TOOL" classify --manifest "$MANIFEST" --cask "$CASK_PATH")"
[[ "$STATE" == "matching" ]] \
    || die "공개 Cask가 검증 manifest와 일치하지 않습니다: $STATE"

brew style --cask "$FULL_CASK"
brew audit --cask --strict --online "$FULL_CASK"

LIVECHECK_JSON="$(brew livecheck --cask --json "$FULL_CASK")"
printf '%s\n' "$LIVECHECK_JSON" \
    | jq -e --arg version "$VERSION" '
        length == 1
        and .[0].cask == "claude-usage"
        and .[0].version.current == $version
        and .[0].version.latest == $version
        and .[0].version.outdated == false
        and .[0].version.newer_than_upstream == false
    ' >/dev/null \
    || die "Homebrew livecheck가 manifest version과 일치하지 않습니다."

INFO_JSON="$(brew info --json=v2 --cask "$FULL_CASK")"
printf '%s\n' "$INFO_JSON" \
    | jq -e \
        --arg version "$VERSION" \
        --arg sha256 "$SHA256" \
        --arg url "$ASSET_URL" '
            (.casks | length) == 1
            and .casks[0].token == "claude-usage"
            and .casks[0].version == $version
            and .casks[0].sha256 == $sha256
            and .casks[0].url == $url
            and .casks[0].auto_updates == true
            and .casks[0].depends_on.macos.">=" == ["14"]
            and .casks[0].artifacts[0].app[0] == "ClaudeUsage.app"
        ' >/dev/null \
    || die "Homebrew Cask metadata가 manifest·설치 계약과 다릅니다."

brew fetch --cask "$FULL_CASK" >/dev/null
echo "Homebrew Cask 검증 완료"
echo "  cask:    $FULL_CASK"
echo "  version: $VERSION"
