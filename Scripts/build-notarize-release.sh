#!/usr/bin/env bash
#
# ClaudeUsage release 파이프라인.
#
# 단계:
#   1. Xcode archive
#   2. notarization 용 ZIP 생성
#   3. 앱 notarization (xcrun notarytool submit --wait)
#   4. 앱 staple
#   5. 스테이플된 앱으로 ZIP 재생성
#   6. Scripts/make-dmg.sh 호출해 설치용 DMG 생성
#   7. DMG 서명 (make-dmg.sh 내부에서 처리)
#   8. DMG notarization
#   9. DMG staple
#  10. 최종 Gatekeeper 검증
#
# 전제:
#   Config/Sparkle.release.local.xcconfig 에 SUFeedURL, SUPublicEDKey 가
#   유효하게 채워져 있어야 합니다.
#   공증 자격 증명은 아래 우선순위로 찾습니다.
#     1. NOTARY_KEY_PATH / NOTARY_KEY_ID / NOTARY_ISSUER
#     2. NOTARY_APPLE_ID / NOTARY_PASSWORD / NOTARY_TEAM_ID
#     3. Config/Sparkle.release.local.xcconfig 의 NOTARY_PROFILE
#   Scripts/setup-sparkle-keys.sh 로 1회성 세팅 가능.
#   RELEASE_CHANNEL=prod|staging 을 주면 해당 채널 feed URL 을 빌드에
#   강제로 주입합니다.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build/release}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$BUILD_DIR/ClaudeUsage.xcarchive}"
APP_PATH="$ARCHIVE_PATH/Products/Applications/ClaudeUsage.app"
ZIP_PATH="${ZIP_PATH:-$BUILD_DIR/ClaudeUsage.zip}"
DMG_PATH="${DMG_PATH:-$BUILD_DIR/ClaudeUsage.dmg}"
SCHEME="${SCHEME:-ClaudeUsage}"
CONFIGURATION="${CONFIGURATION:-Release}"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/ClaudeUsage.xcodeproj}"
XC_CONFIG_PATH="${XC_CONFIG_PATH:-$ROOT_DIR/Config/Release.xcconfig}"
LOCAL_XC_CONFIG_PATH="${LOCAL_XC_CONFIG_PATH:-$ROOT_DIR/Config/Sparkle.release.local.xcconfig}"
MAKE_DMG_SCRIPT="$ROOT_DIR/Scripts/make-dmg.sh"
ENTITLEMENTS_PATH="${ENTITLEMENTS_PATH:-$ROOT_DIR/ClaudeUsage/ClaudeUsage.entitlements}"
SKIP_DMG="${SKIP_DMG:-0}"
EFFECTIVE_XC_CONFIG_PATH="$XC_CONFIG_PATH"
TEMP_XC_CONFIG_PATH=""

cleanup() {
    if [[ -n "$TEMP_XC_CONFIG_PATH" && -f "$TEMP_XC_CONFIG_PATH" ]]; then
        rm -f "$TEMP_XC_CONFIG_PATH"
    fi
}
trap cleanup EXIT

create_app_zip() {
    # AppleDouble files break Gatekeeper after ZIP-based installs.
    COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --keepParent "$APP_PATH" "$ZIP_PATH"
}

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
    [[ "$value" == *"replace_me"* ]] && return 0
    [[ "$value" == *"example.com"* ]] && return 0
    [[ "$value" == *'$('* ]] && return 0
    return 1
}

xcconfig_url_literal() {
    local value="$1"
    printf '%s\n' "${value/\/\//\$(SPARKLE_URL_SLASH)\$(SPARKLE_URL_SLASH)}"
}

validate_release_channel() {
    case "${1:-}" in
        ""|prod|staging) ;;
        *)
            echo "지원하지 않는 RELEASE_CHANNEL 입니다: ${1:-<empty>} (prod 또는 staging만 허용)" >&2
            exit 2
            ;;
    esac
}

derive_repo_pages_base_url() {
    local name_with_owner=""
    local remote_url

    if command -v gh >/dev/null 2>&1; then
        name_with_owner="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
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
        return 0
    fi

    if [[ "$remote_url" =~ ^[^@]+@[^:]+:([^/]+)/(.+?)(\.git)?$ ]]; then
        local owner="${BASH_REMATCH[1]}"
        local repo="${BASH_REMATCH[2]}"
        local owner_lower
        owner_lower="$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')"
        printf 'https://%s.github.io/%s\n' "$owner_lower" "$repo"
        return 0
    fi
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

NOTARY_PROFILE="${NOTARY_PROFILE:-$(extract_xcconfig_value "$LOCAL_XC_CONFIG_PATH" "NOTARY_PROFILE")}"
NOTARY_APPLE_ID="${NOTARY_APPLE_ID:-${APPLE_ID:-}}"
NOTARY_PASSWORD="${NOTARY_PASSWORD:-${APPLE_PASSWORD:-}}"
NOTARY_TEAM_ID="${NOTARY_TEAM_ID:-${APPLE_TEAM_ID:-}}"
NOTARY_KEY_PATH="${NOTARY_KEY_PATH:-}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
NOTARY_ISSUER="${NOTARY_ISSUER:-}"
NOTARY_SUBMIT_ARGS=()
NOTARY_AUTH_DESCRIPTION=""
CERT_HASH="${CERT_HASH:-9A12730390B85461D1A98C907C61A7AA265EE214}"
RELEASE_CHANNEL="${RELEASE_CHANNEL:-}"

# ── 사전 검증 ────────────────────────────────────────────────

if [[ ! -f "$PROJECT_PATH/project.pbxproj" ]]; then
    echo "Xcode 프로젝트를 찾지 못했습니다: $PROJECT_PATH" >&2
    exit 1
fi

if [[ ! -f "$XC_CONFIG_PATH" ]]; then
    echo "release xcconfig를 찾지 못했습니다: $XC_CONFIG_PATH" >&2
    exit 1
fi

if [[ ! -f "$ENTITLEMENTS_PATH" ]]; then
    echo "entitlements 파일을 찾지 못했습니다: $ENTITLEMENTS_PATH" >&2
    exit 1
fi

validate_release_channel "$RELEASE_CHANNEL"

CONFIGURED_FEED_URL="$(extract_xcconfig_value "$LOCAL_XC_CONFIG_PATH" "SUFeedURL")"
CONFIGURED_PUBLIC_KEY="$(extract_xcconfig_value "$LOCAL_XC_CONFIG_PATH" "SUPublicEDKey")"
DERIVED_FEED_URL=""
if [[ -n "$RELEASE_CHANNEL" ]]; then
    DERIVED_FEED_URL="$(derive_default_feed_url_for_channel "$RELEASE_CHANNEL" || true)"
fi

FEED_URL="${SU_FEED_URL:-${DERIVED_FEED_URL:-$CONFIGURED_FEED_URL}}"
PUBLIC_KEY="${SU_PUBLIC_ED_KEY:-$CONFIGURED_PUBLIC_KEY}"

if is_placeholder_value "$FEED_URL"; then
    echo "유효한 SUFeedURL 을 찾지 못했습니다." >&2
    echo "Scripts/setup-sparkle-keys.sh 를 먼저 실행하거나 Config/Sparkle.release.local.xcconfig 를 확인해 주세요." >&2
    exit 1
fi

if is_placeholder_value "$PUBLIC_KEY"; then
    echo "유효한 SUPublicEDKey 를 찾지 못했습니다." >&2
    echo "Scripts/setup-sparkle-keys.sh 를 먼저 실행해 주세요." >&2
    exit 1
fi

if [[ -n "$NOTARY_KEY_PATH$NOTARY_KEY_ID$NOTARY_ISSUER" ]]; then
    if [[ -z "$NOTARY_KEY_PATH" || -z "$NOTARY_KEY_ID" || -z "$NOTARY_ISSUER" ]]; then
        echo "App Store Connect API key 공증을 쓰려면 NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER 를 모두 지정해야 합니다." >&2
        exit 1
    fi
    NOTARY_SUBMIT_ARGS=(
        --key "$NOTARY_KEY_PATH"
        --key-id "$NOTARY_KEY_ID"
        --issuer "$NOTARY_ISSUER"
    )
    NOTARY_AUTH_DESCRIPTION="App Store Connect API key"
elif [[ -n "$NOTARY_APPLE_ID$NOTARY_PASSWORD$NOTARY_TEAM_ID" ]]; then
    if [[ -z "$NOTARY_APPLE_ID" || -z "$NOTARY_PASSWORD" || -z "$NOTARY_TEAM_ID" ]]; then
        echo "Apple ID 공증을 쓰려면 NOTARY_APPLE_ID, NOTARY_PASSWORD, NOTARY_TEAM_ID 를 모두 지정해야 합니다." >&2
        exit 1
    fi
    NOTARY_SUBMIT_ARGS=(
        --apple-id "$NOTARY_APPLE_ID"
        --password "$NOTARY_PASSWORD"
        --team-id "$NOTARY_TEAM_ID"
    )
    NOTARY_AUTH_DESCRIPTION="Apple ID 환경 변수"
elif [[ -n "$NOTARY_PROFILE" ]] && ! is_placeholder_value "$NOTARY_PROFILE"; then
    NOTARY_SUBMIT_ARGS=(--keychain-profile "$NOTARY_PROFILE")
    NOTARY_AUTH_DESCRIPTION="keychain profile: $NOTARY_PROFILE"
else
    echo "유효한 공증 자격 증명을 찾지 못했습니다." >&2
    echo "NOTARY_APPLE_ID/NOTARY_PASSWORD/NOTARY_TEAM_ID 또는 NOTARY_PROFILE 을 확인해 주세요." >&2
    exit 1
fi

echo "ClaudeUsage release 산출물 빌드 + notarization + DMG 를 시작합니다"
if [[ -n "$RELEASE_CHANNEL" ]]; then
    echo "  - release channel: $RELEASE_CHANNEL"
fi
echo "  - notary auth: $NOTARY_AUTH_DESCRIPTION"

for bin in xcodebuild xcrun hdiutil codesign; do
    command -v "$bin" >/dev/null 2>&1 || {
        echo "$bin 을 찾지 못했습니다." >&2
        exit 1
    }
done

if [[ "$SKIP_DMG" != "1" && ! -x "$MAKE_DMG_SCRIPT" ]]; then
    echo "make-dmg.sh 를 찾지 못했습니다: $MAKE_DMG_SCRIPT" >&2
    exit 1
fi

mkdir -p "$BUILD_DIR"
rm -rf "$ARCHIVE_PATH" "$ZIP_PATH" "$DMG_PATH"

if [[ -n "$RELEASE_CHANNEL" || -n "${SU_FEED_URL:-}" || -n "${SU_PUBLIC_ED_KEY:-}" ]]; then
    TEMP_XC_CONFIG_PATH="$(mktemp "$BUILD_DIR/release-override.XXXXXX").xcconfig"
    cat > "$TEMP_XC_CONFIG_PATH" <<EOF
#include "$XC_CONFIG_PATH"
SPARKLE_URL_SLASH = /
SUFeedURL = $(xcconfig_url_literal "$FEED_URL")
SUPublicEDKey = $PUBLIC_KEY
EOF
    EFFECTIVE_XC_CONFIG_PATH="$TEMP_XC_CONFIG_PATH"
    echo "빌드용 임시 xcconfig override 생성: $TEMP_XC_CONFIG_PATH"
    if [[ -n "$RELEASE_CHANNEL" ]]; then
        echo "  - RELEASE_CHANNEL 강제 적용: $RELEASE_CHANNEL"
    fi
    echo "  - SUFeedURL: $FEED_URL"
fi

# ── 1. Xcode archive ────────────────────────────────────────

echo
echo "1. Xcode archive 생성"
xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -xcconfig "$EFFECTIVE_XC_CONFIG_PATH" \
    -archivePath "$ARCHIVE_PATH" \
    archive

if [[ ! -d "$APP_PATH" ]]; then
    echo "archive 안에서 앱을 찾지 못했습니다: $APP_PATH" >&2
    exit 1
fi

/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $PUBLIC_KEY" "$APP_PATH/Contents/Info.plist"

# ── 2. Sparkle helper 재서명 ────────────────────────────────

echo
echo "2. Sparkle helper 재서명"
SPARKLE_FW="$APP_PATH/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE_FW" ]]; then
    codesign --force --options runtime --timestamp --sign "$CERT_HASH" \
        "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc"
    codesign --force --options runtime --timestamp --sign "$CERT_HASH" \
        "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc"
    codesign --force --options runtime --timestamp --sign "$CERT_HASH" \
        "$SPARKLE_FW/Versions/B/Autoupdate"
    codesign --force --options runtime --timestamp --sign "$CERT_HASH" \
        "$SPARKLE_FW/Versions/B/Updater.app"
    codesign --force --options runtime --timestamp --sign "$CERT_HASH" \
        "$SPARKLE_FW"
fi

codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS_PATH" \
    --sign "$CERT_HASH" \
    "$APP_PATH"

# ── 3. 앱 notarization 용 ZIP ────────────────────────────────

echo
echo "3. 앱 notarization ZIP 생성"
create_app_zip

# ── 4. 앱 notarize ──────────────────────────────────────────

echo
echo "4. 앱 notarization 제출 (--wait)"
xcrun notarytool submit "$ZIP_PATH" \
    "${NOTARY_SUBMIT_ARGS[@]}" \
    --wait

# ── 5. 앱 staple ────────────────────────────────────────────

echo
echo "5. 앱 staple 적용"
xcrun stapler staple "$APP_PATH"

# ── 6. stapled ZIP 재생성 ──────────────────────────────────

echo
echo "6. stapled ZIP 재생성"
rm -f "$ZIP_PATH"
create_app_zip

if [[ "$SKIP_DMG" == "1" ]]; then
    echo
    cat <<EOF
완료 (ZIP 만)
    archive: $ARCHIVE_PATH
    app:     $APP_PATH
    zip:     $ZIP_PATH

DMG 도 필요하면 SKIP_DMG=0 으로 재실행하거나 Scripts/make-dmg.sh 를 수동 호출하세요.
EOF
    exit 0
fi

# ── 7. DMG 생성 + 서명 ──────────────────────────────────────

echo
echo "7. 설치용 DMG 생성"
APP_PATH="$APP_PATH" \
DMG_PATH="$DMG_PATH" \
CERT_HASH="$CERT_HASH" \
"$MAKE_DMG_SCRIPT"

# ── 8. DMG notarize ────────────────────────────────────────

echo
echo "8. DMG notarization 제출 (--wait)"
xcrun notarytool submit "$DMG_PATH" \
    "${NOTARY_SUBMIT_ARGS[@]}" \
    --wait

# ── 9. DMG staple ──────────────────────────────────────────

echo
echo "9. DMG staple 적용"
xcrun stapler staple "$DMG_PATH"

# ── 10. 최종 Gatekeeper 검증 ────────────────────────────────

echo
echo "10. Gatekeeper 최종 검증"
spctl -a -t open --context context:primary-signature -v "$DMG_PATH" 2>&1 | tail -3 || true

DMG_SIZE_BYTES=$(stat -f%z "$DMG_PATH")
DMG_SIZE_MB=$(awk -v b="$DMG_SIZE_BYTES" 'BEGIN { printf "%.2f", b / 1024 / 1024 }')

echo
cat <<EOF
완료
    archive: $ARCHIVE_PATH
    app:     $APP_PATH
    zip:     $ZIP_PATH  (Sparkle appcast 다운로드용)
    dmg:     $DMG_PATH  (${DMG_SIZE_MB}MB, 설치 배포용)

다음 단계
    1. Scripts/publish-release.sh vX.Y.Z 로 GitHub Release + appcast 게시
    2. Sparkle 업데이트 경로가 활성인지 설정 화면에서 확인
EOF
