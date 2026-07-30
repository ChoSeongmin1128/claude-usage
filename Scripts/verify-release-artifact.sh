#!/usr/bin/env bash
#
# Verify one published ClaudeUsage DMG against GitHub asset metadata and the
# signed app inside it. Optionally replace one explicit ClaudeUsage.app path
# with the verified app. This script never creates backup apps.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Scripts/lib/release-driver-common.sh
source "$ROOT_DIR/Scripts/lib/release-driver-common.sh"
SPARKLE_SIGNATURE_VERIFIER="$ROOT_DIR/Scripts/verify-sparkle-signature.swift"
PROJECT_FILE="$ROOT_DIR/ClaudeUsage.xcodeproj/project.pbxproj"
RELEASE_XCCONFIG="$ROOT_DIR/Config/Release.xcconfig"

REPOSITORY="ChoSeongmin1128/claude-usage"
TAG=""
CHANNEL=""
EXPECTED_VERSION=""
EXPECTED_BUILD=""
INSTALL_TO=""
EXPORT_APPCAST_TO=""
VERIFY_PUBLIC_FEED=0
DRY_RUN=0

usage() {
    cat <<'USAGE'
사용법:
  Scripts/verify-release-artifact.sh \
    --tag vX.Y.Z[-staging] \
    --channel prod|staging \
    --expected-version X.Y.Z \
    --expected-build N \
    [--install-to /absolute/path/ClaudeUsage.app] \
    [--export-verified-appcast-to /absolute/path/appcast.xml] \
    [--verify-public-feed] \
    [--repo OWNER/REPO] \
    [--dry-run]

--install-to 를 생략하면 원격 산출물만 검증하고 앱을 남기지 않습니다.
USAGE
}

die() {
    echo "오류: $*" >&2
    exit 1
}

read_xcconfig_value() {
    local file="$1"
    local key="$2"

    [[ -f "$file" ]] || return 1
    awk -v target="$key" '
        $0 ~ "^[[:space:]]*" target "[[:space:]]*=" {
            value = $0
            sub("^[[:space:]]*" target "[[:space:]]*=[[:space:]]*", "", value)
            sub(/[[:space:]]+$/, "", value)
            print value
            exit
        }
    ' "$file"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)
            [[ $# -ge 2 ]] || die "--tag 값이 필요합니다."
            TAG="$2"
            shift 2
            ;;
        --channel)
            [[ $# -ge 2 ]] || die "--channel 값이 필요합니다."
            CHANNEL="$2"
            shift 2
            ;;
        --expected-version)
            [[ $# -ge 2 ]] || die "--expected-version 값이 필요합니다."
            EXPECTED_VERSION="$2"
            shift 2
            ;;
        --expected-build)
            [[ $# -ge 2 ]] || die "--expected-build 값이 필요합니다."
            EXPECTED_BUILD="$2"
            shift 2
            ;;
        --install-to)
            [[ $# -ge 2 ]] || die "--install-to 값이 필요합니다."
            INSTALL_TO="$2"
            shift 2
            ;;
        --export-verified-appcast-to)
            [[ $# -ge 2 ]] || die "--export-verified-appcast-to 값이 필요합니다."
            EXPORT_APPCAST_TO="$2"
            shift 2
            ;;
        --verify-public-feed)
            VERIFY_PUBLIC_FEED=1
            shift
            ;;
        --repo)
            [[ $# -ge 2 ]] || die "--repo 값이 필요합니다."
            REPOSITORY="$2"
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

[[ -n "$TAG" ]] || die "--tag 를 지정해 주세요."
[[ "$CHANNEL" == "prod" || "$CHANNEL" == "staging" ]] || die "--channel 은 prod 또는 staging이어야 합니다."
case "$CHANNEL" in
    staging)
        APP_BUNDLE_NAME="ClaudeUsage-stg.app"
        EXPECTED_APP_NAME="ClaudeUsage-stg"
        EXPECTED_BUNDLE_IDENTIFIER="com.seongmin.ClaudeUsage.staging"
        ;;
    prod)
        APP_BUNDLE_NAME="ClaudeUsage.app"
        EXPECTED_APP_NAME="ClaudeUsage"
        EXPECTED_BUNDLE_IDENTIFIER="com.seongmin.ClaudeUsage"
        ;;
esac
validate_numeric_release_version "$EXPECTED_VERSION" \
    || die "--expected-version 은 build number를 모호하지 않게 계산할 수 있는 X.Y.Z 형식이어야 합니다."
[[ "$EXPECTED_BUILD" =~ ^[1-9][0-9]*$ ]] || die "--expected-build 는 양의 정수여야 합니다."

EXPECTED_TAG="$(release_tag_for "$CHANNEL" "$EXPECTED_VERSION")"
[[ "$TAG" == "$EXPECTED_TAG" ]] \
    || die "tag/channel/version 조합이 일치하지 않습니다: 기대=$EXPECTED_TAG, 입력=$TAG"
EXPECTED_FEED_URL="$(release_feed_url_for "$CHANNEL")"
IDENTITY_METADATA_POLICY="$(
    release_artifact_identity_metadata_policy "$CHANNEL" "$EXPECTED_VERSION"
)" || die "release identity metadata 정책을 확정하지 못했습니다."
TRUSTED_TEAM_IDENTIFIER="$(
    read_unique_xcode_build_setting "$PROJECT_FILE" DEVELOPMENT_TEAM
)" || die "project의 DEVELOPMENT_TEAM 신뢰 기준을 하나로 확정하지 못했습니다."
TRUSTED_SPARKLE_PUBLIC_KEY="$(
    read_xcconfig_value "$RELEASE_XCCONFIG" SUPublicEDKey
)" || die "tracked Release.xcconfig의 Sparkle 공개키를 읽지 못했습니다."
[[ "$TRUSTED_TEAM_IDENTIFIER" =~ ^[A-Z0-9]{10}$ ]] \
    || die "project의 DEVELOPMENT_TEAM 신뢰 기준이 유효하지 않습니다."
[[ -n "$TRUSTED_SPARKLE_PUBLIC_KEY" ]] \
    || die "tracked Release.xcconfig의 Sparkle 공개키가 비어 있습니다."

if [[ -n "$INSTALL_TO" ]]; then
    [[ "$INSTALL_TO" == /*/"$APP_BUNDLE_NAME" ]] \
        || die "--install-to 는 $APP_BUNDLE_NAME으로 끝나는 절대 경로여야 합니다."
fi
if [[ -n "$EXPORT_APPCAST_TO" ]]; then
    [[ "$EXPORT_APPCAST_TO" == /* && "$(basename "$EXPORT_APPCAST_TO")" == "appcast.xml" ]] \
        || die "--export-verified-appcast-to 는 appcast.xml로 끝나는 절대 경로여야 합니다."
    [[ ! -e "$EXPORT_APPCAST_TO" && ! -L "$EXPORT_APPCAST_TO" ]] \
        || die "검증된 appcast export 대상이 이미 존재합니다: $EXPORT_APPCAST_TO"
fi

echo "원격 릴리스 산출물 검증"
echo "  repository: $REPOSITORY"
echo "  tag:        $TAG"
echo "  channel:    $CHANNEL"
echo "  version:    $EXPECTED_VERSION ($EXPECTED_BUILD)"
echo "  feed:       $EXPECTED_FEED_URL"
if [[ -n "$INSTALL_TO" ]]; then
    echo "  install:    $INSTALL_TO (기존 앱 백업 없음)"
fi

if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN: 네트워크 조회, 다운로드, mount, 검증, 앱 교체를 실행하지 않았습니다."
    exit 0
fi

for binary in gh jq curl hdiutil xcrun spctl codesign plutil shasum stat ditto cp chmod ln; do
    command -v "$binary" >/dev/null 2>&1 || die "필수 명령을 찾지 못했습니다: $binary"
done
[[ -x /usr/libexec/PlistBuddy ]] || die "PlistBuddy를 찾지 못했습니다."
[[ -f "$SPARKLE_SIGNATURE_VERIFIER" ]] \
    || die "Sparkle signature verifier를 찾지 못했습니다."

RELEASE_JSON="$(
    gh release view "$TAG" \
        --repo "$REPOSITORY" \
        --json tagName,isDraft,isPrerelease,assets
)"
RELEASE_METADATA="$(
    printf '%s\n' "$RELEASE_JSON" \
        | jq -r '[.tagName, (.isDraft|tostring), (.isPrerelease|tostring)] | @tsv'
)"
IFS=$'\t' read -r REMOTE_TAG REMOTE_DRAFT REMOTE_PRERELEASE <<< "$RELEASE_METADATA"
[[ "$REMOTE_TAG" == "$TAG" ]] || die "GitHub Release tag가 요청과 다릅니다: ${REMOTE_TAG:-<없음>}"
[[ "$REMOTE_DRAFT" == "false" ]] || die "draft Release는 검증 기준으로 사용할 수 없습니다: $TAG"
case "$CHANNEL" in
    staging)
        [[ "$REMOTE_PRERELEASE" == "true" ]] || die "staging Release가 prerelease가 아닙니다: $TAG"
        ;;
    prod)
        [[ "$REMOTE_PRERELEASE" == "false" ]] || die "prod Release가 prerelease입니다: $TAG"
        ;;
esac
RELEASE_ASSET_NAMES="$(
    printf '%s\n' "$RELEASE_JSON" \
        | jq -r '.assets[].name' \
        | LC_ALL=C sort
)"
[[ "$RELEASE_ASSET_NAMES" == $'ClaudeUsage.dmg\nClaudeUsage.zip\nappcast.xml' ]] \
    || die "Release asset 집합이 정확한 세 파일과 다릅니다: $TAG"

read_asset_metadata() {
    local asset_name="$1"
    local metadata

    metadata="$(
        printf '%s\n' "$RELEASE_JSON" \
            | jq -r --arg name "$asset_name" \
                '[.assets[] | select(.name == $name)] | if length == 1 then .[0] | [.size, .digest] | @tsv else empty end'
    )"
    [[ -n "$metadata" ]] || die "$asset_name asset이 정확히 하나가 아닙니다: $TAG"
    printf '%s\n' "$metadata"
}

verify_asset_file() {
    local asset_name="$1"
    local asset_path="$2"
    local expected_size="$3"
    local expected_digest="$4"
    local actual_size actual_sha256 normalized_expected_digest

    [[ -f "$asset_path" && ! -L "$asset_path" ]] \
        || die "다운로드한 $asset_name 이 일반 파일이 아닙니다."
    [[ "$expected_size" =~ ^[1-9][0-9]*$ ]] \
        || die "$asset_name GitHub size metadata가 유효하지 않습니다."
    [[ "$expected_digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]] \
        || die "$asset_name GitHub SHA-256 metadata가 없거나 유효하지 않습니다."

    actual_size="$(stat -f%z "$asset_path")"
    [[ "$actual_size" == "$expected_size" ]] \
        || die "$asset_name 크기가 GitHub metadata와 다릅니다: 기대=$expected_size, 실제=$actual_size"
    actual_sha256="$(shasum -a 256 "$asset_path" | awk '{print $1}')"
    normalized_expected_digest="$(printf '%s' "$expected_digest" | tr '[:upper:]' '[:lower:]')"
    [[ "sha256:$actual_sha256" == "$normalized_expected_digest" ]] \
        || die "$asset_name SHA-256이 GitHub metadata와 다릅니다."
    printf '%s\n' "$actual_sha256"
}

verify_app_bundle() {
    local app_path="$1"
    local source_label="$2"
    local app_info bundle_id actual_version actual_build actual_feed_url
    local actual_app_name actual_release_channel
    local actual_public_key signing_info signing_identifier signing_team
    local entitlements_path
    local network_client

    [[ -d "$app_path" && ! -L "$app_path" ]] || die "$source_label $APP_BUNDLE_NAME을 찾지 못했습니다."
    app_info="$app_path/Contents/Info.plist"
    [[ -f "$app_info" ]] || die "$source_label 앱의 Info.plist를 찾지 못했습니다."

    codesign --verify --deep --strict --verbose=2 "$app_path"
    signing_info="$(codesign -dv --verbose=4 "$app_path" 2>&1)"
    signing_identifier="$(
        printf '%s\n' "$signing_info" \
            | awk -F= '$1 == "Identifier" { print $2; exit }'
    )"
    signing_team="$(
        printf '%s\n' "$signing_info" \
            | awk -F= '$1 == "TeamIdentifier" { print $2; exit }'
    )"
    xcrun stapler validate "$app_path"
    spctl --assess --type execute --verbose=4 "$app_path"

    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_info")"
    actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_info")"
    actual_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_info")"
    actual_feed_url="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$app_info")"
    actual_public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app_info")"
    if ! actual_app_name="$(
        /usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$app_info" 2>/dev/null
    )"; then
        [[ "$IDENTITY_METADATA_POLICY" == "legacy-prod" ]] \
            || die "$source_label 앱에 CFBundleDisplayName이 없습니다."
        actual_app_name="$(
            /usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$app_info"
        )"
    fi
    if ! actual_release_channel="$(
        /usr/libexec/PlistBuddy -c 'Print :ClaudeUsageReleaseChannel' "$app_info" 2>/dev/null
    )"; then
        [[ "$IDENTITY_METADATA_POLICY" == "legacy-prod" ]] \
            || die "$source_label 앱에 ClaudeUsageReleaseChannel이 없습니다."
        actual_release_channel="prod"
    fi

    [[ "$bundle_id" == "$EXPECTED_BUNDLE_IDENTIFIER" ]] \
        || die "$source_label bundle identifier가 다릅니다: $bundle_id"
    [[ "$signing_identifier" == "$EXPECTED_BUNDLE_IDENTIFIER" ]] \
        || die "$source_label code signature identifier가 다릅니다: $signing_identifier"
    [[ "$actual_app_name" == "$EXPECTED_APP_NAME" ]] \
        || die "$source_label 앱 표시 이름이 다릅니다: $actual_app_name"
    [[ "$actual_release_channel" == "$CHANNEL" ]] \
        || die "$source_label release channel이 다릅니다: $actual_release_channel"
    [[ "$signing_team" == "$TRUSTED_TEAM_IDENTIFIER" ]] \
        || die "$source_label code signature team이 신뢰 기준과 다릅니다: $signing_team"

    entitlements_path="$VERIFY_ROOT/app-entitlements.plist"
    codesign --display --entitlements - --xml "$app_path" \
        > "$entitlements_path" 2>/dev/null \
        || die "$source_label 앱 서명에서 entitlements를 추출하지 못했습니다."
    plutil -lint "$entitlements_path" >/dev/null \
        || die "$source_label 앱의 signed entitlements가 유효한 plist가 아닙니다."
    network_client="$(
        /usr/libexec/PlistBuddy \
            -c 'Print :com.apple.security.network.client' \
            "$entitlements_path"
    )"
    [[ "$network_client" == "true" ]] \
        || die "$source_label 앱의 network client entitlement가 누락됐습니다."
    # Developer ID 배포본에는 provisioning profile이 없어 restricted entitlement가
    # 런타임에서 거부된다. 원격 artifact에도 다시 들어오지 않았는지 확인한다.
    if /usr/libexec/PlistBuddy \
        -c 'Print :keychain-access-groups' \
        "$entitlements_path" >/dev/null 2>&1; then
        die "$source_label 앱에 provisioning profile 없이 승인될 수 없는 Keychain access group entitlement가 있습니다."
    fi
    [[ "$actual_version" == "$EXPECTED_VERSION" ]] \
        || die "$source_label 앱 version이 다릅니다: 기대=$EXPECTED_VERSION, 실제=$actual_version"
    [[ "$actual_build" == "$EXPECTED_BUILD" ]] \
        || die "$source_label 앱 build가 다릅니다: 기대=$EXPECTED_BUILD, 실제=$actual_build"
    [[ "$actual_feed_url" == "$EXPECTED_FEED_URL" ]] \
        || die "$source_label 앱 feed URL이 다릅니다: 기대=$EXPECTED_FEED_URL, 실제=$actual_feed_url"
    [[ "$actual_public_key" == "$TRUSTED_SPARKLE_PUBLIC_KEY" ]] \
        || die "$source_label 앱의 SUPublicEDKey가 신뢰 기준과 다릅니다."
}

DMG_ASSET_METADATA="$(read_asset_metadata ClaudeUsage.dmg)"
ZIP_ASSET_METADATA="$(read_asset_metadata ClaudeUsage.zip)"
APPCAST_ASSET_METADATA="$(read_asset_metadata appcast.xml)"
IFS=$'\t' read -r EXPECTED_DMG_SIZE EXPECTED_DMG_DIGEST <<< "$DMG_ASSET_METADATA"
IFS=$'\t' read -r EXPECTED_ZIP_SIZE EXPECTED_ZIP_DIGEST <<< "$ZIP_ASSET_METADATA"
IFS=$'\t' read -r EXPECTED_APPCAST_SIZE EXPECTED_APPCAST_DIGEST <<< "$APPCAST_ASSET_METADATA"

VERIFY_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/claudeusage-release-verify.XXXXXX")"
# macOS에서 /var는 /private/var symlink이며 mount(8)는 canonical mountpoint를
# 출력한다. 생성 직후 물리 경로로 고정해 attach 확인과 cleanup이 같은 identity를
# 사용하게 한다.
VERIFY_ROOT="$(cd "$VERIFY_ROOT" && pwd -P)"
DOWNLOAD_DIR="$VERIFY_ROOT/download"
MOUNT_DIR="$VERIFY_ROOT/mount"
ZIP_EXTRACT_DIR="$VERIFY_ROOT/zip"
DMG_PATH="$DOWNLOAD_DIR/ClaudeUsage.dmg"
ZIP_PATH="$DOWNLOAD_DIR/ClaudeUsage.zip"
APPCAST_PATH="$DOWNLOAD_DIR/appcast.xml"
PUBLIC_APPCAST_PATH="$DOWNLOAD_DIR/public-appcast.xml"
INSTALL_STAGE_DIR=""
INSTALL_PREVIOUS_APP=""
EXPORT_STAGE_PATH=""
EXPORT_CREATED=0

is_verify_mount_active() {
    /sbin/mount | awk -v target="$MOUNT_DIR" '
        index($0, " on " target " (") > 0 {
            found = 1
        }
        END {
            exit(found ? 0 : 1)
        }
    '
}

cleanup() {
    local exit_code=$?
    local cleanup_failed=0

    if is_verify_mount_active; then
        if ! hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1; then
            if ! hdiutil detach -force "$MOUNT_DIR" >/dev/null 2>&1; then
                echo "오류: 검증용 DMG mount를 해제하지 못했습니다: $MOUNT_DIR" >&2
                cleanup_failed=1
            fi
        fi
    fi
    if is_verify_mount_active; then
        echo "오류: 검증용 DMG mount가 남았습니다: $MOUNT_DIR" >&2
        cleanup_failed=1
    fi
    if [[ -n "$INSTALL_PREVIOUS_APP" && -d "$INSTALL_PREVIOUS_APP" ]]; then
        if [[ -e "$INSTALL_TO" ]]; then
            if ! rm -rf "$INSTALL_PREVIOUS_APP" || [[ -e "$INSTALL_PREVIOUS_APP" ]]; then
                echo "오류: 교체 전 앱 rollback staging을 정리하지 못했습니다: $INSTALL_PREVIOUS_APP" >&2
                cleanup_failed=1
            fi
        elif ! mv "$INSTALL_PREVIOUS_APP" "$INSTALL_TO"; then
            echo "오류: 교체 실패 후 기존 앱을 복구하지 못했습니다: $INSTALL_TO" >&2
            cleanup_failed=1
        fi
    fi
    if [[ -n "$INSTALL_STAGE_DIR" && -d "$INSTALL_STAGE_DIR" ]]; then
        if ! rm -rf "$INSTALL_STAGE_DIR" || [[ -e "$INSTALL_STAGE_DIR" ]]; then
            echo "오류: 설치 staging 디렉터리를 정리하지 못했습니다: $INSTALL_STAGE_DIR" >&2
            cleanup_failed=1
        fi
    fi
    if [[ -n "$EXPORT_STAGE_PATH" && -f "$EXPORT_STAGE_PATH" ]]; then
        if ! rm -f "$EXPORT_STAGE_PATH" || [[ -e "$EXPORT_STAGE_PATH" ]]; then
            echo "오류: 검증된 appcast export staging을 정리하지 못했습니다: $EXPORT_STAGE_PATH" >&2
            cleanup_failed=1
        fi
    fi
    if [[ "$exit_code" != "0" && "$EXPORT_CREATED" == "1" && -f "$EXPORT_APPCAST_TO" ]]; then
        if ! rm -f "$EXPORT_APPCAST_TO" || [[ -e "$EXPORT_APPCAST_TO" ]]; then
            echo "오류: 실패한 appcast export 결과를 정리하지 못했습니다: $EXPORT_APPCAST_TO" >&2
            cleanup_failed=1
        fi
    fi
    if ! rm -rf "$VERIFY_ROOT" || [[ -e "$VERIFY_ROOT" ]]; then
        echo "오류: 검증 임시 디렉터리를 정리하지 못했습니다: $VERIFY_ROOT" >&2
        cleanup_failed=1
    fi
    exit "$(release_cleanup_exit_code "$exit_code" "$cleanup_failed" 0)"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

mkdir -p "$DOWNLOAD_DIR" "$MOUNT_DIR" "$ZIP_EXTRACT_DIR"
for asset_name in ClaudeUsage.dmg ClaudeUsage.zip appcast.xml; do
    gh release download "$TAG" \
        --repo "$REPOSITORY" \
        --pattern "$asset_name" \
        --dir "$DOWNLOAD_DIR"
done

DMG_SHA256="$(
    verify_asset_file ClaudeUsage.dmg "$DMG_PATH" "$EXPECTED_DMG_SIZE" "$EXPECTED_DMG_DIGEST"
)"
ZIP_SHA256="$(
    verify_asset_file ClaudeUsage.zip "$ZIP_PATH" "$EXPECTED_ZIP_SIZE" "$EXPECTED_ZIP_DIGEST"
)"
APPCAST_SHA256="$(
    verify_asset_file appcast.xml "$APPCAST_PATH" "$EXPECTED_APPCAST_SIZE" "$EXPECTED_APPCAST_DIGEST"
)"

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
EXPECTED_ENCLOSURE="https://github.com/$REPOSITORY/releases/download/$TAG/ClaudeUsage.zip"
[[ "$APPCAST_VERSION" == "$EXPECTED_VERSION" ]] \
    || die "Release appcast version이 다릅니다: 기대=$EXPECTED_VERSION, 실제=$APPCAST_VERSION"
[[ "$APPCAST_BUILD" == "$EXPECTED_BUILD" ]] \
    || die "Release appcast build가 다릅니다: 기대=$EXPECTED_BUILD, 실제=$APPCAST_BUILD"
[[ "$APPCAST_ENCLOSURE" == "$EXPECTED_ENCLOSURE" ]] \
    || die "Release appcast enclosure가 다릅니다: 기대=$EXPECTED_ENCLOSURE, 실제=$APPCAST_ENCLOSURE"
[[ "$APPCAST_LENGTH" == "$EXPECTED_ZIP_SIZE" ]] \
    || die "Release appcast length가 ZIP asset size와 다릅니다: 기대=$EXPECTED_ZIP_SIZE, 실제=$APPCAST_LENGTH"
[[ -n "$APPCAST_SIGNATURE" ]] \
    || die "Release appcast에 sparkle:edSignature가 없습니다."

if [[ "$VERIFY_PUBLIC_FEED" == "1" ]]; then
    curl -fsSL "$EXPECTED_FEED_URL" -o "$PUBLIC_APPCAST_PATH"
    PUBLIC_APPCAST_SHA256="$(shasum -a 256 "$PUBLIC_APPCAST_PATH" | awk '{print $1}')"
    [[ "$PUBLIC_APPCAST_SHA256" == "$APPCAST_SHA256" ]] \
        || die "public appcast가 Release appcast asset과 byte-for-byte 일치하지 않습니다."
fi

ditto -x -k "$ZIP_PATH" "$ZIP_EXTRACT_DIR"
ZIP_APP_PATH="$ZIP_EXTRACT_DIR/$APP_BUNDLE_NAME"
verify_app_bundle "$ZIP_APP_PATH" "ZIP"
xcrun swift \
    -module-cache-path "$VERIFY_ROOT/swift-module-cache" \
    "$SPARKLE_SIGNATURE_VERIFIER" \
    "$ZIP_PATH" \
    "$TRUSTED_SPARKLE_PUBLIC_KEY" \
    "$APPCAST_SIGNATURE"

xcrun stapler validate "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"
DMG_SIGNING_INFO="$(codesign -dv --verbose=4 "$DMG_PATH" 2>&1)"
DMG_SIGNING_TEAM="$(
    printf '%s\n' "$DMG_SIGNING_INFO" \
        | awk -F= '$1 == "TeamIdentifier" { print $2; exit }'
)"
[[ "$DMG_SIGNING_TEAM" == "$TRUSTED_TEAM_IDENTIFIER" ]] \
    || die "DMG code signature team이 신뢰 기준과 다릅니다: $DMG_SIGNING_TEAM"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
hdiutil attach \
    -readonly \
    -nobrowse \
    -noautoopen \
    -mountpoint "$MOUNT_DIR" \
    "$DMG_PATH" >/dev/null
is_verify_mount_active || die "DMG attach 후 mount를 확인하지 못했습니다: $MOUNT_DIR"

APP_PATH="$MOUNT_DIR/$APP_BUNDLE_NAME"
verify_app_bundle "$APP_PATH" "DMG"

if [[ -n "$INSTALL_TO" ]]; then
    INSTALL_PARENT="$(dirname "$INSTALL_TO")"
    [[ -d "$INSTALL_PARENT" && ! -L "$INSTALL_PARENT" ]] \
        || die "설치 대상 상위 디렉터리가 유효하지 않습니다: $INSTALL_PARENT"
    [[ ! -L "$INSTALL_TO" ]] || die "설치 대상이 symlink여서 교체를 거부합니다: $INSTALL_TO"
    if [[ -e "$INSTALL_TO" && ! -d "$INSTALL_TO" ]]; then
        die "설치 대상이 앱 디렉터리가 아닙니다: $INSTALL_TO"
    fi

    INSTALL_STAGE_DIR="$(mktemp -d "$INSTALL_PARENT/.ClaudeUsage-release-install.XXXXXX")"
    STAGED_APP="$INSTALL_STAGE_DIR/$APP_BUNDLE_NAME"
    ditto --rsrc --extattr --acl "$APP_PATH" "$STAGED_APP"
    verify_app_bundle "$STAGED_APP" "설치 staging"

    if [[ -d "$INSTALL_TO" ]]; then
        INSTALL_PREVIOUS_APP="$INSTALL_STAGE_DIR/previous-$APP_BUNDLE_NAME"
        mv "$INSTALL_TO" "$INSTALL_PREVIOUS_APP"
    fi
    mv "$STAGED_APP" "$INSTALL_TO"
    if [[ -n "$INSTALL_PREVIOUS_APP" && -d "$INSTALL_PREVIOUS_APP" ]]; then
        rm -rf "$INSTALL_PREVIOUS_APP"
        [[ ! -e "$INSTALL_PREVIOUS_APP" ]] \
            || die "교체 전 앱 rollback staging을 정리하지 못했습니다."
    fi
    INSTALL_PREVIOUS_APP=""
    rmdir "$INSTALL_STAGE_DIR"
    INSTALL_STAGE_DIR=""
    echo "  채널 앱 교체 완료: $INSTALL_TO"
fi

if [[ -n "$EXPORT_APPCAST_TO" ]]; then
    EXPORT_PARENT="$(dirname "$EXPORT_APPCAST_TO")"
    [[ -d "$EXPORT_PARENT" && ! -L "$EXPORT_PARENT" ]] \
        || die "검증된 appcast export 상위 디렉터리가 유효하지 않습니다: $EXPORT_PARENT"
    EXPORT_STAGE_PATH="$(mktemp "$EXPORT_PARENT/.ClaudeUsage-verified-appcast.XXXXXX")"
    cp "$APPCAST_PATH" "$EXPORT_STAGE_PATH"
    chmod 0644 "$EXPORT_STAGE_PATH"
    EXPORTED_APPCAST_SHA256="$(
        shasum -a 256 "$EXPORT_STAGE_PATH" | awk '{print $1}'
    )"
    [[ "$EXPORTED_APPCAST_SHA256" == "$APPCAST_SHA256" ]] \
        || die "검증된 appcast export staging의 SHA-256이 원본과 다릅니다."
    ln "$EXPORT_STAGE_PATH" "$EXPORT_APPCAST_TO" \
        || die "검증된 appcast export 대상을 원자적으로 생성하지 못했습니다."
    EXPORT_CREATED=1
    rm -f "$EXPORT_STAGE_PATH"
    [[ ! -e "$EXPORT_STAGE_PATH" ]] \
        || die "검증된 appcast export staging을 정리하지 못했습니다."
    EXPORT_STAGE_PATH=""
    echo "  verified appcast export: $EXPORT_APPCAST_TO"
fi

echo "검증 완료"
echo "  DMG SHA-256:     $DMG_SHA256"
echo "  ZIP SHA-256:     $ZIP_SHA256"
echo "  appcast SHA-256: $APPCAST_SHA256"
echo "  app:             $EXPECTED_VERSION ($EXPECTED_BUILD)"
echo "  feed:            $EXPECTED_FEED_URL"
