#!/usr/bin/env bash
#
# ClaudeUsage Sparkle 배포 자격 부트스트랩 (1회 실행 스크립트).
#
# 수행:
#   1. Sparkle SPM artifact 에서 generate_keys 바이너리 위치 확인
#      (없으면 xcodebuild -resolvePackageDependencies 로 다운로드)
#   2. ED25519 키쌍 생성 (개인키는 macOS 키체인, 공개키는 stdout)
#   3. Config/Sparkle.release.local.xcconfig 템플릿 작성 또는 병합
#      - SUPublicEDKey 를 방금 생성한 값으로 채움
#      - SUFeedURL, NOTARY_PROFILE 은 기존 값 유지하거나 placeholder 로
#   4. 공개 trust root인 Config/Release.xcconfig의 SUPublicEDKey도 함께 갱신
#
# 멱등성:
#   기존에 키가 이미 생성돼 있으면 (Keychain에 "Private key for signing
#   Sparkle updates" 항목 존재) 기존 공개키를 재사용.
#   로컬 xcconfig 가 이미 있으면 덮어쓰지 않고 SUPublicEDKey 줄만 교체.
#   --force는 local xcconfig 전체를 다시 쓸 뿐 signing key를 회전하지 않음.
#

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_XCCONFIG="$ROOT_DIR/Config/Sparkle.release.local.xcconfig"
TRACKED_XCCONFIG="$ROOT_DIR/Config/Release.xcconfig"
LOCAL_UPDATE_TEMP=""
TRACKED_UPDATE_TEMP=""

OVERWRITE_CONFIG=0
DEFAULT_FEED_URL=""
DEFAULT_NOTARY_PROFILE="ClaudeUsageNotary"
CHANNEL="prod"

cleanup_update_temps() {
    local exit_code=$?
    local cleanup_failed=0
    local candidate

    for candidate in "$LOCAL_UPDATE_TEMP" "$TRACKED_UPDATE_TEMP"; do
        [[ -n "$candidate" && -e "$candidate" ]] || continue
        if ! rm -f -- "$candidate" || [[ -e "$candidate" ]]; then
            echo "임시 xcconfig를 정리하지 못했습니다: $candidate" >&2
            cleanup_failed=1
        fi
    done

    trap - EXIT
    if [[ "$exit_code" == "0" && "$cleanup_failed" == "1" ]]; then
        exit_code=1
    fi
    exit "$exit_code"
}

exit_on_signal() {
    exit 130
}

trap cleanup_update_temps EXIT
trap exit_on_signal INT TERM HUP

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)
            OVERWRITE_CONFIG=1
            shift
            ;;
        --feed-url)
            DEFAULT_FEED_URL="$2"
            shift 2
            ;;
        --channel)
            CHANNEL="$2"
            shift 2
            ;;
        --notary-profile)
            DEFAULT_NOTARY_PROFILE="$2"
            shift 2
            ;;
        -h|--help)
            cat <<USAGE
사용법:
    $0 [--force] [--feed-url URL] [--channel prod|staging] [--notary-profile NAME]

옵션:
    --force            local xcconfig를 다시 작성 (기존 signing key는 재사용)
    --feed-url URL     SUFeedURL 기본값 (기본: GitHub Pages 채널 URL)
    --channel NAME     기본 feed 채널 (prod 또는 staging, 기본: $CHANNEL)
    --notary-profile N NOTARY_PROFILE 기본값 (기본: $DEFAULT_NOTARY_PROFILE)
USAGE
            exit 0
            ;;
        *)
            echo "알 수 없는 옵션: $1" >&2
            exit 2
            ;;
    esac
done

validate_channel() {
    case "${1:-}" in
        prod|staging) ;;
        *)
            echo "지원하지 않는 채널입니다: ${1:-<empty>} (prod 또는 staging만 허용)" >&2
            exit 2
            ;;
    esac
}

derive_repo_pages_base_url() {
    local name_with_owner=""
    local remote_url=""

    if command -v gh >/dev/null 2>&1; then
        name_with_owner="$(
            cd "$ROOT_DIR"
            gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true
        )"
    fi

    if [[ "$name_with_owner" =~ ^([^/]+)/([^/]+)$ ]]; then
        local owner="${BASH_REMATCH[1]}"
        local repo="${BASH_REMATCH[2]}"
        local owner_lower
        owner_lower="$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')"
        printf 'https://%s.github.io/%s\n' "$owner_lower" "$repo"
        return 0
    fi

    remote_url="$(git -C "$ROOT_DIR" config --get remote.origin.url 2>/dev/null || echo "")"
    if [[ "$remote_url" =~ github\.com[:/](.+)/(.+?)(\.git)?$ ]]; then
        local owner="${BASH_REMATCH[1]}"
        local repo="${BASH_REMATCH[2]}"
        local owner_lower
        owner_lower="$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')"
        printf 'https://%s.github.io/%s\n' "$owner_lower" "$repo"
    fi
}

derive_default_feed_url_for_channel() {
    local channel="$1"
    local base_url
    base_url="$(derive_repo_pages_base_url || true)"

    if [[ -z "$base_url" ]]; then
        case "$channel" in
            prod) printf 'https://REPLACE_ME/appcast.xml\n' ;;
            staging) printf 'https://REPLACE_ME/channels/staging/appcast.xml\n' ;;
        esac
        return 0
    fi

    case "$channel" in
        prod) printf '%s/appcast.xml\n' "$base_url" ;;
        staging) printf '%s/channels/staging/appcast.xml\n' "$base_url" ;;
    esac
}

validate_channel "$CHANNEL"

# 기본 피드 URL: GitHub Pages 채널 URL 을 추정
if [[ -z "$DEFAULT_FEED_URL" ]]; then
    DEFAULT_FEED_URL="$(derive_default_feed_url_for_channel "$CHANNEL")"
fi

echo "ClaudeUsage Sparkle 자격 부트스트랩"
echo

# 1) generate_keys 위치 확인
echo "1. generate_keys 바이너리 탐색"

find_sparkle_binary() {
    local name="$1"
    # DerivedData 내 Sparkle SPM artifact
    local candidates=(
        "$HOME/Library/Developer/Xcode/DerivedData/ClaudeUsage"*/SourcePackages/artifacts/sparkle/Sparkle/bin/"$name"
    )
    for c in "${candidates[@]}"; do
        if [[ -x "$c" ]]; then
            echo "$c"
            return 0
        fi
    done
    # PATH 에 있으면 그걸 씀 (Sparkle을 brew 등으로 설치한 경우)
    if command -v "$name" >/dev/null 2>&1; then
        command -v "$name"
        return 0
    fi
    return 1
}

GEN_KEYS="$(find_sparkle_binary generate_keys || true)"
if [[ -z "$GEN_KEYS" ]]; then
    echo "   DerivedData 에 generate_keys 가 없어 SPM 의존성을 resolve 합니다"
    xcodebuild -project "$ROOT_DIR/ClaudeUsage.xcodeproj" \
        -resolvePackageDependencies >/dev/null
    GEN_KEYS="$(find_sparkle_binary generate_keys || true)"
fi

if [[ -z "$GEN_KEYS" ]]; then
    echo "generate_keys 를 찾지 못했습니다." >&2
    echo "Xcode 에서 한 번 빌드한 뒤 다시 시도하거나 Sparkle SPM 설정을 확인해 주세요." >&2
    exit 1
fi
echo "   $GEN_KEYS"
echo

# 2) 키 생성 또는 기존 공개키 추출
echo "2. ED25519 키 생성"

extract_public_key() {
    local output="$1"
    echo "$output" | grep -E '^[A-Za-z0-9+/=]{40,}$' | tail -n1 | tr -d '[:space:]'
}

PUBLIC_KEY=""
EXISTING_OUTPUT="$("$GEN_KEYS" -p 2>&1 || true)"
PUBLIC_KEY="$(extract_public_key "$EXISTING_OUTPUT")"

HAS_EXISTING_KEY=0
if [[ -n "$PUBLIC_KEY" ]]; then
    HAS_EXISTING_KEY=1
elif [[ -n "$EXISTING_OUTPUT" && "$EXISTING_OUTPUT" != *"No existing signing key found"* ]]; then
    echo "   기존 공개키 확인 실패:" >&2
    echo "$EXISTING_OUTPUT" >&2
fi

if [[ "$HAS_EXISTING_KEY" == "0" ]]; then
    echo "   기존 키 없음: 새 키 생성"
    # 키 생성 (공개키를 stdout 마지막 줄로 출력)
    GEN_OUTPUT="$("$GEN_KEYS" 2>&1)"
    PUBLIC_KEY="$(extract_public_key "$GEN_OUTPUT")"
else
    echo "   기존 키 사용 (키체인에 보관됨)"
    if [[ "$OVERWRITE_CONFIG" == "1" ]]; then
        echo "   --force는 설정만 다시 쓰며 signing key를 회전하지 않습니다"
    fi
fi

if [[ -z "$PUBLIC_KEY" ]]; then
    echo "공개키 추출 실패." >&2
    echo "   generate_keys 출력을 직접 확인해 주세요: $GEN_KEYS" >&2
    exit 1
fi

echo "   공개키: $PUBLIC_KEY"
echo

# 3) 로컬 xcconfig 작성/병합
echo "3. $LOCAL_XCCONFIG 작성"

write_xcconfig() {
    cat > "$LOCAL_XCCONFIG" <<EOF
// Sparkle release local overrides (gitignored).
// setup-sparkle-keys.sh 가 자동 생성했습니다. 수동 편집해도 됩니다.

SPARKLE_URL_SLASH = /
SUFeedURL = ${DEFAULT_FEED_URL/\/\//\$(SPARKLE_URL_SLASH)\$(SPARKLE_URL_SLASH)}
SUPublicEDKey = $PUBLIC_KEY
NOTARY_PROFILE = $DEFAULT_NOTARY_PROFILE
EOF
}

if [[ -f "$LOCAL_XCCONFIG" && "$OVERWRITE_CONFIG" != "1" ]]; then
    # 기존 파일 보존: SUPublicEDKey 줄만 대체
    if grep -q '^[[:space:]]*SUPublicEDKey' "$LOCAL_XCCONFIG"; then
        # macOS sed 호환 (in-place 편집 시 ''): 공개키 값만 치환
        LOCAL_UPDATE_TEMP="$(
            mktemp "$ROOT_DIR/Config/.Sparkle.release.local.xcconfig.XXXXXX"
        )"
        cp -p "$LOCAL_XCCONFIG" "$LOCAL_UPDATE_TEMP"
        awk -v key="$PUBLIC_KEY" '
            /^[[:space:]]*SUPublicEDKey/ {
                print "SUPublicEDKey = " key
                next
            }
            { print }
        ' "$LOCAL_XCCONFIG" > "$LOCAL_UPDATE_TEMP"
        mv "$LOCAL_UPDATE_TEMP" "$LOCAL_XCCONFIG"
        LOCAL_UPDATE_TEMP=""
        echo "   기존 파일의 SUPublicEDKey 만 업데이트"
    else
        echo "SUPublicEDKey = $PUBLIC_KEY" >> "$LOCAL_XCCONFIG"
        echo "   SUPublicEDKey 줄 추가"
    fi
else
    write_xcconfig
    echo "   새 xcconfig 작성 완료"
fi

[[ -f "$TRACKED_XCCONFIG" ]] || {
    echo "tracked release xcconfig를 찾지 못했습니다: $TRACKED_XCCONFIG" >&2
    exit 1
}
TRACKED_UPDATE_TEMP="$(
    mktemp "$ROOT_DIR/Config/.Release.xcconfig.XXXXXX"
)"
cp -p "$TRACKED_XCCONFIG" "$TRACKED_UPDATE_TEMP"
awk -v key="$PUBLIC_KEY" '
    /^[[:space:]]*SUPublicEDKey[[:space:]]*=/ {
        print "SUPublicEDKey = " key
        updated = 1
        next
    }
    { print }
    END {
        if (!updated) {
            print "SUPublicEDKey = " key
        }
    }
' "$TRACKED_XCCONFIG" > "$TRACKED_UPDATE_TEMP"
mv "$TRACKED_UPDATE_TEMP" "$TRACKED_XCCONFIG"
TRACKED_UPDATE_TEMP=""
echo "   tracked Sparkle trust root 업데이트: $TRACKED_XCCONFIG"

# .gitignore 반영 확인
if ! grep -q "Sparkle.release.local.xcconfig" "$ROOT_DIR/.gitignore" 2>/dev/null; then
    echo "Sparkle.release.local.xcconfig" >> "$ROOT_DIR/.gitignore"
    echo "   .gitignore 에 로컬 xcconfig 규칙 추가"
fi

echo
echo "완료"
echo "   공개키: $PUBLIC_KEY"
echo "   로컬 xcconfig: $LOCAL_XCCONFIG"
echo
echo "다음 단계"
echo "   1. Config/Release.xcconfig 의 SUPublicEDKey 변경을 검토하고 commit하세요"
echo "   2. Config/Sparkle.release.local.xcconfig 의 SUFeedURL 을 확인/수정하세요"
echo "   3. notarytool 자격이 없다면 다음 명령으로 저장:"
echo "        xcrun notarytool store-credentials \"$DEFAULT_NOTARY_PROFILE\" \\"
echo "            --apple-id YOUR@EMAIL --team-id YOUR_TEAM_ID"
echo "   4. Scripts/build-notarize-release.sh 실행"
