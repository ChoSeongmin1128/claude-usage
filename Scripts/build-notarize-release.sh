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
#   Config/Sparkle.release.local.xcconfig 에 SUFeedURL, SUPublicEDKey,
#   NOTARY_PROFILE 이 유효하게 채워져 있어야 합니다.
#   Scripts/setup-sparkle-keys.sh 로 1회성 세팅 가능.

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
SKIP_DMG="${SKIP_DMG:-0}"

extract_xcconfig_value() {
    local file="$1"
    local key="$2"
    [[ -f "$file" ]] || return 0
    awk -F '=' -v target="$key" '
        $1 ~ "^[[:space:]]*"target"[[:space:]]*$" {
            value=$2
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            print value
            exit
        }
    ' "$file"
}

is_placeholder_value() {
    local value="${1,,}"
    [[ -z "$value" ]] && return 0
    [[ "$value" == *"change_me"* ]] && return 0
    [[ "$value" == *"placeholder"* ]] && return 0
    [[ "$value" == *"replace_with"* ]] && return 0
    [[ "$value" == *"replace_me"* ]] && return 0
    [[ "$value" == *"example.com"* ]] && return 0
    [[ "$value" == *'$('* ]] && return 0
    return 1
}

NOTARY_PROFILE="${NOTARY_PROFILE:-$(extract_xcconfig_value "$LOCAL_XC_CONFIG_PATH" "NOTARY_PROFILE")}"
CERT_HASH="${CERT_HASH:-9A12730390B85461D1A98C907C61A7AA265EE214}"

echo "ClaudeUsage release 산출물 빌드 + notarization + DMG 를 시작합니다"

# ── 사전 검증 ────────────────────────────────────────────────

if [[ ! -f "$PROJECT_PATH/project.pbxproj" ]]; then
    echo "Xcode 프로젝트를 찾지 못했습니다: $PROJECT_PATH" >&2
    exit 1
fi

if [[ ! -f "$XC_CONFIG_PATH" ]]; then
    echo "release xcconfig를 찾지 못했습니다: $XC_CONFIG_PATH" >&2
    exit 1
fi

FEED_URL="${SU_FEED_URL:-$(extract_xcconfig_value "$LOCAL_XC_CONFIG_PATH" "SUFeedURL")}"
PUBLIC_KEY="${SU_PUBLIC_ED_KEY:-$(extract_xcconfig_value "$LOCAL_XC_CONFIG_PATH" "SUPublicEDKey")}"

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

if [[ -z "$NOTARY_PROFILE" ]] || is_placeholder_value "$NOTARY_PROFILE"; then
    echo "유효한 NOTARY_PROFILE 을 찾지 못했습니다." >&2
    echo "xcrun notarytool store-credentials <profile> 를 먼저 실행해 주세요." >&2
    exit 1
fi

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

# ── 1. Xcode archive ────────────────────────────────────────

echo
echo "1. Xcode archive 생성"
xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -xcconfig "$XC_CONFIG_PATH" \
    -archivePath "$ARCHIVE_PATH" \
    archive

if [[ ! -d "$APP_PATH" ]]; then
    echo "archive 안에서 앱을 찾지 못했습니다: $APP_PATH" >&2
    exit 1
fi

# ── 2. 앱 notarization 용 ZIP ────────────────────────────────

echo
echo "2. 앱 notarization ZIP 생성"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

# ── 3. 앱 notarize ──────────────────────────────────────────

echo
echo "3. 앱 notarization 제출 (--wait)"
xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

# ── 4. 앱 staple ────────────────────────────────────────────

echo
echo "4. 앱 staple 적용"
xcrun stapler staple "$APP_PATH"

# ── 5. stapled ZIP 재생성 ──────────────────────────────────

echo
echo "5. stapled ZIP 재생성"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

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

# ── 6. DMG 생성 + 서명 ──────────────────────────────────────

echo
echo "6. 설치용 DMG 생성"
APP_PATH="$APP_PATH" \
DMG_PATH="$DMG_PATH" \
CERT_HASH="$CERT_HASH" \
"$MAKE_DMG_SCRIPT"

# ── 7. DMG notarize ────────────────────────────────────────

echo
echo "7. DMG notarization 제출 (--wait)"
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

# ── 8. DMG staple ──────────────────────────────────────────

echo
echo "8. DMG staple 적용"
xcrun stapler staple "$DMG_PATH"

# ── 9. 최종 Gatekeeper 검증 ────────────────────────────────

echo
echo "9. Gatekeeper 최종 검증"
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
