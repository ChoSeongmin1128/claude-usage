#!/usr/bin/env bash
#
# ClaudeUsage release 파이프라인.
#
# 단계:
#   1. Xcode archive
#   2. Developer ID 서명
#   3. ZIP 생성
#   4. notarized 배포면 앱 notarization + staple + ZIP 재생성
#   5. Scripts/make-dmg.sh 호출해 설치용 DMG 생성/서명
#   6. notarized 배포면 DMG notarization + staple + Gatekeeper 검증
#      internal 배포면 codesign 검증 후 공증 없음 경고 출력
#
# 전제:
#   Config/Sparkle.release.local.xcconfig 에 SUFeedURL, SUPublicEDKey 가
#   유효하게 채워져 있어야 합니다.
#   RELEASE_DISTRIBUTION=notarized|internal 로 배포 기준을 고릅니다.
#   기본값은 notarized 입니다. internal 은 사내 배포용 signed-only 산출물이며
#   Apple notarization 제출과 staple 을 수행하지 않습니다.
#   공증 자격 증명은 notarized 배포에서만 아래 우선순위로 찾습니다.
#     1. NOTARY_KEY_PATH / NOTARY_KEY_ID / NOTARY_ISSUER
#     2. APP_STORE_CONNECT_API_KEY_P8 / APP_STORE_CONNECT_KEY_ID / APP_STORE_CONNECT_ISSUER_ID
#     3. NOTARY_APPLE_ID / NOTARY_PASSWORD / NOTARY_TEAM_ID
#     4. Config/Sparkle.release.local.xcconfig 의 NOTARY_PROFILE
#   Scripts/setup-sparkle-keys.sh 로 1회성 세팅 가능.
#   RELEASE_CHANNEL=prod|staging 을 주면 해당 채널 feed URL 을 빌드에
#   강제로 주입합니다.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Scripts/lib/release-driver-common.sh
source "$ROOT_DIR/Scripts/lib/release-driver-common.sh"
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
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-}"
MAKE_DMG_SCRIPT="$ROOT_DIR/Scripts/make-dmg.sh"
ENTITLEMENTS_PATH="${ENTITLEMENTS_PATH:-$ROOT_DIR/ClaudeUsage/ClaudeUsage.entitlements}"
SKIP_DMG="${SKIP_DMG:-0}"
RELEASE_DISTRIBUTION="${RELEASE_DISTRIBUTION:-notarized}"
EFFECTIVE_XC_CONFIG_PATH="$XC_CONFIG_PATH"
TEMP_XC_CONFIG_PATH=""
TEMP_XC_CONFIG_DIR=""
TEMP_NOTARY_KEY_PATH=""
RESOLVED_ENTITLEMENTS_PATH=""

cleanup() {
    local exit_code=$?
    local cleanup_failed=0

    if [[ -n "$TEMP_XC_CONFIG_PATH" && -f "$TEMP_XC_CONFIG_PATH" ]]; then
        if ! rm -f "$TEMP_XC_CONFIG_PATH" || [[ -e "$TEMP_XC_CONFIG_PATH" ]]; then
            echo "임시 xcconfig를 정리하지 못했습니다: $TEMP_XC_CONFIG_PATH" >&2
            cleanup_failed=1
        fi
    fi
    if [[ -n "$TEMP_XC_CONFIG_DIR" && -d "$TEMP_XC_CONFIG_DIR" ]]; then
        if ! rm -rf "$TEMP_XC_CONFIG_DIR" || [[ -e "$TEMP_XC_CONFIG_DIR" ]]; then
            echo "임시 xcconfig 디렉터리를 정리하지 못했습니다: $TEMP_XC_CONFIG_DIR" >&2
            cleanup_failed=1
        fi
    fi
    if [[ -n "$TEMP_NOTARY_KEY_PATH" && -f "$TEMP_NOTARY_KEY_PATH" ]]; then
        if ! rm -f "$TEMP_NOTARY_KEY_PATH" || [[ -e "$TEMP_NOTARY_KEY_PATH" ]]; then
            echo "임시 공증 key 파일을 정리하지 못했습니다: $TEMP_NOTARY_KEY_PATH" >&2
            cleanup_failed=1
        fi
    fi
    if [[ -n "$RESOLVED_ENTITLEMENTS_PATH" && -f "$RESOLVED_ENTITLEMENTS_PATH" ]]; then
        if ! rm -f "$RESOLVED_ENTITLEMENTS_PATH" || [[ -e "$RESOLVED_ENTITLEMENTS_PATH" ]]; then
            echo "해석된 entitlements 파일을 정리하지 못했습니다: $RESOLVED_ENTITLEMENTS_PATH" >&2
            cleanup_failed=1
        fi
    fi
    exit "$(release_cleanup_exit_code "$exit_code" "$cleanup_failed" 0)"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

create_app_zip() {
    # AppleDouble files break Gatekeeper after ZIP-based installs.
    COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --keepParent "$APP_PATH" "$ZIP_PATH"
}

extract_and_validate_app_entitlements() {
    local app_path="$1"
    local output_path="$2"
    local bundle_id
    local network_client

    bundle_id="$(
        /usr/libexec/PlistBuddy \
            -c 'Print :CFBundleIdentifier' \
            "$app_path/Contents/Info.plist"
    )"
    [[ "$bundle_id" == "com.seongmin.ClaudeUsage" ]] || {
        echo "서명 대상 bundle identifier가 다릅니다: $bundle_id" >&2
        return 1
    }

    if ! codesign --display --entitlements - --xml "$app_path" \
        > "$output_path" 2>/dev/null; then
        echo "앱 서명에서 entitlements를 추출하지 못했습니다: $app_path" >&2
        return 1
    fi
    plutil -lint "$output_path" >/dev/null

    network_client="$(
        /usr/libexec/PlistBuddy \
            -c 'Print :com.apple.security.network.client' \
            "$output_path"
    )"

    [[ "$network_client" == "true" ]] || {
        echo "network client entitlement가 누락됐습니다." >&2
        return 1
    }
    # Developer ID 배포본에는 provisioning profile이 없으므로 restricted
    # entitlement는 서명돼도 런타임에서 거부된다. 다시 들어오면 앱이 조용히
    # 깨지므로 빌드 단계에서 막는다.
    if /usr/libexec/PlistBuddy \
        -c 'Print :keychain-access-groups' \
        "$output_path" >/dev/null 2>&1; then
        echo "provisioning profile 없이 승인될 수 없는 Keychain access group entitlement가 포함됐습니다." >&2
        return 1
    fi
}

preflight_notary_credentials() {
    echo
    echo "공증 자격 증명 사전 확인"
    local output
    if ! output="$(xcrun notarytool history \
        "${NOTARY_SUBMIT_ARGS[@]}" \
        --output-format json \
        --no-progress 2>&1 >/dev/null)"; then
        if [[ -n "${output:-}" ]]; then
            printf '%s\n' "$output" >&2
        fi
        echo "공증 자격 증명이 유효하지 않아 archive 전에 중단합니다." >&2
        local printed_recovery=0
        if [[ "$output" == *"HTTP status code: 401"* || "$output" == *"Invalid credentials"* ]]; then
            case "$NOTARY_AUTH_DESCRIPTION" in
                keychain\ profile:*)
                    local profile="${NOTARY_AUTH_DESCRIPTION#keychain profile: }"
                    local recovery_profile="$profile"
                    if security find-generic-password -s "$profile" -a "claude-session-key" >/dev/null 2>&1; then
                        echo "keychain profile \"$profile\" 이름이 ClaudeUsage 앱 세션 Keychain 항목과 충돌합니다." >&2
                        echo "현재 발견된 항목은 공증용 Apple ID/App Store Connect 자격이 아니라 앱의 claude-session-key 입니다." >&2
                        recovery_profile="ClaudeUsageNotary"
                        echo "NOTARY_PROFILE 을 \"$recovery_profile\" 같은 별도 이름으로 바꾸고 공증 자격을 새로 저장해야 합니다." >&2
                    else
                        echo "현재 keychain profile \"$profile\" 은 존재하지만 Apple 서버가 인증을 거부했습니다." >&2
                        echo "Apple ID, team ID, 또는 app-specific password 를 새 값으로 다시 저장해야 합니다." >&2
                    fi
                    echo "복구:" >&2
                    echo "  Config/Sparkle.release.local.xcconfig 의 NOTARY_PROFILE 을 \"$recovery_profile\" 로 설정" >&2
                    echo "  xcrun notarytool store-credentials \"$recovery_profile\" --apple-id YOUR@EMAIL --team-id YOUR_TEAM_ID" >&2
                    echo "  xcrun notarytool history --keychain-profile \"$recovery_profile\"" >&2
                    printed_recovery=1
                    ;;
                "Apple ID 환경 변수")
                    echo "NOTARY_APPLE_ID/NOTARY_PASSWORD/NOTARY_TEAM_ID 조합이 Apple 서버에서 거부됐습니다." >&2
                    echo "NOTARY_PASSWORD 는 Apple ID 일반 비밀번호가 아니라 appleid.apple.com 의 app-specific password 여야 합니다." >&2
                    ;;
                App\ Store\ Connect\ API\ key*)
                    echo "NOTARY_KEY_PATH/NOTARY_KEY_ID/NOTARY_ISSUER 조합이 Apple 서버에서 거부됐습니다." >&2
                    echo "또는 APP_STORE_CONNECT_API_KEY_P8/APP_STORE_CONNECT_KEY_ID/APP_STORE_CONNECT_ISSUER_ID 조합을 확인해 주세요." >&2
                    echo ".p8 key, key id, issuer id 가 같은 App Store Connect API key 에 속하는지 확인해 주세요." >&2
                    ;;
            esac
        fi
        if [[ "$printed_recovery" -eq 0 && "$NOTARY_AUTH_DESCRIPTION" == keychain\ profile:* ]]; then
            local profile="${NOTARY_AUTH_DESCRIPTION#keychain profile: }"
            echo "복구 예시: xcrun notarytool store-credentials \"$profile\" --apple-id YOUR@EMAIL --team-id YOUR_TEAM_ID" >&2
        fi
        if [[ "$NOTARY_AUTH_DESCRIPTION" == App\ Store\ Connect\ API\ key* ]]; then
            echo ".p8 key, key id, issuer id 가 같은 App Store Connect API key 에 속하는지 확인해 주세요." >&2
        fi
        echo "App Store Connect API key를 쓰려면 NOTARY_KEY_PATH/NOTARY_KEY_ID/NOTARY_ISSUER 또는 APP_STORE_CONNECT_* 환경 변수를 지정하세요." >&2
        echo "자세한 절차는 docs/RELEASE.md 의 notarytool store-credentials 섹션을 확인해 주세요." >&2
        exit 1
    fi
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
    [[ "$value" == *"\$("* ]] && return 0
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

validate_release_distribution() {
    case "${1:-}" in
        notarized|internal) ;;
        *)
            echo "지원하지 않는 RELEASE_DISTRIBUTION 입니다: ${1:-<empty>} (notarized 또는 internal만 허용)" >&2
            exit 2
            ;;
    esac
}

derive_repo_pages_base_url() {
    local name_with_owner=""
    local remote_url

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
APP_STORE_CONNECT_API_KEY_P8="${APP_STORE_CONNECT_API_KEY_P8:-}"
APP_STORE_CONNECT_KEY_ID="${APP_STORE_CONNECT_KEY_ID:-}"
APP_STORE_CONNECT_ISSUER_ID="${APP_STORE_CONNECT_ISSUER_ID:-}"
NOTARY_SUBMIT_ARGS=()
NOTARY_AUTH_DESCRIPTION=""
CERT_HASH="${CERT_HASH:-}"
RELEASE_CHANNEL="${RELEASE_CHANNEL:-}"
REQUESTED_DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"

if [[ ! -f "$PROJECT_PATH/project.pbxproj" ]]; then
    echo "Xcode 프로젝트를 찾지 못했습니다: $PROJECT_PATH" >&2
    exit 1
fi
TRUSTED_DEVELOPMENT_TEAM="$(
    read_unique_xcode_build_setting "$PROJECT_PATH/project.pbxproj" DEVELOPMENT_TEAM
)" || {
    echo "project의 DEVELOPMENT_TEAM 신뢰 기준을 하나로 확정하지 못했습니다." >&2
    exit 1
}
[[ "$TRUSTED_DEVELOPMENT_TEAM" =~ ^[A-Z0-9]{10}$ ]] || {
    echo "project의 DEVELOPMENT_TEAM 신뢰 기준이 유효하지 않습니다: $TRUSTED_DEVELOPMENT_TEAM" >&2
    exit 1
}
if [[ -n "$REQUESTED_DEVELOPMENT_TEAM" \
    && "$REQUESTED_DEVELOPMENT_TEAM" != "$TRUSTED_DEVELOPMENT_TEAM" ]]; then
    echo "DEVELOPMENT_TEAM override가 project 신뢰 기준과 다릅니다: requested=$REQUESTED_DEVELOPMENT_TEAM, trusted=$TRUSTED_DEVELOPMENT_TEAM" >&2
    exit 1
fi
DEVELOPMENT_TEAM="$TRUSTED_DEVELOPMENT_TEAM"

# CERT_HASH 가 비어 있으면 keychain 에서 Developer ID Application 인증서를 자동
# 탐색한다. DEVELOPMENT_TEAM 이 설정돼 있으면 해당 팀(예: "5YG4V2PLZV")으로
# 필터링한다. 후보가 여러 개여서 모호하면 silent 자동 선택을 거부하고 명시적
# 지정을 요구한다.
list_developer_id_certificates() {
    local team_filter="${1:-}"
    security find-identity -v -p codesigning 2>/dev/null \
        | awk -v team="$team_filter" '
            /Developer ID Application/ {
                if (team == "" || $0 ~ "\\(" team "\\)") print $2
            }
        '
}

# 이미 배포된 앱의 leaf 서명 인증서 SHA-1. 후보가 여러 개일 때 어느 인증서가
# "현재 쓰이고 있는 것"인지 판단하는 기준이 된다.
resolve_app_signing_certificate_sha1() {
    local app_path="$1"
    [[ -d "$app_path" ]] || return 1

    local work
    work="$(mktemp -d)" || return 1
    local sha=""
    if codesign -d --extract-certificates="$work/cert" "$app_path" >/dev/null 2>&1 \
        && [[ -f "$work/cert0" ]]; then
        sha="$(openssl x509 -inform DER -in "$work/cert0" -noout -fingerprint -sha1 2>/dev/null \
            | sed 's/.*=//; s/://g' \
            | tr '[:lower:]' '[:upper:]')"
    fi
    rm -rf "$work"

    [[ "$sha" =~ ^[0-9A-F]{40}$ ]] || return 1
    printf '%s\n' "$sha"
}

if [[ -z "$CERT_HASH" ]]; then
    CERT_CANDIDATES=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && CERT_CANDIDATES+=("$line")
    done < <(list_developer_id_certificates "$TRUSTED_DEVELOPMENT_TEAM")

    SIGNING_REFERENCE_SHA=""
    if [[ -n "${SIGNING_REFERENCE_APP:-}" ]]; then
        SIGNING_REFERENCE_SHA="$(
            resolve_app_signing_certificate_sha1 "$SIGNING_REFERENCE_APP" || true
        )"
    fi

    detected=""
    detect_rc=0
    detected="$(
        select_signing_certificate "$SIGNING_REFERENCE_SHA" "${CERT_CANDIDATES[@]+"${CERT_CANDIDATES[@]}"}"
    )" || detect_rc=$?
    case "$detect_rc" in
        0)
            CERT_HASH="$detected"
            if [[ "${#CERT_CANDIDATES[@]}" -gt 1 ]]; then
                echo "코드서명 인증서 선택: $CERT_HASH (현재 배포본과 동일: $SIGNING_REFERENCE_APP)"
            else
                echo "코드서명 인증서 자동 탐색: $CERT_HASH"
            fi
            ;;
        1)
            echo "Developer ID Application 인증서를 keychain 에서 찾지 못했습니다." >&2
            echo "Xcode > Settings > Accounts 에서 발급받거나 CERT_HASH 환경변수로 지정하세요." >&2
            exit 1
            ;;
        2)
            echo "Developer ID Application 인증서가 여러 개인데 비교할 현재 배포본이 없습니다:" >&2
            security find-identity -v -p codesigning | grep "Developer ID Application" >&2
            echo "SIGNING_REFERENCE_APP로 현재 배포본 경로를 주거나 CERT_HASH로 직접 지정하세요." >&2
            exit 1
            ;;
        3)
            echo "현재 배포본이 쓴 인증서($SIGNING_REFERENCE_SHA)가 keychain 후보에 없습니다:" >&2
            security find-identity -v -p codesigning | grep "Developer ID Application" >&2
            echo "서명 인증서가 바뀌면 기존 사용자에게 Keychain prompt가 발생하므로 자동 선택을 거부합니다." >&2
            echo "의도한 교체라면 CERT_HASH로 명시하세요." >&2
            exit 1
            ;;
    esac
fi
NORMALIZED_CERT_HASH="$(printf '%s' "$CERT_HASH" | tr '[:lower:]' '[:upper:]')"
[[ "$NORMALIZED_CERT_HASH" =~ ^[0-9A-F]{40}$ ]] || {
    echo "CERT_HASH가 40자리 SHA-1이 아닙니다: $CERT_HASH" >&2
    exit 1
}
security find-identity -v -p codesigning 2>/dev/null \
    | awk -v hash="$NORMALIZED_CERT_HASH" -v team="$TRUSTED_DEVELOPMENT_TEAM" '
        $2 == hash && /Developer ID Application/ && $0 ~ "\\(" team "\\)" {
            found = 1
        }
        END {
            exit(found ? 0 : 1)
        }
    ' || {
        echo "선택한 Developer ID 인증서가 project team과 일치하지 않습니다: hash=$CERT_HASH, team=$TRUSTED_DEVELOPMENT_TEAM" >&2
        exit 1
    }
CERT_HASH="$NORMALIZED_CERT_HASH"
export CERT_HASH

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
validate_release_distribution "$RELEASE_DISTRIBUTION"

CONFIGURED_FEED_URL="$(extract_xcconfig_value "$LOCAL_XC_CONFIG_PATH" "SUFeedURL")"
CONFIGURED_PUBLIC_KEY="$(extract_xcconfig_value "$LOCAL_XC_CONFIG_PATH" "SUPublicEDKey")"
TRACKED_PUBLIC_KEY="$(extract_xcconfig_value "$XC_CONFIG_PATH" "SUPublicEDKey")"
DERIVED_FEED_URL=""
if [[ -n "$RELEASE_CHANNEL" ]]; then
    DERIVED_FEED_URL="$(derive_default_feed_url_for_channel "$RELEASE_CHANNEL" || true)"
fi

FEED_URL="${SU_FEED_URL:-${DERIVED_FEED_URL:-$CONFIGURED_FEED_URL}}"
if is_placeholder_value "$TRACKED_PUBLIC_KEY"; then
    echo "tracked Release.xcconfig의 SUPublicEDKey 신뢰 기준이 비어 있거나 유효하지 않습니다." >&2
    exit 1
fi
if [[ -n "${SU_PUBLIC_ED_KEY:-}" && "$SU_PUBLIC_ED_KEY" != "$TRACKED_PUBLIC_KEY" ]]; then
    echo "SU_PUBLIC_ED_KEY override가 tracked Sparkle 공개키와 다릅니다. 먼저 Config/Release.xcconfig의 trust root를 검토·갱신하세요." >&2
    exit 1
fi
if [[ -n "$CONFIGURED_PUBLIC_KEY" && "$CONFIGURED_PUBLIC_KEY" != "$TRACKED_PUBLIC_KEY" ]]; then
    echo "local SUPublicEDKey가 tracked Sparkle 공개키와 다릅니다. key rotation은 tracked trust root와 함께 반영해야 합니다." >&2
    exit 1
fi
PUBLIC_KEY="$TRACKED_PUBLIC_KEY"

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

if [[ "$RELEASE_DISTRIBUTION" == "notarized" ]]; then
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
    elif [[ -n "$APP_STORE_CONNECT_API_KEY_P8$APP_STORE_CONNECT_KEY_ID$APP_STORE_CONNECT_ISSUER_ID" ]]; then
        if [[ -z "$APP_STORE_CONNECT_API_KEY_P8" || -z "$APP_STORE_CONNECT_KEY_ID" || -z "$APP_STORE_CONNECT_ISSUER_ID" ]]; then
            echo "CodexBar식 App Store Connect API key 공증을 쓰려면 APP_STORE_CONNECT_API_KEY_P8, APP_STORE_CONNECT_KEY_ID, APP_STORE_CONNECT_ISSUER_ID 를 모두 지정해야 합니다." >&2
            exit 1
        fi
        TEMP_NOTARY_KEY_PATH="$(mktemp "${TMPDIR:-/tmp}/claudeusage-asc-key.XXXXXX")"
        printf '%s' "$APP_STORE_CONNECT_API_KEY_P8" | sed 's/\\n/\
/g' > "$TEMP_NOTARY_KEY_PATH"
        chmod 600 "$TEMP_NOTARY_KEY_PATH"
        NOTARY_SUBMIT_ARGS=(
            --key "$TEMP_NOTARY_KEY_PATH"
            --key-id "$APP_STORE_CONNECT_KEY_ID"
            --issuer "$APP_STORE_CONNECT_ISSUER_ID"
        )
        NOTARY_AUTH_DESCRIPTION="App Store Connect API key 환경 변수"
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
        echo "NOTARY_KEY_PATH/NOTARY_KEY_ID/NOTARY_ISSUER, APP_STORE_CONNECT_*, NOTARY_APPLE_ID/NOTARY_PASSWORD/NOTARY_TEAM_ID 또는 NOTARY_PROFILE 을 확인해 주세요." >&2
        exit 1
    fi
else
    NOTARY_AUTH_DESCRIPTION="disabled (internal signed-only distribution)"
fi

echo "ClaudeUsage release 산출물 빌드를 시작합니다"
echo "  - distribution: $RELEASE_DISTRIBUTION"
if [[ -n "$RELEASE_CHANNEL" ]]; then
    echo "  - release channel: $RELEASE_CHANNEL"
fi
echo "  - notary auth: $NOTARY_AUTH_DESCRIPTION"

for bin in xcodebuild xcrun hdiutil codesign plutil; do
    command -v "$bin" >/dev/null 2>&1 || {
        echo "$bin 을 찾지 못했습니다." >&2
        exit 1
    }
done
[[ -x /usr/libexec/PlistBuddy ]] || {
    echo "PlistBuddy를 찾지 못했습니다." >&2
    exit 1
}

if [[ "$RELEASE_DISTRIBUTION" == "notarized" ]]; then
    preflight_notary_credentials
fi

if [[ "$SKIP_DMG" != "1" && ! -x "$MAKE_DMG_SCRIPT" ]]; then
    echo "make-dmg.sh 를 찾지 못했습니다: $MAKE_DMG_SCRIPT" >&2
    exit 1
fi

mkdir -p "$BUILD_DIR"
rm -rf "$ARCHIVE_PATH" "$ZIP_PATH" "$DMG_PATH"

if [[ -n "$RELEASE_CHANNEL" || -n "${SU_FEED_URL:-}" || -n "${SU_PUBLIC_ED_KEY:-}" ]]; then
    TEMP_XC_CONFIG_DIR="$(mktemp -d "$BUILD_DIR/release-override.XXXXXX")"
    TEMP_XC_CONFIG_PATH="$TEMP_XC_CONFIG_DIR/release-override.xcconfig"
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
XCODEBUILD_ARCHIVE_ARGS=(
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -xcconfig "$EFFECTIVE_XC_CONFIG_PATH" \
    -archivePath "$ARCHIVE_PATH" \
    archive
)
if [[ -n "$DERIVED_DATA_PATH" ]]; then
    XCODEBUILD_ARCHIVE_ARGS=(
        -derivedDataPath "$DERIVED_DATA_PATH"
        "${XCODEBUILD_ARCHIVE_ARGS[@]}"
    )
fi
xcodebuild "${XCODEBUILD_ARCHIVE_ARGS[@]}"

if [[ -n "$TEMP_XC_CONFIG_PATH" ]]; then
    rm -f "$TEMP_XC_CONFIG_PATH"
    [[ ! -e "$TEMP_XC_CONFIG_PATH" ]] \
        || {
            echo "archive 후 임시 xcconfig를 정리하지 못했습니다: $TEMP_XC_CONFIG_PATH" >&2
            exit 1
        }
    TEMP_XC_CONFIG_PATH=""
fi
if [[ -n "$TEMP_XC_CONFIG_DIR" ]]; then
    rmdir "$TEMP_XC_CONFIG_DIR"
    [[ ! -e "$TEMP_XC_CONFIG_DIR" ]] \
        || {
            echo "archive 후 임시 xcconfig 디렉터리를 정리하지 못했습니다: $TEMP_XC_CONFIG_DIR" >&2
            exit 1
        }
    TEMP_XC_CONFIG_DIR=""
fi
echo "archive 임시 xcconfig 정리 완료"

if [[ ! -d "$APP_PATH" ]]; then
    echo "archive 안에서 앱을 찾지 못했습니다: $APP_PATH" >&2
    exit 1
fi

/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $PUBLIC_KEY" "$APP_PATH/Contents/Info.plist"
RESOLVED_ENTITLEMENTS_PATH="$BUILD_DIR/ClaudeUsage.resolved.entitlements"
extract_and_validate_app_entitlements \
    "$APP_PATH" \
    "$RESOLVED_ENTITLEMENTS_PATH"

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
    --entitlements "$RESOLVED_ENTITLEMENTS_PATH" \
    --sign "$CERT_HASH" \
    "$APP_PATH"
extract_and_validate_app_entitlements \
    "$APP_PATH" \
    "$RESOLVED_ENTITLEMENTS_PATH"
rm -f "$RESOLVED_ENTITLEMENTS_PATH"
[[ ! -e "$RESOLVED_ENTITLEMENTS_PATH" ]] \
    || {
        echo "해석된 entitlements 파일을 정리하지 못했습니다: $RESOLVED_ENTITLEMENTS_PATH" >&2
        exit 1
    }
RESOLVED_ENTITLEMENTS_PATH=""

# ── 3. 앱 ZIP 생성 ──────────────────────────────────────────

echo
echo "3. 앱 ZIP 생성"
create_app_zip

if [[ "$RELEASE_DISTRIBUTION" == "notarized" ]]; then
    # ── 4. 앱 notarize ──────────────────────────────────────

    echo
    echo "4. 앱 notarization 제출 (--wait)"
    xcrun notarytool submit "$ZIP_PATH" \
        "${NOTARY_SUBMIT_ARGS[@]}" \
        --wait

    # ── 5. 앱 staple ────────────────────────────────────────

    echo
    echo "5. 앱 staple 적용"
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
    spctl --assess --type execute --verbose=4 "$APP_PATH"

    # ── 6. stapled ZIP 재생성 ──────────────────────────────

    echo
    echo "6. stapled ZIP 재생성"
    rm -f "$ZIP_PATH"
    create_app_zip
else
    echo
    echo "4. 내부 배포용 앱 서명 검증"
    codesign --verify --deep --strict --verbose=2 "$APP_PATH"
    echo "   notarization/staple 단계는 RELEASE_DISTRIBUTION=internal 로 건너뜁니다."
fi

if [[ "$SKIP_DMG" == "1" ]]; then
    echo
    cat <<EOF
완료 (ZIP 만, distribution=$RELEASE_DISTRIBUTION)
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

if [[ "$RELEASE_DISTRIBUTION" == "notarized" ]]; then
    # ── 8. DMG notarize ────────────────────────────────────

    echo
    echo "8. DMG notarization 제출 (--wait)"
    xcrun notarytool submit "$DMG_PATH" \
        "${NOTARY_SUBMIT_ARGS[@]}" \
        --wait

    # ── 9. DMG staple ──────────────────────────────────────

    echo
    echo "9. DMG staple 적용"
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"

    # ── 10. 최종 Gatekeeper 검증 ────────────────────────────

    echo
    echo "10. Gatekeeper 최종 검증"
    spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
else
    echo
    echo "8. 내부 배포용 DMG 서명 검증"
    codesign --verify --verbose=2 "$DMG_PATH"
    echo "   Gatekeeper 참고 검증:"
    spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH" || true
    echo "   내부 배포 모드는 Apple notarization 이 없으므로 다운로드 quarantine 경로에서는 macOS가 경고하거나 차단할 수 있습니다."
fi

DMG_SIZE_BYTES=$(stat -f%z "$DMG_PATH")
DMG_SIZE_MB=$(awk -v b="$DMG_SIZE_BYTES" 'BEGIN { printf "%.2f", b / 1024 / 1024 }')

echo
cat <<EOF
완료
    archive: $ARCHIVE_PATH
    app:     $APP_PATH
    zip:     $ZIP_PATH  (Sparkle appcast 다운로드용)
    dmg:     $DMG_PATH  (${DMG_SIZE_MB}MB, 설치 배포용)
    distribution: $RELEASE_DISTRIBUTION

다음 단계
    1. 검증된 main에서 Scripts/release.sh stg|prod X.Y.Z 로 게시
    2. Sparkle 업데이트 경로가 활성인지 설정 화면에서 확인
EOF
