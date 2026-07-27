#!/usr/bin/env bash
#
# ClaudeUsage GitHub Release 게시 + Sparkle appcast 생성.
#
# 사용:
#   Scripts/publish-release.sh vX.Y.Z [--prerelease] [--notes "릴리스 노트"]
#                                   [--feed-url URL] [--download-base-url URL]
#                                   [--channel prod|staging]
#                                   --expected-commit SHA
#                                   [--resume-exact-tag]
#                                   [--skip-pages-publish]
#
# 수행:
#   1. 태그 유효성 확인 (vX.Y.Z 형식 + 미사용 태그)
#   2. build/release/ 에 DMG 와 ZIP 이 준비돼있는지 확인
#   3. Sparkle appcast 생성 (feed URL 과 download base URL 을 분리 처리)
#   4. git tag 생성 + push
#   5. gh release create 로 DMG + ZIP (+ 선택적으로 appcast.xml) 업로드
#   6. public Pages는 이 스크립트에서 변경하지 않음. 원격 검증 후 driver가 게시
#
# 전제:
#   - Scripts/build-notarize-release.sh 이 성공적으로 완료돼 DMG/ZIP 존재
#   - gh (GitHub CLI) 로그인 상태
#   - git working tree clean (tag 대상 커밋이 HEAD)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Scripts/lib/release-driver-common.sh
source "$ROOT_DIR/Scripts/lib/release-driver-common.sh"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build/release}"
DMG_PATH="${DMG_PATH:-$BUILD_DIR/ClaudeUsage.dmg}"
ZIP_PATH="${ZIP_PATH:-$BUILD_DIR/ClaudeUsage.zip}"
APPCAST_PATH="${APPCAST_PATH:-$BUILD_DIR/appcast.xml}"
LOCAL_XC_CONFIG_PATH="${LOCAL_XC_CONFIG_PATH:-$ROOT_DIR/Config/Sparkle.release.local.xcconfig}"
RELEASE_XC_CONFIG_PATH="$ROOT_DIR/Config/Release.xcconfig"
SPARKLE_SIGNATURE_VERIFIER="$ROOT_DIR/Scripts/verify-sparkle-signature.swift"

TAG=""
PRERELEASE=0
NOTES=""
FEED_URL_OVERRIDE=""
DOWNLOAD_BASE_URL_OVERRIDE=""
RESUME_EXACT_TAG=0
CHANNEL=""
EXPECTED_COMMIT=""
PUBLISH_VERIFY_CACHE=""

cleanup_publish_release() {
    local exit_code=$?
    local cleanup_failed=0

    if [[ -n "$PUBLISH_VERIFY_CACHE" && -d "$PUBLISH_VERIFY_CACHE" ]]; then
        if ! rm -rf "$PUBLISH_VERIFY_CACHE" || [[ -e "$PUBLISH_VERIFY_CACHE" ]]; then
            echo "게시 전 Sparkle 검증 cache를 정리하지 못했습니다: $PUBLISH_VERIFY_CACHE" >&2
            cleanup_failed=1
        fi
    fi
    exit "$(release_cleanup_exit_code "$exit_code" "$cleanup_failed" 0)"
}
trap cleanup_publish_release EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

while [[ $# -gt 0 ]]; do
    case "$1" in
        --draft)
            echo "--draft는 immutable release 흐름에서 지원하지 않습니다." >&2
            exit 2
            ;;
        --prerelease) PRERELEASE=1; shift ;;
        --skip-appcast-asset)
            echo "--skip-appcast-asset은 정확히 세 asset을 요구하는 release 흐름에서 지원하지 않습니다." >&2
            exit 2
            ;;
        --skip-pages-publish) shift ;;
        --resume-exact-tag) RESUME_EXACT_TAG=1; shift ;;
        --notes) NOTES="$2"; shift 2 ;;
        --feed-url) FEED_URL_OVERRIDE="$2"; shift 2 ;;
        --download-base-url) DOWNLOAD_BASE_URL_OVERRIDE="$2"; shift 2 ;;
        --channel) CHANNEL="$2"; shift 2 ;;
        --expected-commit) EXPECTED_COMMIT="$2"; shift 2 ;;
        -h|--help)
            cat <<USAGE
사용법:
    $0 vX.Y.Z [--prerelease] [--notes "릴리스 노트"]
               [--feed-url URL] [--download-base-url URL]
               [--channel prod|staging]
               --expected-commit SHA
               [--resume-exact-tag]
               [--skip-pages-publish]

비고:
    - feed URL 과 download base URL 은 서로 다른 호스트를 가리켜도 됩니다.
    - channel 기본값은 stable 릴리스는 prod, prerelease 는 staging 입니다.
    - --expected-commit은 검증·빌드한 main commit을 고정하며 tag도 그 commit에만 생성합니다.
    - Release asset은 ClaudeUsage.dmg, ClaudeUsage.zip, appcast.xml 정확히 세 개입니다.
    - public Pages는 Release 원격 검증을 통과한 뒤 release driver가 별도로 게시합니다.
    - --resume-exact-tag 는 HEAD와 정확히 일치하는 tag만 재사용하며 기존 Release가 있으면 거부합니다.
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

if ! [[ "$EXPECTED_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
    echo "--expected-commit에는 검증·빌드한 40자리 commit SHA가 필요합니다." >&2
    exit 2
fi

extract_xcconfig_value() {
    local file="$1"
    local key="$2"
    [[ -f "$file" ]] || return 0
    awk -v target="$key" '
        $0 ~ "^[[:space:]]*"target"[[:space:]]*=" {
            value=$0
            sub("^[[:space:]]*" target "[[:space:]]*=[[:space:]]*", "", value)
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
    [[ "$value" == *"\$("* ]] && return 0
    return 1
}

validate_channel() {
    case "${1:-}" in
        prod|staging) ;;
        *)
            echo "지원하지 않는 채널입니다: ${1:-<empty>} (prod 또는 staging만 허용)" >&2
            exit 2
            ;;
    esac
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
        owner_and_repo="$(
            cd "$ROOT_DIR"
            gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true
        )"
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

derive_repo_pages_base_url() {
    local owner_and_repo=""
    if command -v gh >/dev/null 2>&1; then
        owner_and_repo="$(
            cd "$ROOT_DIR"
            gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true
        )"
    fi

    if [[ "$owner_and_repo" =~ ^([^/]+)/([^/]+)$ ]]; then
        local owner="${BASH_REMATCH[1]}"
        local repo="${BASH_REMATCH[2]}"
        local owner_lower
        owner_lower="$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')"
        printf 'https://%s.github.io/%s\n' "$owner_lower" "$repo"
        return 0
    fi

    local remote_url
    remote_url="$(git -C "$ROOT_DIR" config --get remote.origin.url 2>/dev/null || echo "")"
    if [[ "$remote_url" =~ github\.com[:/](.+)/(.+?)(\.git)?$ ]]; then
        local owner="${BASH_REMATCH[1]}"
        local repo="${BASH_REMATCH[2]}"
        local owner_lower
        owner_lower="$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')"
        printf 'https://%s.github.io/%s\n' "$owner_lower" "$repo"
        return 0
    fi

    return 1
}

derive_default_feed_url_for_channel() {
    local channel="$1"
    local base_url
    base_url="$(derive_repo_pages_base_url || true)"
    [[ -n "$base_url" ]] || return 0

    case "$channel" in
        prod) printf '%s/appcast.xml\n' "$base_url" ;;
        staging) printf '%s/channels/staging/appcast.xml\n' "$base_url" ;;
    esac
}

is_github_pages_feed_url() {
    local feed_url="$1"
    local base_url
    base_url="$(derive_repo_pages_base_url || true)"
    [[ -n "$base_url" ]] || return 1
    [[ "$feed_url" == "$base_url"/appcast.xml || "$feed_url" == "$base_url"/channels/*/appcast.xml ]]
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

if [[ -z "$CHANNEL" ]]; then
    if [[ "$PRERELEASE" == "1" ]]; then
        CHANNEL="staging"
    else
        CHANNEL="prod"
    fi
fi
validate_channel "$CHANNEL"
case "$CHANNEL" in
    prod)
        [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && "$PRERELEASE" == "0" ]] || {
            echo "prod는 exact vX.Y.Z tag와 non-prerelease 조합만 허용합니다: tag=$TAG, prerelease=$PRERELEASE" >&2
            exit 2
        }
        ;;
    staging)
        [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-staging$ && "$PRERELEASE" == "1" ]] || {
            echo "staging은 exact vX.Y.Z-staging tag와 --prerelease 조합만 허용합니다: tag=$TAG, prerelease=$PRERELEASE" >&2
            exit 2
        }
        ;;
esac

CONFIGURED_FEED_URL="$(extract_xcconfig_value "$LOCAL_XC_CONFIG_PATH" "SUFeedURL")"
DERIVED_FEED_URL="$(derive_default_feed_url_for_channel "$CHANNEL" || true)"
FEED_URL="${FEED_URL_OVERRIDE:-${SU_FEED_URL:-${DERIVED_FEED_URL:-$CONFIGURED_FEED_URL}}}"
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
for bin in gh git xcrun stat; do
    command -v "$bin" >/dev/null 2>&1 || {
        echo "$bin 을 찾지 못했습니다." >&2
        exit 1
    }
done

if ! gh auth status >/dev/null 2>&1; then
    echo "gh 로그인이 안 돼있습니다. gh auth login 을 먼저 실행하세요." >&2
    exit 1
fi

TARGET_REPOSITORY="$(
    cd "$ROOT_DIR"
    gh repo view --json nameWithOwner -q .nameWithOwner
)"
[[ "$TARGET_REPOSITORY" =~ ^[^/]+/[^/]+$ ]] || {
    echo "대상 GitHub repository를 확인하지 못했습니다." >&2
    exit 1
}

if RELEASE_LOOKUP="$(gh api "repos/$TARGET_REPOSITORY/releases/tags/$TAG" 2>&1)"; then
    RELEASE_EXISTS=1
else
    if [[ "$RELEASE_LOOKUP" == *"HTTP 404"* ]]; then
        RELEASE_EXISTS=0
    else
        printf '%s\n' "$RELEASE_LOOKUP" >&2
        echo "기존 GitHub Release 상태를 확인하지 못했습니다: $TAG" >&2
        exit 1
    fi
fi
[[ "$RELEASE_EXISTS" == "0" ]] || {
    echo "기존 GitHub Release는 수정하거나 덮어쓰지 않습니다: $TAG" >&2
    exit 1
}

LOCAL_TAG_COMMIT="$(git -C "$ROOT_DIR" rev-parse "refs/tags/$TAG^{commit}" 2>/dev/null || true)"
REMOTE_TAG_LINES="$(
    git -C "$ROOT_DIR" ls-remote --tags origin \
        "refs/tags/$TAG" "refs/tags/$TAG^{}"
)"
REMOTE_TAG_COMMIT="$(
    printf '%s\n' "$REMOTE_TAG_LINES" \
        | awk -v peeled="refs/tags/$TAG^{}" -v direct="refs/tags/$TAG" '
            $2 == peeled { peeledCommit = $1 }
            $2 == direct { directCommit = $1 }
            END {
                if (peeledCommit != "") {
                    print peeledCommit
                } else if (directCommit != "") {
                    print directCommit
                }
            }
        '
)"

if [[ "$RESUME_EXACT_TAG" == "1" ]]; then
    [[ -n "$LOCAL_TAG_COMMIT" && "$LOCAL_TAG_COMMIT" == "$EXPECTED_COMMIT" ]] || {
        echo "resume tag가 검증된 commit과 정확히 일치하지 않습니다: $TAG" >&2
        exit 1
    }
    [[ -z "$REMOTE_TAG_COMMIT" || "$REMOTE_TAG_COMMIT" == "$EXPECTED_COMMIT" ]] || {
        echo "원격 resume tag가 검증된 commit과 다릅니다: $TAG" >&2
        exit 1
    }
else
    [[ -z "$LOCAL_TAG_COMMIT" ]] || {
        echo "태그가 이미 존재합니다: $TAG" >&2
        exit 1
    }
    [[ -z "$REMOTE_TAG_COMMIT" ]] || {
        echo "원격 태그가 이미 존재합니다: $TAG" >&2
        exit 1
    }
fi

validate_release_source() {
    HEAD_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
    CURRENT_BRANCH="$(git -C "$ROOT_DIR" branch --show-current)"
    ORIGIN_MAIN_COMMIT="$(
        git -C "$ROOT_DIR" ls-remote origin refs/heads/main \
            | awk 'NR == 1 { print $1 }'
    )"
    [[ "$CURRENT_BRANCH" == "main" ]] || {
        echo "릴리스 source branch는 main이어야 합니다: $CURRENT_BRANCH" >&2
        exit 1
    }
    [[ "$HEAD_COMMIT" == "$EXPECTED_COMMIT" ]] || {
        echo "현재 HEAD가 검증·빌드한 commit과 달라졌습니다: expected=$EXPECTED_COMMIT, HEAD=$HEAD_COMMIT" >&2
        exit 1
    }
    [[ "$ORIGIN_MAIN_COMMIT" == "$EXPECTED_COMMIT" ]] || {
        echo "origin/main이 검증·빌드한 commit과 다릅니다: expected=$EXPECTED_COMMIT, origin/main=$ORIGIN_MAIN_COMMIT" >&2
        exit 1
    }
    [[ -z "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=all)" ]] || {
        echo "커밋되지 않은 변경사항이 있습니다. git status 확인 후 재시도." >&2
        exit 1
    }
}
validate_release_source

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
echo "   channel: $CHANNEL"
echo "   feed url: ${FEED_URL:-<미설정>}"
echo "   download base url: $DOWNLOAD_BASE_URL"

GEN_ARGS=(--download-base-url "$DOWNLOAD_BASE_URL" --tag "$TAG")
if [[ -n "$FEED_URL" ]]; then
    GEN_ARGS+=(--feed-url "$FEED_URL")
fi

ARTIFACTS_DIR="$BUILD_DIR" APPCAST_OUTPUT="$APPCAST_PATH" \
    "$ROOT_DIR/Scripts/generate-sparkle-appcast.sh" "${GEN_ARGS[@]}"

if [[ ! -f "$APPCAST_PATH" ]]; then
    echo "appcast.xml 생성 실패" >&2
    exit 1
fi
echo "   생성됨: $APPCAST_PATH"

TRACKED_PUBLIC_KEY="$(extract_xcconfig_value "$RELEASE_XC_CONFIG_PATH" "SUPublicEDKey")"
is_placeholder_value "$TRACKED_PUBLIC_KEY" && {
    echo "tracked Release.xcconfig의 Sparkle 공개키가 비어 있거나 유효하지 않습니다." >&2
    exit 1
}
PROJECT_VERSION="$(read_project_release_version "$ROOT_DIR/ClaudeUsage.xcodeproj/project.pbxproj")" \
    || {
        echo "project MARKETING_VERSION을 하나로 확정하지 못했습니다." >&2
        exit 1
    }
PROJECT_BUILD="$(read_project_release_build "$ROOT_DIR/ClaudeUsage.xcodeproj/project.pbxproj")" \
    || {
        echo "project CURRENT_PROJECT_VERSION을 하나로 확정하지 못했습니다." >&2
        exit 1
    }
TAG_VERSION="$(release_version_from_tag "$TAG")" || {
    echo "tag에서 numeric version을 읽지 못했습니다: $TAG" >&2
    exit 1
}
APPCAST_VERSION="$(
    sed -n 's|.*<sparkle:shortVersionString>\([^<]*\)</sparkle:shortVersionString>.*|\1|p' "$APPCAST_PATH" \
        | sed -n '1p'
)"
APPCAST_BUILD="$(
    sed -n 's|.*<sparkle:version>\([^<]*\)</sparkle:version>.*|\1|p' "$APPCAST_PATH" \
        | sed -n '1p'
)"
APPCAST_ENCLOSURE="$(
    sed -n 's|.*<enclosure[^>]*url="\([^"]*\)".*|\1|p' "$APPCAST_PATH" \
        | sed -n '1p'
)"
APPCAST_SIGNATURE="$(
    sed -n 's|.*sparkle:edSignature="\([^"]*\)".*|\1|p' "$APPCAST_PATH" \
        | sed -n '1p'
)"
APPCAST_LENGTH="$(
    sed -n 's|.*<enclosure[^>]*length="\([^"]*\)".*|\1|p' "$APPCAST_PATH" \
        | sed -n '1p'
)"
EXPECTED_ENCLOSURE="https://github.com/$TARGET_REPOSITORY/releases/download/$TAG/ClaudeUsage.zip"
ZIP_SIZE="$(stat -f%z "$ZIP_PATH")"
[[ "$TAG_VERSION" == "$PROJECT_VERSION" && "$APPCAST_VERSION" == "$PROJECT_VERSION" ]] || {
    echo "tag/project/appcast version이 일치하지 않습니다: tag=$TAG_VERSION, project=$PROJECT_VERSION, appcast=$APPCAST_VERSION" >&2
    exit 1
}
[[ "$APPCAST_BUILD" == "$PROJECT_BUILD" ]] || {
    echo "project/appcast build가 일치하지 않습니다: project=$PROJECT_BUILD, appcast=$APPCAST_BUILD" >&2
    exit 1
}
[[ "$APPCAST_ENCLOSURE" == "$EXPECTED_ENCLOSURE" ]] || {
    echo "appcast enclosure가 target Release와 다릅니다: expected=$EXPECTED_ENCLOSURE, actual=$APPCAST_ENCLOSURE" >&2
    exit 1
}
[[ "$APPCAST_LENGTH" == "$ZIP_SIZE" && -n "$APPCAST_SIGNATURE" ]] || {
    echo "appcast ZIP length 또는 Ed25519 signature가 유효하지 않습니다." >&2
    exit 1
}
PUBLISH_VERIFY_CACHE="$(mktemp -d "$BUILD_DIR/.publish-sparkle-verify.XXXXXX")"
xcrun swift \
    -module-cache-path "$PUBLISH_VERIFY_CACHE" \
    "$SPARKLE_SIGNATURE_VERIFIER" \
    "$ZIP_PATH" \
    "$TRACKED_PUBLIC_KEY" \
    "$APPCAST_SIGNATURE"
rm -rf "$PUBLISH_VERIFY_CACHE"
[[ ! -e "$PUBLISH_VERIFY_CACHE" ]] || {
    echo "게시 전 Sparkle 검증 cache를 정리하지 못했습니다: $PUBLISH_VERIFY_CACHE" >&2
    exit 1
}
PUBLISH_VERIFY_CACHE=""
echo "   tracked 공개키 기준 Sparkle 서명 검증 완료"

# 2) git tag + push
echo
echo "2. git tag 생성 + push"
validate_release_source
if [[ "$RESUME_EXACT_TAG" == "1" ]]; then
    if [[ -z "$REMOTE_TAG_COMMIT" ]]; then
        git -C "$ROOT_DIR" push origin "refs/tags/$TAG"
    else
        echo "   HEAD와 일치하는 원격 tag 재사용: $TAG"
    fi
else
    git -C "$ROOT_DIR" tag -a "$TAG" -m "Release $TAG" "$EXPECTED_COMMIT"
    git -C "$ROOT_DIR" push origin "$TAG"
fi

# 3) GitHub Release 생성 + 아티팩트 업로드
echo
echo "3. GitHub Release 생성 + 업로드"

GH_FLAGS=()
[[ "$PRERELEASE" == "1" ]] && GH_FLAGS+=(--prerelease)
if [[ -n "$NOTES" ]]; then
    GH_FLAGS+=(--notes "$NOTES")
else
    GH_FLAGS+=(--generate-notes)
fi

ASSETS=("$DMG_PATH" "$ZIP_PATH" "$APPCAST_PATH")

gh release create "$TAG" \
    --repo "$TARGET_REPOSITORY" \
    --title "$TAG" \
    "${GH_FLAGS[@]}" \
    "${ASSETS[@]}"

# 4) GitHub Pages channel appcast 보류
echo
echo "4. public Pages 게시 보류"
echo "   Release 원격 검증 뒤 release driver가 검증된 appcast 바이트만 게시합니다."

echo
cat <<EOF
완료
    tag:                $TAG
    dmg:                $DMG_PATH
    zip:                $ZIP_PATH
    appcast:            $APPCAST_PATH
    channel:            $CHANNEL
    feed url:           ${FEED_URL:-<미설정>}
    download base url:  $DOWNLOAD_BASE_URL
    URL:                $(gh release view "$TAG" --repo "$TARGET_REPOSITORY" --json url -q .url 2>/dev/null || echo "?")

EOF

echo "appcast.xml 을 Release asset으로 업로드했습니다."
