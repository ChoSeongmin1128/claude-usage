#!/usr/bin/env bash
#
# ClaudeUsage GitHub Release 게시 + Sparkle appcast 생성.
#
# 사용:
#   Scripts/publish-release.sh vX.Y.Z [--draft] [--prerelease] [--notes "릴리스 노트"]
#                                   [--feed-url URL] [--download-base-url URL]
#                                   [--skip-appcast-asset]
#
# 수행:
#   1. 태그 유효성 확인 (vX.Y.Z 형식 + 미사용 태그)
#   2. build/release/ 에 DMG 와 ZIP 이 준비돼있는지 확인
#   3. Sparkle appcast 생성 (feed URL 과 download base URL 을 분리 처리)
#   4. git tag 생성 + push
#   5. gh release create 로 DMG + ZIP (+ 선택적으로 appcast.xml) 업로드
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
FEED_URL_OVERRIDE=""
DOWNLOAD_BASE_URL_OVERRIDE=""
SKIP_APPCAST_ASSET=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --draft) DRAFT=1; shift ;;
        --prerelease) PRERELEASE=1; shift ;;
        --skip-appcast-asset) SKIP_APPCAST_ASSET=1; shift ;;
        --notes) NOTES="$2"; shift 2 ;;
        --feed-url) FEED_URL_OVERRIDE="$2"; shift 2 ;;
        --download-base-url) DOWNLOAD_BASE_URL_OVERRIDE="$2"; shift 2 ;;
        -h|--help)
            cat <<USAGE
사용법:
    $0 vX.Y.Z [--draft] [--prerelease] [--notes "릴리스 노트"]
               [--feed-url URL] [--download-base-url URL]
               [--skip-appcast-asset]

비고:
    - feed URL 과 download base URL 은 서로 다른 호스트를 가리켜도 됩니다.
    - appcast.xml 을 GitHub Pages 같은 별도 채널에 배포한다면 --skip-appcast-asset 을 권장합니다.
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

if ! [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9\.]+)?$ ]]; then
    echo "태그 형식이 올바르지 않습니다 (vX.Y.Z[-suffix]): $TAG" >&2
    exit 2
fi

extract_xcconfig_value() {
    local file="$1"
    local key="$2"
    [[ -f "$file" ]] || return 0
    awk -F '=' -v target="$key" '
        $1 ~ "^[[:space:]]*"target"[[:space:]]*$" {
            value=$2
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            sub(/^"/, "", value)
            sub(/"$/, "", value)
            gsub(/\$\(SPARKLE_URL_SLASH\)/, "/", value)
            gsub(/\$\(URL_SLASH\)/, "/", value)
            print value
            exit
        }
    ' "$file"
}

is_placeholder_value() {
    local value
    value="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
    [[ -z "$value" ]] && return 0
    [[ "$value" == *"change_me"* ]] && return 0
    [[ "$value" == *"placeholder"* ]] && return 0
    [[ "$value" == *"replace_with"* ]] && return 0
    [[ "$value" == *"example.com"* ]] && return 0
    [[ "$value" == *'$('* ]] && return 0
    return 1
}

expand_tag_placeholder() {
    local value="$1"
    if [[ "$value" == *"__TAG__"* ]]; then
        printf '%s\n' "${value//__TAG__/$TAG}"
        return 0
    fi
    printf '%s\n' "$value"
}

derive_repo_download_base_url() {
    local owner_and_repo=""
    if command -v gh >/dev/null 2>&1; then
        owner_and_repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
    fi

    if [[ "$owner_and_repo" =~ ^([^/]+)/([^/]+)$ ]]; then
        local owner="${BASH_REMATCH[1]}"
        local repo="${BASH_REMATCH[2]}"
        printf 'https://github.com/%s/%s/releases/download/%s\n' "$owner" "$repo" "$TAG"
        return 0
    fi

    local remote_url
    remote_url="$(git -C "$ROOT_DIR" config --get remote.origin.url 2>/dev/null || echo "")"
    if [[ "$remote_url" =~ github\.com[:/](.+)/(.+?)(\.git)?$ ]]; then
        local owner="${BASH_REMATCH[1]}"
        local repo="${BASH_REMATCH[2]}"
        printf 'https://github.com/%s/%s/releases/download/%s\n' "$owner" "$repo" "$TAG"
        return 0
    fi

    return 1
}

derive_download_base_url_from_feed_url() {
    local feed_url="$1"
    if is_placeholder_value "$feed_url"; then
        return 0
    fi
    if [[ "$feed_url" =~ ^(https://github\.com/[^/]+/[^/]+)/releases/latest/download/appcast\.xml$ ]]; then
        printf '%s/releases/download/%s\n' "${BASH_REMATCH[1]}" "$TAG"
        return 0
    fi
    printf '%s\n' "${feed_url%/appcast.xml}"
}

FEED_URL="${FEED_URL_OVERRIDE:-${SU_FEED_URL:-$(extract_xcconfig_value "$LOCAL_XC_CONFIG_PATH" "SUFeedURL")}}"
DOWNLOAD_BASE_URL="${DOWNLOAD_BASE_URL_OVERRIDE:-${DOWNLOAD_BASE_URL:-$(extract_xcconfig_value "$LOCAL_XC_CONFIG_PATH" "SPARKLE_DOWNLOAD_BASE_URL")}}"
DOWNLOAD_BASE_URL="$(expand_tag_placeholder "$DOWNLOAD_BASE_URL")"

if [[ -z "$DOWNLOAD_BASE_URL" ]]; then
    DOWNLOAD_BASE_URL="$(derive_repo_download_base_url || true)"
fi
if [[ -z "$DOWNLOAD_BASE_URL" ]]; then
    DOWNLOAD_BASE_URL="$(derive_download_base_url_from_feed_url "$FEED_URL")"
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

if [[ -z "$DOWNLOAD_BASE_URL" ]]; then
    echo "유효한 download base URL 을 찾지 못했습니다." >&2
    echo "--download-base-url, DOWNLOAD_BASE_URL, SPARKLE_DOWNLOAD_BASE_URL 중 하나를 제공해 주세요." >&2
    exit 1
fi

echo
echo "1. appcast 생성"
echo "   feed url: ${FEED_URL:-<미설정>}"
echo "   download base url: $DOWNLOAD_BASE_URL"

GEN_ARGS=(--download-base-url "$DOWNLOAD_BASE_URL" --tag "$TAG")
if [[ -n "$FEED_URL" ]]; then
    GEN_ARGS+=(--feed-url "$FEED_URL")
fi

"$ROOT_DIR/Scripts/generate-sparkle-appcast.sh" "${GEN_ARGS[@]}"

if [[ ! -f "$APPCAST_PATH" ]]; then
    echo "appcast.xml 생성 실패" >&2
    exit 1
fi
echo "   생성됨: $APPCAST_PATH"

# 2) git tag + push
echo
echo "2. git tag 생성 + push"
git -C "$ROOT_DIR" tag -a "$TAG" -m "Release $TAG"
git -C "$ROOT_DIR" push origin "$TAG"

# 3) GitHub Release 생성 + 아티팩트 업로드
echo
echo "3. GitHub Release 생성 + 업로드"

GH_FLAGS=()
[[ "$DRAFT" == "1" ]] && GH_FLAGS+=(--draft)
[[ "$PRERELEASE" == "1" ]] && GH_FLAGS+=(--prerelease)
if [[ -n "$NOTES" ]]; then
    GH_FLAGS+=(--notes "$NOTES")
else
    GH_FLAGS+=(--generate-notes)
fi

ASSETS=("$DMG_PATH" "$ZIP_PATH")
if [[ "$SKIP_APPCAST_ASSET" != "1" ]]; then
    ASSETS+=("$APPCAST_PATH")
fi

gh release create "$TAG" \
    --title "$TAG" \
    "${GH_FLAGS[@]}" \
    "${ASSETS[@]}"

echo
cat <<EOF
완료
    tag:                $TAG
    dmg:                $DMG_PATH
    zip:                $ZIP_PATH
    appcast:            $APPCAST_PATH
    feed url:           ${FEED_URL:-<미설정>}
    download base url:  $DOWNLOAD_BASE_URL
    URL:                $(gh release view "$TAG" --json url -q .url 2>/dev/null || echo "?")

EOF

if [[ "$SKIP_APPCAST_ASSET" == "1" ]]; then
    echo "appcast.xml 은 Release asset 으로 업로드하지 않았습니다. 별도 feed 경로에 배포해 주세요."
else
    echo "appcast.xml 을 Release asset 으로도 업로드했습니다. feed 경로가 별도라면 해당 경로에는 따로 배포해야 합니다."
fi
