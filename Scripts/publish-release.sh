#!/usr/bin/env bash
#
# ClaudeUsage GitHub Release 게시 + Sparkle appcast 생성.
#
# 사용:
#   Scripts/publish-release.sh vX.Y.Z [--draft] [--prerelease] [--notes "릴리스 노트"]
#
# 수행:
#   1. 태그 유효성 확인 (vX.Y.Z 형식 + 미사용 태그)
#   2. build/release/ 에 DMG 와 ZIP 이 준비돼있는지 확인
#   3. Sparkle generate_appcast 로 appcast.xml 생성 (Sparkle SPM artifact 사용)
#   4. git tag 생성 + push
#   5. gh release create 로 DMG + ZIP + appcast.xml 업로드
#   6. Sparkle 경로 설정된 경우 appcast 에 SUFeedURL 일치 확인
#
# 전제:
#   - Scripts/build-notarize-release.sh 이 성공적으로 완료돼 DMG/ZIP 존재
#   - gh (GitHub CLI) 로그인 상태
#   - git working tree clean (tag 대상 커밋이 HEAD)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build/release}"
DMG_PATH="${DMG_PATH:-$BUILD_DIR/ClaudeUsage.dmg}"
ZIP_PATH="${ZIP_PATH:-$BUILD_DIR/ClaudeUsage.zip}"
APPCAST_PATH="${APPCAST_PATH:-$BUILD_DIR/appcast.xml}"
LOCAL_XC_CONFIG_PATH="${LOCAL_XC_CONFIG_PATH:-$ROOT_DIR/Config/Sparkle.release.local.xcconfig}"

TAG=""
DRAFT=0
PRERELEASE=0
NOTES=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --draft) DRAFT=1; shift ;;
        --prerelease) PRERELEASE=1; shift ;;
        --notes) NOTES="$2"; shift 2 ;;
        -h|--help)
            cat <<USAGE
사용법:
    $0 vX.Y.Z [--draft] [--prerelease] [--notes "릴리스 노트"]
USAGE
            exit 0
            ;;
        v*.*.*) TAG="$1"; shift ;;
        *) echo "알 수 없는 인자: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$TAG" ]]; then
    echo "태그를 지정해 주세요. 예: $0 v0.5.0" >&2
    exit 2
fi

if ! [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[a-z0-9\.]+)?$ ]]; then
    echo "태그 형식이 올바르지 않습니다 (vX.Y.Z[-suffix]): $TAG" >&2
    exit 2
fi

echo "ClaudeUsage 릴리스 게시: $TAG"

# 1) 사전 검증
for bin in gh git; do
    command -v "$bin" >/dev/null 2>&1 || {
        echo "$bin 을 찾지 못했습니다." >&2
        exit 1
    }
done

if ! gh auth status >/dev/null 2>&1; then
    echo "gh 로그인이 안 돼있습니다. gh auth login 을 먼저 실행하세요." >&2
    exit 1
fi

if git -C "$ROOT_DIR" rev-parse "$TAG" >/dev/null 2>&1; then
    echo "태그가 이미 존재합니다: $TAG" >&2
    exit 1
fi

if ! git -C "$ROOT_DIR" diff-index --quiet HEAD --; then
    echo "커밋되지 않은 변경사항이 있습니다. git status 확인 후 재시도." >&2
    exit 1
fi

for f in "$DMG_PATH" "$ZIP_PATH"; do
    if [[ ! -f "$f" ]]; then
        echo "빌드 산출물이 없습니다: $f" >&2
        echo "Scripts/build-notarize-release.sh 를 먼저 실행해 주세요." >&2
        exit 1
    fi
done

# 2) Sparkle generate_appcast 경로 확보
echo
echo "1. generate_appcast 탐색"
GEN_APPCAST=""
for c in \
    "$HOME/Library/Developer/Xcode/DerivedData/ClaudeUsage"*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast
do
    if [[ -x "$c" ]]; then
        GEN_APPCAST="$c"
        break
    fi
done

if [[ -z "$GEN_APPCAST" ]] && command -v generate_appcast >/dev/null 2>&1; then
    GEN_APPCAST="$(command -v generate_appcast)"
fi

if [[ -z "$GEN_APPCAST" ]]; then
    echo "generate_appcast 를 찾지 못했습니다." >&2
    echo "Xcode 에서 한 번 빌드 후 재시도하거나 Sparkle 을 PATH 에 설치해 주세요." >&2
    exit 1
fi
echo "   $GEN_APPCAST"

# 3) appcast 생성용 스테이징 디렉토리 구성
echo
echo "2. appcast 생성"
STAGE_DIR="$(mktemp -d -t claudeusage-appcast)"
trap 'rm -rf "$STAGE_DIR"' EXIT

cp "$ZIP_PATH" "$STAGE_DIR/"

# SUFeedURL 에서 download-url-prefix 추론
FEED_URL="$(awk -F '=' '/^[[:space:]]*SUFeedURL[[:space:]]*=/ { sub(/^[[:space:]]+/,"",$2); sub(/[[:space:]]+$/,"",$2); print $2; exit }' "$LOCAL_XC_CONFIG_PATH" 2>/dev/null || true)"
URL_PREFIX=""
if [[ -n "$FEED_URL" ]]; then
    # GitHub Releases URL 규약: https://github.com/OWNER/REPO/releases/latest/download/appcast.xml
    # → 각 아티팩트는 같은 디렉토리 (이 태그 release 의 download/) 에 업로드됨
    if [[ "$FEED_URL" =~ ^(https://github\.com/[^/]+/[^/]+)/releases/latest/download/ ]]; then
        REPO_BASE="${BASH_REMATCH[1]}"
        URL_PREFIX="$REPO_BASE/releases/download/$TAG/"
    else
        URL_PREFIX="$(dirname "$FEED_URL")/"
    fi
    echo "   download URL prefix: $URL_PREFIX"
fi

# generate_appcast 호출 (SUFeedURL 기반 prefix 있으면 전달)
if [[ -n "$URL_PREFIX" ]]; then
    "$GEN_APPCAST" --download-url-prefix "$URL_PREFIX" -o "$APPCAST_PATH" "$STAGE_DIR"
else
    "$GEN_APPCAST" -o "$APPCAST_PATH" "$STAGE_DIR"
fi

if [[ ! -f "$APPCAST_PATH" ]]; then
    echo "appcast.xml 생성 실패" >&2
    exit 1
fi
echo "   생성됨: $APPCAST_PATH"

# 4) git tag + push
echo
echo "3. git tag 생성 + push"
git -C "$ROOT_DIR" tag -a "$TAG" -m "Release $TAG"
git -C "$ROOT_DIR" push origin "$TAG"

# 5) GitHub Release 생성 + 아티팩트 업로드
echo
echo "4. GitHub Release 생성 + 업로드"

GH_FLAGS=()
[[ "$DRAFT" == "1" ]] && GH_FLAGS+=(--draft)
[[ "$PRERELEASE" == "1" ]] && GH_FLAGS+=(--prerelease)
if [[ -n "$NOTES" ]]; then
    GH_FLAGS+=(--notes "$NOTES")
else
    GH_FLAGS+=(--generate-notes)
fi

gh release create "$TAG" \
    --title "$TAG" \
    "${GH_FLAGS[@]}" \
    "$DMG_PATH" \
    "$ZIP_PATH" \
    "$APPCAST_PATH"

echo
cat <<EOF
완료
    tag:      $TAG
    dmg:      $DMG_PATH
    zip:      $ZIP_PATH
    appcast:  $APPCAST_PATH
    URL:      $(gh release view "$TAG" --json url -q .url 2>/dev/null || echo "?")

Sparkle 클라이언트가 SUFeedURL ($FEED_URL) 을 폴링해 자동 업데이트를 감지합니다.
EOF
