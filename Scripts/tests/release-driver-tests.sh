#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=Scripts/lib/release-driver-common.sh
source "$ROOT_DIR/Scripts/lib/release-driver-common.sh"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/claudeusage-release-driver-tests.XXXXXX")"
cleanup() {
    local exit_code=$?
    local cleanup_failed=0

    if ! rm -rf "$TEST_ROOT" || [[ -e "$TEST_ROOT" ]]; then
        echo "FAIL: test 임시 디렉터리를 정리하지 못했습니다: $TEST_ROOT" >&2
        cleanup_failed=1
    fi
    trap - EXIT
    exit "$(release_cleanup_exit_code "$exit_code" "$cleanup_failed" 0)"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

PASS_COUNT=0

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_equal() {
    local expected="$1"
    local actual="$2"
    local label="$3"
    [[ "$actual" == "$expected" ]] || fail "$label: expected='$expected', actual='$actual'"
    pass
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local label="$3"
    [[ "$haystack" == *"$needle"* ]] || fail "$label: '$needle'를 찾지 못했습니다."
    pass
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local label="$3"
    [[ "$haystack" != *"$needle"* ]] || fail "$label: 금지된 '$needle'를 찾았습니다."
    pass
}

assert_ordered() {
    local haystack="$1"
    local first="$2"
    local second="$3"
    local label="$4"
    local first_prefix second_prefix

    [[ "$haystack" == *"$first"* ]] || fail "$label: 첫 명령 '$first'를 찾지 못했습니다."
    [[ "$haystack" == *"$second"* ]] || fail "$label: 둘째 명령 '$second'를 찾지 못했습니다."
    first_prefix="${haystack%%"$first"*}"
    second_prefix="${haystack%%"$second"*}"
    (( ${#first_prefix} < ${#second_prefix} )) \
        || fail "$label: '$first'가 '$second'보다 먼저 실행되지 않았습니다."
    pass
}

assert_line_count() {
    local haystack="$1"
    local line="$2"
    local expected_count="$3"
    local label="$4"
    local actual_count

    actual_count="$(
        printf '%s\n' "$haystack" \
            | awk -v expected="$line" '$0 == expected { count += 1 } END { print count + 0 }'
    )"
    [[ "$actual_count" == "$expected_count" ]] \
        || fail "$label: '$line' expected=$expected_count, actual=$actual_count"
    pass
}

assert_success() {
    local label="$1"
    shift
    "$@" || fail "$label: 성공해야 합니다."
    pass
}

assert_failure() {
    local label="$1"
    shift
    if "$@"; then
        fail "$label: 실패해야 합니다."
    fi
    pass
}

assert_equal "staging" "$(normalize_release_environment stg)" "stg alias"
assert_equal "staging" "$(normalize_release_environment staging)" "staging name"
assert_equal "prod" "$(normalize_release_environment prod)" "prod name"
assert_failure "unknown environment" normalize_release_environment stage

assert_success "2.4.0 numeric version" validate_numeric_release_version 2.4.0
assert_success "two-digit patch" validate_numeric_release_version 2.4.10
assert_failure "v prefix rejected" validate_numeric_release_version v2.4.0
assert_failure "staging suffix rejected" validate_numeric_release_version 2.4.0-staging
assert_failure "leading zero rejected" validate_numeric_release_version 2.04.0
assert_failure "minor overflow rejected" validate_numeric_release_version 2.100.0
assert_failure "patch overflow rejected" validate_numeric_release_version 2.4.100
assert_failure "major overflow rejected" validate_numeric_release_version 214748.0.0
assert_failure "very large major rejected" validate_numeric_release_version 9999999999999999999.0.0
assert_failure "wrapping major rejected" validate_numeric_release_version 18446744073709551616.0.0

assert_equal "20400" "$(derive_release_build_number 2.4.0)" "2.4.0 build"
assert_equal "20401" "$(derive_release_build_number 2.4.1)" "2.4.1 build"
assert_equal "20410" "$(derive_release_build_number 2.4.10)" "2.4.10 build"
assert_equal "20500" "$(derive_release_build_number 2.5.0)" "2.5.0 build"
assert_equal "v2.4.0-staging" "$(release_tag_for staging 2.4.0)" "staging tag"
assert_equal "v2.4.0" "$(release_tag_for prod 2.4.0)" "prod tag"
assert_equal "2.4.0" "$(release_version_from_tag v2.4.0-staging)" "staging tag version"
assert_equal "1" "$(compare_numeric_release_versions 2.4.1 2.4.0)" "version greater"
assert_equal "0" "$(compare_numeric_release_versions 2.4.0 2.4.0)" "version equal"
assert_equal "-1" "$(compare_numeric_release_versions 2.3.99 2.4.0)" "version lower"
assert_equal \
    "legacy-prod" \
    "$(release_artifact_identity_metadata_policy prod 2.3.3)" \
    "historical prod accepts legacy identity metadata"
assert_equal \
    "strict" \
    "$(release_artifact_identity_metadata_policy prod 2.4.0)" \
    "current prod requires explicit identity metadata"
assert_equal \
    "strict" \
    "$(release_artifact_identity_metadata_policy staging 2.3.3)" \
    "staging never accepts prod legacy identity metadata"
assert_failure \
    "identity policy rejects unknown environment" \
    release_artifact_identity_metadata_policy beta 2.4.0
assert_equal "0" "$(release_cleanup_exit_code 0 0 0)" "clean success status"
assert_equal "1" "$(release_cleanup_exit_code 0 1 0)" "cleanup failure changes success"
assert_equal "1" "$(release_cleanup_exit_code 0 0 1)" "account restore failure changes success"
assert_equal "7" "$(release_cleanup_exit_code 7 1 1)" "original failure is preserved"
# 서명 인증서 선택. 후보가 여러 개일 때 임의로 고르면 기존 사용자 Keychain ACL
# 연속성이 끊기므로, 현재 배포본과 일치하는 것만 골라야 한다.
CERT_A="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
CERT_B="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
assert_equal "$CERT_A" "$(select_signing_certificate "" "$CERT_A")" \
    "single certificate needs no reference"
assert_equal "$CERT_B" "$(select_signing_certificate "$CERT_B" "$CERT_A" "$CERT_B")" \
    "reference picks the deployed certificate"
assert_failure "no candidate" select_signing_certificate ""
set +e
select_signing_certificate "" "$CERT_A" "$CERT_B" >/dev/null 2>&1
AMBIGUOUS_RC=$?
select_signing_certificate "$CERT_A$CERT_A" "$CERT_A" "$CERT_B" >/dev/null 2>&1
UNKNOWN_REFERENCE_RC=$?
set -e
assert_equal "2" "$AMBIGUOUS_RC" "ambiguous candidates without reference are rejected"
assert_equal "3" "$UNKNOWN_REFERENCE_RC" "reference absent from candidates is rejected"

RESOLVE_TAG_REPO="$TEST_ROOT/resolve-tag-repo"
git init -q "$RESOLVE_TAG_REPO"
git -C "$RESOLVE_TAG_REPO" \
    -c user.email=release-tests@example.com \
    -c user.name="release tests" \
    commit -q --allow-empty -m init
RESOLVE_TAG_HEAD="$(git -C "$RESOLVE_TAG_REPO" rev-parse HEAD)"
git -C "$RESOLVE_TAG_REPO" tag v9.9.9-staging
assert_equal \
    "$RESOLVE_TAG_HEAD" \
    "$(resolve_local_tag_commit "$RESOLVE_TAG_REPO" v9.9.9-staging)" \
    "existing local tag resolves to commit"
# 없는 tag는 리터럴 ref 문자열이 아니라 빈 문자열이어야 한다. 비어 있지 않으면
# 아직 발행하지 않은 새 버전이 항상 mismatched로 차단된다.
assert_equal \
    "" \
    "$(resolve_local_tag_commit "$RESOLVE_TAG_REPO" v9.9.10-staging)" \
    "absent local tag resolves to empty"

assert_equal "fresh" "$(classify_release_candidate_state absent absent previous)" "fresh release state"
assert_equal "tag_only" "$(classify_release_candidate_state matching absent previous)" "tag-only resume state"
assert_equal "pages_pending" "$(classify_release_candidate_state matching complete previous)" "Pages resume state"
assert_equal "complete" "$(classify_release_candidate_state matching complete candidate)" "complete release state"
assert_equal "burned" "$(classify_release_candidate_state mismatched absent previous)" "mismatched tag burns candidate"
assert_equal "burned" "$(classify_release_candidate_state matching partial previous)" "partial release burns candidate"
assert_equal "burned" "$(classify_release_candidate_state matching complete diverged)" "diverged feed burns candidate"
assert_equal "burned" "$(classify_release_candidate_state absent complete candidate)" "release without matching tag burns candidate"

FIXTURE_ROOT="$TEST_ROOT/repository"
FIXTURE_TMP="$TEST_ROOT/dry-run-tmp"
FIXTURE_HOME="$TEST_ROOT/home"
mkdir -p "$FIXTURE_ROOT/ClaudeUsage.xcodeproj" "$FIXTURE_TMP" "$FIXTURE_HOME"
cat > "$FIXTURE_ROOT/ClaudeUsage.xcodeproj/project.pbxproj" <<'PBX'
{
    MARKETING_VERSION = 2.4.0;
    CURRENT_PROJECT_VERSION = 20400;
    MARKETING_VERSION = 2.4.0;
    CURRENT_PROJECT_VERSION = 20400;
}
PBX

assert_equal "2.4.0" "$(read_project_release_version "$FIXTURE_ROOT/ClaudeUsage.xcodeproj/project.pbxproj")" "project version"
assert_equal "20400" "$(read_project_release_build "$FIXTURE_ROOT/ClaudeUsage.xcodeproj/project.pbxproj")" "project build"

DRY_RUN_COMMON_ENV=(
    "RELEASE_DRIVER_TEST_MODE=1"
    "RELEASE_DRIVER_ROOT_DIR=$FIXTURE_ROOT"
    "RELEASE_DRIVER_TEST_PROD_TAG=v2.3.3"
    "RELEASE_DRIVER_TEST_STAGING_TAG=v2.3.3-staging"
    "RELEASE_DRIVER_TEST_STAGING_IDENTITY_BOOTSTRAP_VERSION=2.4.0"
    $'RELEASE_DRIVER_TEST_PROD_FEED_STATE=2.3.3\t20330\tv2.3.3'
    $'RELEASE_DRIVER_TEST_STAGING_FEED_STATE=2.3.3\t20330\tv2.3.3-staging'
    "HOME=$FIXTURE_HOME"
    "TMPDIR=$FIXTURE_TMP"
)

snapshot_tree() {
    local root="$1"
    find "$root" -print | LC_ALL=C sort | while IFS= read -r entry; do
        stat -f '%Sp:%z:%N' "$entry"
        if [[ -f "$entry" ]]; then
            shasum -a 256 "$entry"
        fi
    done
}

BEFORE_SNAPSHOT="$(snapshot_tree "$TEST_ROOT")"
STAGING_OUTPUT="$(
    env "${DRY_RUN_COMMON_ENV[@]}" \
        /bin/bash "$ROOT_DIR/Scripts/release.sh" \
        stg 2.4.0 --non-interactive --dry-run
)"
AFTER_SNAPSHOT="$(snapshot_tree "$TEST_ROOT")"
assert_equal "$BEFORE_SNAPSHOT" "$AFTER_SNAPSHOT" "release dry-run filesystem unchanged"
assert_equal "" "$(find "$FIXTURE_TMP" -mindepth 1 -print -quit)" "release dry-run creates no temp"
assert_contains "$STAGING_OUTPUT" "환경 입력:  stg -> staging" "stg normalization output"
assert_contains "$STAGING_OUTPUT" "generated tag:     v2.4.0-staging" "staging generated tag output"
assert_contains "$STAGING_OUTPUT" "expected build:    20400" "standard build output"
assert_contains "$STAGING_OUTPUT" "v2.3.3-staging / 2.3.3 (20330)" "historical prior build preserved"
assert_contains "$STAGING_OUTPUT" "DRY-RUN 완료" "release dry-run completion"

PROD_OUTPUT="$(
    env "${DRY_RUN_COMMON_ENV[@]}" \
        /bin/bash "$ROOT_DIR/Scripts/release.sh" \
        prod 2.4.0 --non-interactive --dry-run
)"
assert_contains "$PROD_OUTPUT" "generated tag:     v2.4.0" "prod generated tag output"
assert_contains "$PROD_OUTPUT" "upgrade 기준:     v2.3.3 / 2.3.3 (20330)" "prod prior channel"
assert_equal "" "$(find "$FIXTURE_TMP" -mindepth 1 -print -quit)" "prod dry-run creates no temp"

set +e
MISMATCH_OUTPUT="$(
    env "${DRY_RUN_COMMON_ENV[@]}" \
        /bin/bash "$ROOT_DIR/Scripts/release.sh" \
        stg 2.4.1 --non-interactive --dry-run 2>&1
)"
MISMATCH_STATUS=$?
set -e
[[ "$MISMATCH_STATUS" -ne 0 ]] || fail "project mismatch dry-run은 실패해야 합니다."
pass
assert_contains "$MISMATCH_OUTPUT" "CURRENT_PROJECT_VERSION=20401" "mismatch expected build guidance"
assert_contains "$MISMATCH_OUTPUT" "ClaudeUsage.xcodeproj/project.pbxproj" "mismatch edit location"
assert_equal "" "$(find "$FIXTURE_TMP" -mindepth 1 -print -quit)" "failed dry-run creates no temp"

set +e
BLOCKED_TEST_EXECUTION_OUTPUT="$(
    env "${DRY_RUN_COMMON_ENV[@]}" \
        /bin/bash "$ROOT_DIR/Scripts/release.sh" \
        stg 2.4.0 \
        --non-interactive \
        --confirm-publish v2.4.0-staging \
        2>&1
)"
BLOCKED_TEST_EXECUTION_STATUS=$?
set -e
[[ "$BLOCKED_TEST_EXECUTION_STATUS" -ne 0 ]] \
    || fail "명시적 test execute opt-in 없는 actual path는 실패해야 합니다."
pass
assert_contains \
    "$BLOCKED_TEST_EXECUTION_OUTPUT" \
    "RELEASE_DRIVER_TEST_EXECUTE=1이 필요합니다." \
    "test actual path explicit opt-in"
assert_equal "" "$(find "$FIXTURE_TMP" -mindepth 1 -print -quit)" "blocked test execution creates no temp"

VERIFIER_OUTPUT="$(
    TMPDIR="$FIXTURE_TMP" \
        /bin/bash "$ROOT_DIR/Scripts/verify-release-artifact.sh" \
        --tag v2.4.0-staging \
        --channel staging \
        --expected-version 2.4.0 \
        --expected-build 20400 \
        --install-to "$TEST_ROOT/Downloads/ClaudeUsage-stg.app" \
        --dry-run
)"
assert_contains "$VERIFIER_OUTPUT" "DRY-RUN" "artifact verifier dry-run"
assert_equal "" "$(find "$FIXTURE_TMP" -mindepth 1 -print -quit)" "verifier dry-run creates no temp"
[[ ! -e "$TEST_ROOT/Downloads/ClaudeUsage-stg.app" ]] || fail "verifier dry-run이 앱을 생성했습니다."
pass

EMPTY_ARCHIVE="$TEST_ROOT/empty-archive.zip"
SIGNATURE_MODULE_CACHE="$TEST_ROOT/signature-module-cache"
: > "$EMPTY_ARCHIVE"
xcrun swift \
    -module-cache-path "$SIGNATURE_MODULE_CACHE" \
    "$ROOT_DIR/Scripts/verify-sparkle-signature.swift" \
    "$EMPTY_ARCHIVE" \
    "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=" \
    "5VZDAMNgrHKQhuLMgG6CioSHfx645dl02HPgZSJJAVVfuIIVkKM7rMYeOXAc+bRr0lv18FlbviRlUUFDjnoQCw==" \
    >/dev/null || fail "RFC 8032 Ed25519 signature는 성공해야 합니다."
pass
if xcrun swift \
    -module-cache-path "$SIGNATURE_MODULE_CACHE" \
    "$ROOT_DIR/Scripts/verify-sparkle-signature.swift" \
    "$EMPTY_ARCHIVE" \
    "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=" \
    "6VZDAMNgrHKQhuLMgG6CioSHfx645dl02HPgZSJJAVVfuIIVkKM7rMYeOXAc+bRr0lv18FlbviRlUUFDjnoQCw==" \
    >/dev/null 2>&1; then
    fail "변조된 Ed25519 signature는 실패해야 합니다."
fi
pass
rm -rf "$SIGNATURE_MODULE_CACHE" "$EMPTY_ARCHIVE"
[[ ! -e "$SIGNATURE_MODULE_CACHE" && ! -e "$EMPTY_ARCHIVE" ]] \
    || fail "signature test 임시 파일 정리에 실패했습니다."
pass

ORCHESTRATION_ROOT="$TEST_ROOT/orchestration"
ORCHESTRATION_REPOSITORY="$ORCHESTRATION_ROOT/repository"
ORCHESTRATION_BIN="$ORCHESTRATION_ROOT/bin"
ORCHESTRATION_TMP="$ORCHESTRATION_ROOT/tmp"
ORCHESTRATION_STATE="$ORCHESTRATION_ROOT/state"
ORCHESTRATION_DOWNLOADS="$ORCHESTRATION_ROOT/Downloads"
ORCHESTRATION_TRACE="$ORCHESTRATION_STATE/commands.log"
ORCHESTRATION_ACCOUNT="$ORCHESTRATION_STATE/active-account"
ORCHESTRATION_FEED_SWITCH="$ORCHESTRATION_STATE/feed-switched"
ORCHESTRATION_PAGES_STATE="$ORCHESTRATION_STATE/pages-state-count"
ORCHESTRATION_HEAD="1111111111111111111111111111111111111111"
ORCHESTRATION_PAGES_HEAD="2222222222222222222222222222222222222222"
mkdir -p \
    "$ORCHESTRATION_REPOSITORY/ClaudeUsage.xcodeproj" \
    "$ORCHESTRATION_REPOSITORY/Scripts/tests" \
    "$ORCHESTRATION_BIN" \
    "$ORCHESTRATION_TMP" \
    "$ORCHESTRATION_STATE" \
    "$ORCHESTRATION_DOWNLOADS"

cat > "$ORCHESTRATION_REPOSITORY/ClaudeUsage.xcodeproj/project.pbxproj" <<'PBX'
{
    MARKETING_VERSION = 2.4.0;
    CURRENT_PROJECT_VERSION = 20400;
    MARKETING_VERSION = 2.4.0;
    CURRENT_PROJECT_VERSION = 20400;
}
PBX

cat > "$ORCHESTRATION_REPOSITORY/Scripts/tests/release-driver-tests.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf 'gate <release-driver-shell-tests>\n' >> "${RELEASE_DRIVER_TEST_TRACE:?}"
SCRIPT

cat > "$ORCHESTRATION_REPOSITORY/Scripts/verify-release-artifact.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'verify'
    printf ' <%s>' "$@"
    printf '\n'
} >> "${RELEASE_DRIVER_TEST_TRACE:?}"
install_path=""
export_path=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --install-to)
            install_path="$2"
            shift 2
            ;;
        --export-verified-appcast-to)
            export_path="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done
if [[ -n "$install_path" ]]; then
    mkdir -p "$install_path"
    printf 'fixture app\n' > "$install_path/fixture.txt"
fi
if [[ -n "$export_path" ]]; then
    mkdir -p "$(dirname "$export_path")"
    printf '<appcast verified="true">candidate</appcast>\n' > "$export_path"
    printf 'verify-export <verified-candidate-appcast>\n' \
        >> "${RELEASE_DRIVER_TEST_TRACE:?}"
fi
SCRIPT

cat > "$ORCHESTRATION_REPOSITORY/Scripts/build-notarize-release.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'build'
    printf ' <BUILD_DIR=%s>' "${BUILD_DIR:?}"
    printf ' <ARCHIVE_PATH=%s>' "${ARCHIVE_PATH:?}"
    printf ' <ZIP_PATH=%s>' "${ZIP_PATH:?}"
    printf ' <DMG_PATH=%s>' "${DMG_PATH:?}"
    printf ' <PROJECT_PATH=%s>' "${PROJECT_PATH:?}"
    printf ' <XC_CONFIG_PATH=%s>' "${XC_CONFIG_PATH:?}"
    printf ' <LOCAL_XC_CONFIG_PATH=%s>' "${LOCAL_XC_CONFIG_PATH:?}"
    printf ' <DERIVED_DATA_PATH=%s>' "${DERIVED_DATA_PATH:?}"
    printf ' <ENTITLEMENTS_PATH=%s>' "${ENTITLEMENTS_PATH:?}"
    printf ' <RELEASE_CHANNEL=%s>' "${RELEASE_CHANNEL:?}"
    printf ' <RELEASE_DISTRIBUTION=%s>' "${RELEASE_DISTRIBUTION:?}"
    printf ' <NOTARY_PROFILE=%s>' "${NOTARY_PROFILE:?}"
    printf ' <SU_FEED_URL=%s>' "${SU_FEED_URL:?}"
    printf ' <SIGNING_REFERENCE_APP=%s>' "${SIGNING_REFERENCE_APP:?}"
    printf ' <TMPDIR=%s>\n' "${TMPDIR:?}"
} >> "${RELEASE_DRIVER_TEST_TRACE:?}"
run_root="${TMPDIR%/tmp}"
[[ "$BUILD_DIR" == "$run_root/build" ]]
[[ "$ARCHIVE_PATH" == "$BUILD_DIR/ClaudeUsage.xcarchive" ]]
[[ "$ZIP_PATH" == "$BUILD_DIR/ClaudeUsage.zip" ]]
[[ "$DMG_PATH" == "$BUILD_DIR/ClaudeUsage.dmg" ]]
[[ "$PROJECT_PATH" == "${RELEASE_DRIVER_ROOT_DIR:?}/ClaudeUsage.xcodeproj" ]]
[[ "$XC_CONFIG_PATH" == "$RELEASE_DRIVER_ROOT_DIR/Config/Release.xcconfig" ]]
[[ "$LOCAL_XC_CONFIG_PATH" == "$RELEASE_DRIVER_ROOT_DIR/Config/Sparkle.release.local.xcconfig" ]]
[[ "$ENTITLEMENTS_PATH" == "$RELEASE_DRIVER_ROOT_DIR/ClaudeUsage/ClaudeUsage.entitlements" ]]
[[ "$RELEASE_CHANNEL" == "staging" ]]
[[ "$SU_FEED_URL" == "${RELEASE_DRIVER_TEST_EXPECTED_FEED:?}" ]]
[[ "$SIGNING_REFERENCE_APP" == "${RELEASE_DRIVER_TEST_SANDBOX_ROOT:?}/Applications/ClaudeUsage.app" ]]
app_path="$ARCHIVE_PATH/Products/Applications/ClaudeUsage-stg.app"
sparkle_path="$DERIVED_DATA_PATH/SourcePackages/artifacts/sparkle/Sparkle/bin"
mkdir -p "$app_path/Contents" "$sparkle_path"
: > "$ZIP_PATH"
: > "$DMG_PATH"
cat > "$app_path/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleShortVersionString</key>
    <string>2.4.0</string>
    <key>CFBundleVersion</key>
    <string>20400</string>
    <key>CFBundleIdentifier</key>
    <string>com.seongmin.ClaudeUsage.staging</string>
    <key>CFBundleDisplayName</key>
    <string>ClaudeUsage-stg</string>
    <key>ClaudeUsageReleaseChannel</key>
    <string>staging</string>
    <key>SUFeedURL</key>
    <string>${RELEASE_DRIVER_TEST_EXPECTED_FEED:?}</string>
</dict>
</plist>
PLIST
printf '#!/usr/bin/env bash\nexit 0\n' > "$sparkle_path/generate_appcast"
printf '#!/usr/bin/env bash\nexit 0\n' > "$sparkle_path/sign_update"
chmod +x "$sparkle_path/generate_appcast" "$sparkle_path/sign_update"
SCRIPT

cat > "$ORCHESTRATION_REPOSITORY/Scripts/publish-release.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'publish'
    printf ' <%s>' "$@"
    printf '\n'
    printf 'publish-env'
    printf ' <BUILD_DIR=%s>' "${BUILD_DIR:?}"
    printf ' <DMG_PATH=%s>' "${DMG_PATH:?}"
    printf ' <ZIP_PATH=%s>' "${ZIP_PATH:?}"
    printf ' <APPCAST_PATH=%s>' "${APPCAST_PATH:?}"
    printf ' <LOCAL_XC_CONFIG_PATH=%s>' "${LOCAL_XC_CONFIG_PATH:?}"
    printf ' <SU_FEED_URL=%s>' "${SU_FEED_URL:?}"
    printf ' <DOWNLOAD_BASE_URL=%s>' "${DOWNLOAD_BASE_URL:?}"
    printf ' <RELEASE_TAG=%s>' "${RELEASE_TAG:?}"
    printf ' <TMPDIR=%s>\n' "${TMPDIR:?}"
} >> "${RELEASE_DRIVER_TEST_TRACE:?}"
run_root="${TMPDIR%/tmp}"
[[ "$BUILD_DIR" == "$run_root/build" ]]
[[ "$DMG_PATH" == "$BUILD_DIR/ClaudeUsage.dmg" ]]
[[ "$ZIP_PATH" == "$BUILD_DIR/ClaudeUsage.zip" ]]
[[ "$APPCAST_PATH" == "$BUILD_DIR/appcast.xml" ]]
[[ "$LOCAL_XC_CONFIG_PATH" == "${RELEASE_DRIVER_ROOT_DIR:?}/Config/Sparkle.release.local.xcconfig" ]]
[[ "$SU_FEED_URL" == "${RELEASE_DRIVER_TEST_EXPECTED_FEED:?}" ]]
[[ "$DOWNLOAD_BASE_URL" == "https://github.com/ChoSeongmin1128/claude-usage/releases/download/v2.4.0-staging" ]]
[[ "$RELEASE_TAG" == "v2.4.0-staging" ]]
SCRIPT

cat > "$ORCHESTRATION_REPOSITORY/Scripts/publish-pages-appcast.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'pages-publish'
    printf ' <%s>' "$@"
    printf '\n'
    printf 'pages-env'
    printf ' <GHPAGES_BRANCH=%s>' "${GHPAGES_BRANCH:?}"
    printf ' <TMPDIR=%s>\n' "${TMPDIR:?}"
} >> "${RELEASE_DRIVER_TEST_TRACE:?}"
[[ "$GHPAGES_BRANCH" == "gh-pages" ]]
[[ -f "${APPCAST_SOURCE:?}" ]]
[[ "$(cat "$APPCAST_SOURCE")" == '<appcast verified="true">candidate</appcast>' ]]
printf 'pages-source <verified-candidate-appcast>\n' \
    >> "${RELEASE_DRIVER_TEST_TRACE:?}"
: > "${RELEASE_DRIVER_TEST_FEED_SWITCH_FILE:?}"
SCRIPT

cat > "$ORCHESTRATION_BIN/git" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'git'
    printf ' <%s>' "$@"
    printf '\n'
} >> "${RELEASE_DRIVER_TEST_TRACE:?}"
if [[ "${1:-}" == "-C" ]]; then
    shift 2
fi
case "${1:-}" in
    fetch)
        exit 0
        ;;
    status)
        exit 0
        ;;
    branch)
        printf 'main\n'
        ;;
    remote)
        [[ "${2:-}" == "get-url" && "${3:-}" == "origin" ]]
        printf 'git@github-seongmin:ChoSeongmin1128/claude-usage.git\n'
        ;;
    rev-parse)
        case "${2:-}" in
            HEAD|origin/main)
                printf '%s\n' "${RELEASE_DRIVER_TEST_HEAD:?}"
                ;;
            refs/tags/v2.4.0-staging*|refs/tags/v2.4.0*)
                case "${RELEASE_DRIVER_TEST_CANDIDATE_MODE:?}" in
                    fresh)
                        exit 1
                        ;;
                    *)
                        printf '%s\n' "${RELEASE_DRIVER_TEST_HEAD:?}"
                        ;;
                esac
                ;;
            *)
                exit 1
                ;;
        esac
        ;;
    ls-remote)
        if [[ "${2:-}" == "--tags" ]]; then
            case "${RELEASE_DRIVER_TEST_CANDIDATE_MODE:?}" in
                fresh)
                    exit 0
                    ;;
                *)
                    printf '%s\trefs/tags/v2.4.0-staging\n' "${RELEASE_DRIVER_TEST_HEAD:?}"
                    ;;
            esac
        elif [[ "${2:-}" == "origin" && "${3:-}" == "refs/heads/gh-pages" ]]; then
            printf '%s\trefs/heads/gh-pages\n' "${RELEASE_DRIVER_TEST_PAGES_HEAD:?}"
        else
            exit 1
        fi
        ;;
    *)
        printf 'unexpected fake git invocation\n' >&2
        exit 97
        ;;
esac
SCRIPT

cat > "$ORCHESTRATION_BIN/gh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'gh'
    printf ' <%s>' "$@"
    printf '\n'
} >> "${RELEASE_DRIVER_TEST_TRACE:?}"
case "${1:-}" in
    auth)
        case "${2:-}" in
            status)
                printf 'Logged in to github.com account ChoSeongmin1128\n'
                printf 'Logged in to github.com account nathan-glorang\n'
                ;;
            switch)
                shift 2
                while [[ $# -gt 0 ]]; do
                    case "$1" in
                        --user)
                            printf '%s\n' "$2" > "${RELEASE_DRIVER_TEST_ACCOUNT_FILE:?}"
                            shift 2
                            ;;
                        *)
                            shift
                            ;;
                    esac
                done
                ;;
            *)
                exit 97
                ;;
        esac
        ;;
    api)
        if [[ "${2:-}" == "user" ]]; then
            cat "${RELEASE_DRIVER_TEST_ACCOUNT_FILE:?}"
        elif [[ "${2:-}" == *"/releases/tags/v2.4.0-staging" ]]; then
            case "${RELEASE_DRIVER_TEST_CANDIDATE_MODE:?}" in
                fresh|tag_only)
                    printf 'gh: Not Found (HTTP 404)\n' >&2
                    exit 1
                    ;;
                pages_pending|complete)
                    printf '{}\n'
                    ;;
            esac
        elif [[ "${2:-}" == *"/pages/builds/latest" ]]; then
            pages_count=0
            if [[ -f "${RELEASE_DRIVER_TEST_PAGES_STATE_FILE:?}" ]]; then
                pages_count="$(cat "$RELEASE_DRIVER_TEST_PAGES_STATE_FILE")"
            fi
            pages_count=$((pages_count + 1))
            printf '%s\n' "$pages_count" > "$RELEASE_DRIVER_TEST_PAGES_STATE_FILE"
            case "${RELEASE_DRIVER_TEST_PAGES_SEQUENCE:-built}" in
                built)
                    pages_status="built"
                    ;;
                queued_errored)
                    case "$pages_count" in
                        1)
                            pages_status="queued"
                            ;;
                        2|3)
                            pages_status="errored"
                            ;;
                        *)
                            pages_status="built"
                            ;;
                    esac
                    ;;
                *)
                    exit 97
                    ;;
            esac
            printf 'pages-state <%s>\n' "$pages_status" \
                >> "${RELEASE_DRIVER_TEST_TRACE:?}"
            printf '%s\t%s\n' "$pages_status" "${RELEASE_DRIVER_TEST_PAGES_HEAD:?}"
        elif [[ "${2:-}" == "--method" \
            && "${3:-}" == "POST" \
            && "${4:-}" == *"/pages/builds" ]]; then
            exit 0
        else
            printf 'unexpected fake gh api invocation\n' >&2
            exit 97
        fi
        ;;
    repo)
        [[ "${2:-}" == "view" ]]
        printf 'ChoSeongmin1128/claude-usage\n'
        ;;
    release)
        case "${2:-}" in
            view)
                if [[ "$*" == *'then "complete"'* ]]; then
                    printf 'complete\n'
                elif [[ "$*" == *'digest else'* ]]; then
                    printf '<appcast>candidate</appcast>\n' \
                        | shasum -a 256 \
                        | awk '{print "sha256:" $1}'
                else
                    printf 'unexpected fake gh release view invocation\n' >&2
                    exit 97
                fi
                ;;
            *)
                printf 'unexpected fake gh release invocation\n' >&2
                exit 97
                ;;
        esac
        ;;
    *)
        printf 'unexpected fake gh invocation\n' >&2
        exit 97
        ;;
esac
SCRIPT

cat > "$ORCHESTRATION_BIN/xcrun" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'xcrun'
    printf ' <%s>' "$@"
    printf '\n'
} >> "${RELEASE_DRIVER_TEST_TRACE:?}"
case "${1:-}" in
    notarytool)
        exit 0
        ;;
    xcresulttool)
        printf '{"testsPassed":1,"testsFailed":0}\n'
        ;;
    xctest)
        printf 'xcrun-env <CLAUDEUSAGE_RUN_LIVE_AGY_TESTS=%s>\n' \
            "${CLAUDEUSAGE_RUN_LIVE_AGY_TESTS:-}" \
            >> "${RELEASE_DRIVER_TEST_TRACE:?}"
        test_bundle="${@: -1}"
        [[ "$CLAUDEUSAGE_RUN_LIVE_AGY_TESTS" == "1" ]]
        [[ -d "$test_bundle" ]]
        ;;
    *)
        exit 97
        ;;
esac
SCRIPT

cat > "$ORCHESTRATION_BIN/xcodebuild" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'xcodebuild'
    printf ' <%s>' "$@"
    printf '\n'
    printf 'xcodebuild-env <TMPDIR=%s>\n' "${TMPDIR:?}"
} >> "${RELEASE_DRIVER_TEST_TRACE:?}"
case "$TMPDIR" in
    "${RELEASE_DRIVER_TEST_SANDBOX_ROOT:?}"/tmp/claudeusage-release-driver.*/tmp) ;;
    *) exit 98 ;;
esac
if [[ "${RELEASE_DRIVER_TEST_XCODEBUILD_FAIL:-0}" == "1" ]]; then
    exit 42
fi
derived_data=""
result_bundle=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -derivedDataPath)
            derived_data="$2"
            shift 2
            ;;
        -resultBundlePath)
            result_bundle="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done
[[ -n "$derived_data" && -n "$result_bundle" ]]
mkdir -p \
    "$derived_data/Build/Products/Debug/ClaudeUsageTests.xctest" \
    "$result_bundle"
SCRIPT

cat > "$ORCHESTRATION_BIN/codesign" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT

cat > "$ORCHESTRATION_BIN/sleep" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'sleep'
    printf ' <%s>' "$@"
    printf '\n'
} >> "${RELEASE_DRIVER_TEST_TRACE:?}"
SCRIPT

chmod +x \
    "$ORCHESTRATION_REPOSITORY/Scripts/tests/release-driver-tests.sh" \
    "$ORCHESTRATION_REPOSITORY/Scripts/verify-release-artifact.sh" \
    "$ORCHESTRATION_REPOSITORY/Scripts/build-notarize-release.sh" \
    "$ORCHESTRATION_REPOSITORY/Scripts/publish-release.sh" \
    "$ORCHESTRATION_REPOSITORY/Scripts/publish-pages-appcast.sh" \
    "$ORCHESTRATION_BIN/git" \
    "$ORCHESTRATION_BIN/gh" \
    "$ORCHESTRATION_BIN/xcrun" \
    "$ORCHESTRATION_BIN/xcodebuild" \
    "$ORCHESTRATION_BIN/codesign" \
    "$ORCHESTRATION_BIN/sleep"

SCENARIO_OUTPUT=""
SCENARIO_STATUS=0
SCENARIO_TRACE=""

run_orchestration_scenario() {
    local candidate_mode="$1"
    local staging_release_tag="$2"
    local staging_feed_state="$3"
    local staging_feed_state_after="$4"
    local xcodebuild_fail="${5:-0}"
    local pages_sequence="${6:-built}"
    local bootstrap_version="${7:-2.4.0}"

    rm -rf "$ORCHESTRATION_TMP" "$ORCHESTRATION_DOWNLOADS"
    mkdir -p "$ORCHESTRATION_TMP" "$ORCHESTRATION_DOWNLOADS"
    : > "$ORCHESTRATION_TRACE"
    printf 'nathan-glorang\n' > "$ORCHESTRATION_ACCOUNT"
    rm -f "$ORCHESTRATION_FEED_SWITCH" "$ORCHESTRATION_PAGES_STATE"

    set +e
    SCENARIO_OUTPUT="$(
        env \
            "PATH=$ORCHESTRATION_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
            "TMPDIR=$ORCHESTRATION_TMP" \
            "DOWNLOADS_APP_PATH=$ORCHESTRATION_DOWNLOADS/ClaudeUsage-stg.app" \
            "RELEASE_DRIVER_TEST_MODE=1" \
            "RELEASE_DRIVER_TEST_EXECUTE=1" \
            "RELEASE_DRIVER_TEST_SANDBOX_ROOT=$ORCHESTRATION_ROOT" \
            "RELEASE_DRIVER_TEST_BIN_DIR=$ORCHESTRATION_BIN" \
            "RELEASE_DRIVER_ROOT_DIR=$ORCHESTRATION_REPOSITORY" \
            "RELEASE_DRIVER_TEST_TRACE=$ORCHESTRATION_TRACE" \
            "RELEASE_DRIVER_TEST_ACCOUNT_FILE=$ORCHESTRATION_ACCOUNT" \
            "RELEASE_DRIVER_TEST_FEED_SWITCH_FILE=$ORCHESTRATION_FEED_SWITCH" \
            "RELEASE_DRIVER_TEST_PAGES_STATE_FILE=$ORCHESTRATION_PAGES_STATE" \
            "RELEASE_DRIVER_TEST_PAGES_SEQUENCE=$pages_sequence" \
            "RELEASE_DRIVER_TEST_CANDIDATE_MODE=$candidate_mode" \
            "RELEASE_DRIVER_TEST_HEAD=$ORCHESTRATION_HEAD" \
            "RELEASE_DRIVER_TEST_PAGES_HEAD=$ORCHESTRATION_PAGES_HEAD" \
            "RELEASE_DRIVER_TEST_XCODEBUILD_FAIL=$xcodebuild_fail" \
            "RELEASE_DRIVER_TEST_STAGING_IDENTITY_BOOTSTRAP_VERSION=$bootstrap_version" \
            "RELEASE_DRIVER_TEST_EXPECTED_FEED=https://choseongmin1128.github.io/claude-usage/channels/staging/appcast.xml" \
            "RELEASE_DRIVER_TEST_PROD_TAG=v2.3.3" \
            "RELEASE_DRIVER_TEST_STAGING_TAG=$staging_release_tag" \
            $'RELEASE_DRIVER_TEST_PROD_FEED_STATE=2.3.3\t20330\tv2.3.3' \
            "RELEASE_DRIVER_TEST_STAGING_FEED_STATE=$staging_feed_state" \
            "RELEASE_DRIVER_TEST_STAGING_FEED_STATE_AFTER=$staging_feed_state_after" \
            "ARCHIVE_PATH=$ORCHESTRATION_ROOT/hostile-override/archive.xcarchive" \
            "ZIP_PATH=$ORCHESTRATION_ROOT/hostile-override/escape.zip" \
            "DMG_PATH=$ORCHESTRATION_ROOT/hostile-override/escape.dmg" \
            "PROJECT_PATH=$ORCHESTRATION_ROOT/hostile-override/Escape.xcodeproj" \
            "XC_CONFIG_PATH=$ORCHESTRATION_ROOT/hostile-override/Escape.xcconfig" \
            "LOCAL_XC_CONFIG_PATH=$ORCHESTRATION_ROOT/hostile-override/Escape.local.xcconfig" \
            "GHPAGES_BRANCH=hostile-pages" \
            "SU_FEED_URL=https://hostile.invalid/appcast.xml" \
            "DOWNLOAD_BASE_URL=https://hostile.invalid/releases" \
            /bin/bash "$ROOT_DIR/Scripts/release.sh" \
            stg 2.4.0 \
            --non-interactive \
            --confirm-publish v2.4.0-staging \
            2>&1
    )"
    SCENARIO_STATUS=$?
    set -e
    SCENARIO_TRACE="$(cat "$ORCHESTRATION_TRACE")"
}

assert_no_destructive_release_commands() {
    local trace="$1"
    local label="$2"

    assert_not_contains "$trace" "<--force>" "$label force"
    assert_not_contains "$trace" "<--delete>" "$label delete option"
    assert_not_contains "$trace" "git <tag> <-d>" "$label tag delete"
    assert_not_contains "$trace" "git <push> <-d>" "$label remote tag delete"
    assert_not_contains "$trace" "gh <release> <edit>" "$label release edit"
    assert_not_contains "$trace" "gh <release> <delete>" "$label release delete"
    assert_not_contains "$trace" "gh <release> <upload>" "$label release upload"
    assert_not_contains "$trace" "<--clobber>" "$label release clobber"
}

assert_orchestration_cleanup() {
    local label="$1"

    assert_equal "nathan-glorang" "$(cat "$ORCHESTRATION_ACCOUNT")" "$label account restore"
    assert_equal "" "$(find "$ORCHESTRATION_TMP" -mindepth 1 -print -quit)" "$label temp cleanup"
}

run_orchestration_scenario \
    fresh \
    v2.3.3-staging \
    $'2.3.3\t20330\tv2.3.3-staging' \
    $'2.4.0\t20400\tv2.4.0-staging'
assert_equal "0" "$SCENARIO_STATUS" "fresh staging actual path"
assert_contains "$SCENARIO_OUTPUT" "candidate metadata state: fresh" "fresh state output"
assert_contains "$SCENARIO_OUTPUT" "배포 및 원격 검증 완료" "fresh completion output"
assert_contains "$SCENARIO_TRACE" "gate <release-driver-shell-tests>" "fresh shell gate"
assert_contains "$SCENARIO_TRACE" "xcodebuild <-project>" "fresh XCTest"
assert_contains "$SCENARIO_TRACE" "xcodebuild-env <TMPDIR=$ORCHESTRATION_TMP/claudeusage-release-driver." "fresh XCTest TMPDIR is isolated"
assert_contains "$SCENARIO_TRACE" "/tmp>" "fresh XCTest uses RUN_ROOT tmp"
assert_contains "$SCENARIO_TRACE" "xcrun <xctest> <-XCTest> <AntigravityLiveAGYIntegrationTests/testProductionManagedPathReturnsRealGroupedQuota>" "fresh live AGY smoke"
assert_contains "$SCENARIO_TRACE" "xcrun-env <CLAUDEUSAGE_RUN_LIVE_AGY_TESTS=1>" "fresh live AGY opt-in"
assert_contains "$SCENARIO_OUTPUT" "staging 전환:     2.4.0 식별자 최초 배포" "fresh identity bootstrap output"
assert_not_contains "$SCENARIO_TRACE" "verify <--tag> <v2.3.3-staging>" "fresh legacy staging verification skipped"
assert_not_contains "$SCENARIO_TRACE" "<--install-to>" "fresh legacy staging install skipped"
assert_contains "$SCENARIO_TRACE" "build <BUILD_DIR=$ORCHESTRATION_TMP/" "fresh isolated build"
assert_contains "$SCENARIO_TRACE" "<ARCHIVE_PATH=$ORCHESTRATION_TMP/" "fresh archive is isolated"
assert_contains "$SCENARIO_TRACE" "/build/ClaudeUsage.xcarchive>" "fresh archive has canonical name"
assert_contains "$SCENARIO_TRACE" "<ZIP_PATH=$ORCHESTRATION_TMP/" "fresh ZIP is isolated"
assert_contains "$SCENARIO_TRACE" "/build/ClaudeUsage.zip>" "fresh ZIP has canonical name"
assert_contains "$SCENARIO_TRACE" "<DMG_PATH=$ORCHESTRATION_TMP/" "fresh DMG is isolated"
assert_contains "$SCENARIO_TRACE" "/build/ClaudeUsage.dmg>" "fresh DMG has canonical name"
assert_contains "$SCENARIO_TRACE" "<PROJECT_PATH=$ORCHESTRATION_REPOSITORY/ClaudeUsage.xcodeproj>" "fresh project path is pinned"
assert_contains "$SCENARIO_TRACE" "<XC_CONFIG_PATH=$ORCHESTRATION_REPOSITORY/Config/Release.xcconfig>" "fresh release config is pinned"
assert_contains "$SCENARIO_TRACE" "<LOCAL_XC_CONFIG_PATH=$ORCHESTRATION_REPOSITORY/Config/Sparkle.release.local.xcconfig>" "fresh local config is pinned"
assert_contains "$SCENARIO_TRACE" "<ENTITLEMENTS_PATH=$ORCHESTRATION_REPOSITORY/ClaudeUsage/ClaudeUsage.entitlements>" "fresh entitlements are pinned"
assert_contains "$SCENARIO_TRACE" "<SU_FEED_URL=https://choseongmin1128.github.io/claude-usage/channels/staging/appcast.xml>" "fresh build feed is pinned"
assert_contains "$SCENARIO_TRACE" "<SIGNING_REFERENCE_APP=$ORCHESTRATION_ROOT/Applications/ClaudeUsage.app>" "fresh signing reference uses production Applications app"
assert_contains "$SCENARIO_TRACE" "publish-env <BUILD_DIR=$ORCHESTRATION_TMP/" "fresh publish build is isolated"
assert_contains "$SCENARIO_TRACE" "<APPCAST_PATH=$ORCHESTRATION_TMP/" "fresh publish appcast is isolated"
assert_contains "$SCENARIO_TRACE" "<DOWNLOAD_BASE_URL=https://github.com/ChoSeongmin1128/claude-usage/releases/download/v2.4.0-staging>" "fresh publish download URL is pinned"
assert_contains "$SCENARIO_TRACE" "pages-env <GHPAGES_BRANCH=gh-pages>" "fresh Pages branch is pinned"
assert_not_contains "$SCENARIO_TRACE" "hostile-override" "fresh hostile filesystem overrides"
assert_not_contains "$SCENARIO_TRACE" "hostile.invalid" "fresh hostile URL overrides"
assert_not_contains "$SCENARIO_TRACE" "hostile-pages" "fresh hostile Pages branch"
assert_contains "$SCENARIO_TRACE" "publish <v2.4.0-staging> <--channel> <staging> <--expected-commit> <$ORCHESTRATION_HEAD> <--skip-pages-publish> <--prerelease>" "fresh two-phase prerelease publish"
assert_not_contains "$SCENARIO_TRACE" "<--resume-exact-tag>" "fresh resume flag"
assert_contains "$SCENARIO_TRACE" "verify-export <verified-candidate-appcast>" "fresh verified appcast export"
assert_contains "$SCENARIO_TRACE" "pages-source <verified-candidate-appcast>" "fresh verified Pages source"
assert_contains "$SCENARIO_TRACE" "verify <--tag> <v2.4.0-staging> <--channel> <staging> <--expected-version> <2.4.0> <--expected-build> <20400> <--verify-public-feed>" "fresh final public verification"
assert_ordered "$SCENARIO_TRACE" "gate <release-driver-shell-tests>" "xcodebuild <-project>" "fresh shell tests before XCTest"
assert_ordered "$SCENARIO_TRACE" "xcodebuild <-project>" "xcrun <xctest>" "fresh XCTest before live AGY"
assert_ordered "$SCENARIO_TRACE" "xcrun <xctest>" "build <BUILD_DIR=" "fresh live AGY before build"
assert_ordered "$SCENARIO_TRACE" "publish <v2.4.0-staging>" "verify-export <verified-candidate-appcast>" "fresh Release before candidate verification"
assert_ordered "$SCENARIO_TRACE" "verify-export <verified-candidate-appcast>" "pages-source <verified-candidate-appcast>" "fresh verification before Pages"
assert_ordered "$SCENARIO_TRACE" "pages-source <verified-candidate-appcast>" "verify <--tag> <v2.4.0-staging> <--channel> <staging> <--expected-version> <2.4.0> <--expected-build> <20400> <--verify-public-feed>" "fresh Pages before final public verification"
assert_line_count "$SCENARIO_TRACE" "gh <api> <--method> <POST> <repos/ChoSeongmin1128/claude-usage/pages/builds>" "1" "fresh forced Pages rebuild"
[[ ! -e "$ORCHESTRATION_DOWNLOADS/ClaudeUsage-stg.app" ]] \
    || fail "식별자 최초 staging이 구 번들 앱을 Downloads fixture에 두었습니다."
pass
[[ ! -e "$ORCHESTRATION_ROOT/hostile-override" ]] \
    || fail "fresh staging이 hostile override 대상에 파일을 생성했습니다."
pass
assert_orchestration_cleanup "fresh"
assert_no_destructive_release_commands "$SCENARIO_TRACE" "fresh"

run_orchestration_scenario \
    fresh \
    v2.3.3-staging \
    $'2.3.3\t20330\tv2.3.3-staging' \
    $'2.4.0\t20400\tv2.4.0-staging' \
    0 \
    built \
    2.3.0
assert_equal "0" "$SCENARIO_STATUS" "same-identity upgrade actual path"
assert_contains "$SCENARIO_TRACE" "verify <--tag> <v2.3.3-staging>" "same-identity previous artifact verification"
assert_contains "$SCENARIO_TRACE" "<--install-to> <$ORCHESTRATION_DOWNLOADS/ClaudeUsage-stg.app>" "same-identity temporary upgrade app"
assert_contains "$SCENARIO_TRACE" "<SIGNING_REFERENCE_APP=$ORCHESTRATION_DOWNLOADS/ClaudeUsage-stg.app>" "same-identity signing reference"
[[ ! -e "$ORCHESTRATION_DOWNLOADS/ClaudeUsage-stg.app" ]] \
    || fail "same-identity upgrade 앱이 driver 종료 후 Downloads fixture에 남았습니다."
pass
assert_contains "$SCENARIO_OUTPUT" "배포 중 준비한 Downloads 앱은 종료 시 삭제합니다." "same-identity cleanup output"
assert_orchestration_cleanup "same-identity upgrade"
assert_no_destructive_release_commands "$SCENARIO_TRACE" "same-identity upgrade"

run_orchestration_scenario \
    tag_only \
    v2.3.3-staging \
    $'2.3.3\t20330\tv2.3.3-staging' \
    $'2.4.0\t20400\tv2.4.0-staging'
assert_equal "0" "$SCENARIO_STATUS" "tag-only actual path"
assert_contains "$SCENARIO_OUTPUT" "candidate metadata state: tag_only" "tag-only state output"
assert_contains "$SCENARIO_TRACE" "publish <v2.4.0-staging> <--channel> <staging> <--expected-commit> <$ORCHESTRATION_HEAD> <--skip-pages-publish> <--prerelease> <--resume-exact-tag>" "tag-only two-phase exact resume publish"
assert_contains "$SCENARIO_TRACE" "build <BUILD_DIR=$ORCHESTRATION_TMP/" "tag-only build"
assert_not_contains "$SCENARIO_TRACE" "verify <--tag> <v2.3.3-staging>" "tag-only legacy staging verification skipped"
assert_ordered "$SCENARIO_TRACE" "publish <v2.4.0-staging>" "verify-export <verified-candidate-appcast>" "tag-only Release before candidate verification"
assert_ordered "$SCENARIO_TRACE" "verify-export <verified-candidate-appcast>" "pages-source <verified-candidate-appcast>" "tag-only verification before Pages"
assert_ordered "$SCENARIO_TRACE" "pages-source <verified-candidate-appcast>" "verify <--tag> <v2.4.0-staging> <--channel> <staging> <--expected-version> <2.4.0> <--expected-build> <20400> <--verify-public-feed>" "tag-only Pages before final public verification"
assert_line_count "$SCENARIO_TRACE" "gh <api> <--method> <POST> <repos/ChoSeongmin1128/claude-usage/pages/builds>" "1" "tag-only forced Pages rebuild"
assert_orchestration_cleanup "tag-only"
assert_no_destructive_release_commands "$SCENARIO_TRACE" "tag-only"

run_orchestration_scenario \
    pages_pending \
    v2.4.0-staging \
    $'2.3.3\t20330\tv2.3.3-staging' \
    $'2.4.0\t20400\tv2.4.0-staging'
assert_equal "0" "$SCENARIO_STATUS" "pages-pending actual path"
assert_contains "$SCENARIO_OUTPUT" "candidate metadata state: pages_pending" "pages-pending state output"
assert_contains "$SCENARIO_OUTPUT" "부분 배포 복구 및 원격 검증 완료" "pages-pending completion"
assert_contains "$SCENARIO_TRACE" "verify <--tag> <v2.4.0-staging> <--channel> <staging> <--expected-version> <2.4.0> <--expected-build> <20400> <--export-verified-appcast-to>" "pages-pending candidate export verification"
assert_not_contains "$SCENARIO_TRACE" "verify <--tag> <v2.3.3-staging>" "pages-pending legacy feed verification skipped"
assert_contains "$SCENARIO_TRACE" "pages-publish <--feed-url>" "pages-pending Pages repair"
assert_contains "$SCENARIO_TRACE" "pages-source <verified-candidate-appcast>" "pages-pending verified Pages source"
assert_ordered "$SCENARIO_TRACE" "verify-export <verified-candidate-appcast>" "pages-source <verified-candidate-appcast>" "pages-pending verification before Pages"
assert_ordered "$SCENARIO_TRACE" "pages-source <verified-candidate-appcast>" "verify <--tag> <v2.4.0-staging> <--channel> <staging> <--expected-version> <2.4.0> <--expected-build> <20400> <--verify-public-feed>" "pages-pending Pages before final public verification"
assert_not_contains "$SCENARIO_TRACE" "gh <release> <download>" "pages-pending direct Release download removed"
assert_line_count "$SCENARIO_TRACE" "gh <api> <--method> <POST> <repos/ChoSeongmin1128/claude-usage/pages/builds>" "1" "built stale Pages forced rebuild"
assert_not_contains "$SCENARIO_TRACE" "gate <release-driver-shell-tests>" "pages-pending shell tests skipped"
assert_not_contains "$SCENARIO_TRACE" "xcodebuild <-project>" "pages-pending XCTest skipped"
assert_not_contains "$SCENARIO_TRACE" "build <BUILD_DIR=" "pages-pending build skipped"
assert_not_contains "$SCENARIO_TRACE" "publish <v2.4.0-staging>" "pages-pending release publish skipped"
assert_not_contains "$SCENARIO_TRACE" "<--install-to>" "pages-pending Downloads install skipped"
assert_orchestration_cleanup "pages-pending"
assert_no_destructive_release_commands "$SCENARIO_TRACE" "pages-pending"

run_orchestration_scenario \
    pages_pending \
    v2.4.0-staging \
    $'2.3.3\t20330\tv2.3.3-staging' \
    $'2.4.0\t20400\tv2.4.0-staging' \
    0 \
    queued_errored
assert_equal "0" "$SCENARIO_STATUS" "queued-to-errored Pages retry path"
assert_ordered "$SCENARIO_TRACE" "pages-state <queued>" "pages-state <errored>" "queued Pages becomes errored"
assert_ordered "$SCENARIO_TRACE" "pages-state <errored>" "pages-state <built>" "errored Pages rebuild completes"
assert_line_count "$SCENARIO_TRACE" "gh <api> <--method> <POST> <repos/ChoSeongmin1128/claude-usage/pages/builds>" "1" "errored Pages bounded POST retry"
assert_contains "$SCENARIO_TRACE" "sleep <5>" "errored Pages bounded poll"
assert_contains "$SCENARIO_TRACE" "pages-source <verified-candidate-appcast>" "errored retry verified Pages source"
assert_not_contains "$SCENARIO_TRACE" "gh <release> <download>" "errored retry direct Release download removed"
assert_orchestration_cleanup "queued-to-errored"
assert_no_destructive_release_commands "$SCENARIO_TRACE" "queued-to-errored"

run_orchestration_scenario \
    complete \
    v2.4.0-staging \
    $'2.4.0\t20400\tv2.4.0-staging' \
    $'2.4.0\t20400\tv2.4.0-staging'
assert_equal "0" "$SCENARIO_STATUS" "complete actual path"
assert_contains "$SCENARIO_OUTPUT" "candidate metadata state: complete" "complete state output"
assert_contains "$SCENARIO_OUTPUT" "기존 배포 원격 검증 완료" "complete verification output"
assert_contains "$SCENARIO_TRACE" "verify <--tag> <v2.4.0-staging>" "complete remote verification"
assert_not_contains "$SCENARIO_TRACE" "pages-publish" "complete Pages skipped"
assert_not_contains "$SCENARIO_TRACE" "gate <release-driver-shell-tests>" "complete shell tests skipped"
assert_not_contains "$SCENARIO_TRACE" "xcodebuild <-project>" "complete XCTest skipped"
assert_not_contains "$SCENARIO_TRACE" "build <BUILD_DIR=" "complete build skipped"
assert_not_contains "$SCENARIO_TRACE" "publish <v2.4.0-staging>" "complete publish skipped"
assert_not_contains "$SCENARIO_TRACE" "<--install-to>" "complete Downloads install skipped"
assert_orchestration_cleanup "complete"
assert_no_destructive_release_commands "$SCENARIO_TRACE" "complete"

run_orchestration_scenario \
    fresh \
    v2.3.3-staging \
    $'2.3.3\t20330\tv2.3.3-staging' \
    $'2.4.0\t20400\tv2.4.0-staging' \
    1
[[ "$SCENARIO_STATUS" -ne 0 ]] || fail "XCTest failure scenario는 실패해야 합니다."
pass
assert_contains "$SCENARIO_TRACE" "xcodebuild <-project>" "failure reaches XCTest"
assert_not_contains "$SCENARIO_TRACE" "verify <--tag> <v2.3.3-staging>" "failure stops before Downloads verification"
assert_not_contains "$SCENARIO_TRACE" "build <BUILD_DIR=" "failure stops before build"
assert_not_contains "$SCENARIO_TRACE" "publish <v2.4.0-staging>" "failure stops before publish"
[[ ! -e "$ORCHESTRATION_DOWNLOADS/ClaudeUsage-stg.app" ]] \
    || fail "XCTest failure가 Downloads fixture를 변경했습니다."
pass
assert_orchestration_cleanup "failure"
assert_no_destructive_release_commands "$SCENARIO_TRACE" "failure"

PUBLISH_FIXTURE_ROOT="$TEST_ROOT/publish-primitive"
PUBLISH_REPOSITORY="$PUBLISH_FIXTURE_ROOT/ClaudeUsage"
PUBLISH_BUILD="$PUBLISH_REPOSITORY/build/release"
PUBLISH_BIN="$PUBLISH_FIXTURE_ROOT/bin"
PUBLISH_TMP="$PUBLISH_FIXTURE_ROOT/tmp"
PUBLISH_STATE="$PUBLISH_FIXTURE_ROOT/state"
PUBLISH_CALLER_CWD="$PUBLISH_FIXTURE_ROOT/unrelated-caller"
PUBLISH_TRACE="$PUBLISH_STATE/commands.log"
PUBLISH_SCRIPT="$PUBLISH_REPOSITORY/Scripts/publish-release.sh"
PUBLISH_EXPECTED_SHA="3333333333333333333333333333333333333333"
PUBLISH_OTHER_SHA="4444444444444444444444444444444444444444"
PUBLISH_PUBLIC_KEY="11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="
PUBLISH_VALID_SIGNATURE="5VZDAMNgrHKQhuLMgG6CioSHfx645dl02HPgZSJJAVVfuIIVkKM7rMYeOXAc+bRr0lv18FlbviRlUUFDjnoQCw=="
mkdir -p \
    "$PUBLISH_REPOSITORY/Scripts/lib" \
    "$PUBLISH_REPOSITORY/Config" \
    "$PUBLISH_REPOSITORY/ClaudeUsage.xcodeproj" \
    "$PUBLISH_BUILD" \
    "$PUBLISH_BIN" \
    "$PUBLISH_TMP" \
    "$PUBLISH_STATE" \
    "$PUBLISH_CALLER_CWD"
cp "$ROOT_DIR/Scripts/publish-release.sh" "$PUBLISH_SCRIPT"
cp \
    "$ROOT_DIR/Scripts/lib/release-driver-common.sh" \
    "$PUBLISH_REPOSITORY/Scripts/lib/release-driver-common.sh"
cp \
    "$ROOT_DIR/Scripts/verify-sparkle-signature.swift" \
    "$PUBLISH_REPOSITORY/Scripts/verify-sparkle-signature.swift"
chmod +x "$PUBLISH_SCRIPT"

cat > "$PUBLISH_REPOSITORY/Config/Release.xcconfig" <<EOF
SUPublicEDKey = $PUBLISH_PUBLIC_KEY
EOF
cat > "$PUBLISH_REPOSITORY/ClaudeUsage.xcodeproj/project.pbxproj" <<'PBX'
{
    MARKETING_VERSION = 2.4.0;
    CURRENT_PROJECT_VERSION = 20400;
    MARKETING_VERSION = 2.4.0;
    CURRENT_PROJECT_VERSION = 20400;
}
PBX
: > "$PUBLISH_BUILD/ClaudeUsage.dmg"
: > "$PUBLISH_BUILD/ClaudeUsage.zip"

cat > "$PUBLISH_REPOSITORY/Scripts/generate-sparkle-appcast.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
download_base_url=""
release_tag=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --download-base-url)
            download_base_url="$2"
            shift 2
            ;;
        --tag)
            release_tag="$2"
            shift 2
            ;;
        --feed-url)
            shift 2
            ;;
        *)
            exit 97
            ;;
    esac
done
[[ -n "$download_base_url" && -n "$release_tag" ]]
{
    printf 'generator'
    printf ' <cwd-name=%s>' "${PWD##*/}"
    printf ' <mode=%s>' "${PUBLISH_FIXTURE_APPCAST_MODE:-valid}"
    printf ' <tag=%s>' "$release_tag"
    printf ' <output=%s>\n' "${APPCAST_OUTPUT:?}"
} >> "${PUBLISH_FIXTURE_TRACE:?}"
version="${release_tag#v}"
version="${version%-staging}"
enclosure_url="${download_base_url%/}/ClaudeUsage.zip"
length="$(stat -f%z "${ARTIFACTS_DIR:?}/ClaudeUsage.zip")"
signature="${PUBLISH_FIXTURE_VALID_SIGNATURE:?}"
case "${PUBLISH_FIXTURE_APPCAST_MODE:-valid}" in
    valid)
        ;;
    bad_length)
        length=$((length + 1))
        ;;
    bad_enclosure)
        enclosure_url="https://invalid.example/ClaudeUsage.zip"
        ;;
    bad_signature)
        signature="6VZDAMNgrHKQhuLMgG6CioSHfx645dl02HPgZSJJAVVfuIIVkKM7rMYeOXAc+bRr0lv18FlbviRlUUFDjnoQCw=="
        ;;
    *)
        exit 97
        ;;
esac
printf '%s\n' \
    "<rss xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\"><channel><item><sparkle:shortVersionString>$version</sparkle:shortVersionString><sparkle:version>20400</sparkle:version><enclosure url=\"$enclosure_url\" length=\"$length\" sparkle:edSignature=\"$signature\" /></item></channel></rss>" \
    > "${APPCAST_OUTPUT:?}"
SCRIPT

cat > "$PUBLISH_BIN/git" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'git'
    printf ' <cwd=%s>' "$PWD"
    printf ' <%s>' "$@"
    printf '\n'
} >> "${PUBLISH_FIXTURE_TRACE:?}"
if [[ "${1:-}" == "-C" ]]; then
    shift 2
fi
case "${1:-}" in
    config)
        printf 'git@github.com:FixtureOwner/ClaudeUsage.git\n'
        ;;
    rev-parse)
        case "${2:-}" in
            HEAD)
                printf '%s\n' "${PUBLISH_FIXTURE_HEAD:?}"
                ;;
            refs/tags/*)
                exit 1
                ;;
            *)
                exit 97
                ;;
        esac
        ;;
    branch)
        [[ "${2:-}" == "--show-current" ]]
        printf 'main\n'
        ;;
    ls-remote)
        if [[ "${2:-}" == "--tags" ]]; then
            exit 0
        fi
        if [[ "${2:-}" == "origin" && "${3:-}" == "refs/heads/main" ]]; then
            printf '%s\trefs/heads/main\n' "${PUBLISH_FIXTURE_ORIGIN_MAIN:?}"
            exit 0
        fi
        exit 97
        ;;
    status)
        exit 0
        ;;
    tag)
        {
            printf 'mutation <git-tag>'
            printf ' <%s>' "$@"
            printf '\n'
        } >> "${PUBLISH_FIXTURE_TRACE:?}"
        ;;
    push)
        {
            printf 'mutation <git-push>'
            printf ' <%s>' "$@"
            printf '\n'
        } >> "${PUBLISH_FIXTURE_TRACE:?}"
        ;;
    *)
        exit 97
        ;;
esac
SCRIPT

cat > "$PUBLISH_BIN/gh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'gh'
    printf ' <cwd-name=%s>' "${PWD##*/}"
    printf ' <%s>' "$@"
    printf '\n'
} >> "${PUBLISH_FIXTURE_TRACE:?}"
case "${1:-}" in
    auth)
        [[ "${2:-}" == "status" ]]
        ;;
    repo)
        [[ "${2:-}" == "view" ]]
        printf 'FixtureOwner/ClaudeUsage\n'
        ;;
    api)
        if [[ "$*" == *"/pages/"* ]]; then
            printf 'mutation <pages-api>\n' >> "${PUBLISH_FIXTURE_TRACE:?}"
            exit 97
        fi
        if [[ "${2:-}" == "repos/FixtureOwner/ClaudeUsage/releases/tags/"* ]]; then
            printf 'gh: Not Found (HTTP 404)\n' >&2
            exit 1
        fi
        exit 97
        ;;
    release)
        case "${2:-}" in
            create)
                {
                    printf 'mutation <release-create>'
                    printf ' <%s>' "${@:3}"
                    printf '\n'
                } >> "${PUBLISH_FIXTURE_TRACE:?}"
                printf 'https://github.com/FixtureOwner/ClaudeUsage/releases/tag/%s\n' "${3:-}"
                ;;
            view)
                printf 'https://github.com/FixtureOwner/ClaudeUsage/releases/tag/%s\n' "${3:-}"
                ;;
            *)
                exit 97
                ;;
        esac
        ;;
    *)
        exit 97
        ;;
esac
SCRIPT

cat > "$PUBLISH_BIN/xcrun" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'signature-verify'
    printf ' <cwd-name=%s>' "${PWD##*/}"
    printf ' <%s>' "$@"
    printf '\n'
} >> "${PUBLISH_FIXTURE_TRACE:?}"
[[ "${1:-}" == "swift" ]]
shift
/usr/bin/xcrun swift "$@"
SCRIPT

chmod +x \
    "$PUBLISH_REPOSITORY/Scripts/generate-sparkle-appcast.sh" \
    "$PUBLISH_BIN/git" \
    "$PUBLISH_BIN/gh" \
    "$PUBLISH_BIN/xcrun"

PUBLISH_CASE_OUTPUT=""
PUBLISH_CASE_STATUS=0
PUBLISH_CASE_TRACE=""

run_publish_primitive_case() {
    local appcast_mode="$1"
    local head_sha="$2"
    local origin_main_sha="$3"
    shift 3

    : > "$PUBLISH_TRACE"
    rm -f "$PUBLISH_BUILD/appcast.xml"
    find "$PUBLISH_BUILD" \
        -maxdepth 1 \
        -name '.publish-sparkle-verify.*' \
        -exec rm -rf {} +

    set +e
    PUBLISH_CASE_OUTPUT="$(
        cd "$PUBLISH_CALLER_CWD"
        env \
            "PATH=$PUBLISH_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
            "TMPDIR=$PUBLISH_TMP" \
            "BUILD_DIR=$PUBLISH_BUILD" \
            "PUBLISH_FIXTURE_TRACE=$PUBLISH_TRACE" \
            "PUBLISH_FIXTURE_HEAD=$head_sha" \
            "PUBLISH_FIXTURE_ORIGIN_MAIN=$origin_main_sha" \
            "PUBLISH_FIXTURE_APPCAST_MODE=$appcast_mode" \
            "PUBLISH_FIXTURE_VALID_SIGNATURE=$PUBLISH_VALID_SIGNATURE" \
            /bin/bash "$PUBLISH_SCRIPT" "$@" 2>&1
    )"
    PUBLISH_CASE_STATUS=$?
    set -e
    PUBLISH_CASE_TRACE="$(cat "$PUBLISH_TRACE")"
    [[ -z "$(
        find "$PUBLISH_BUILD" \
            -maxdepth 1 \
            -name '.publish-sparkle-verify.*' \
            -print \
            -quit
    )" ]] || fail "publish primitive가 검증 cache를 남겼습니다."
}

assert_no_publish_mutation() {
    local label="$1"
    assert_not_contains "$PUBLISH_CASE_TRACE" "mutation <git-tag>" "$label tag mutation"
    assert_not_contains "$PUBLISH_CASE_TRACE" "mutation <git-push>" "$label push mutation"
    assert_not_contains "$PUBLISH_CASE_TRACE" "mutation <release-create>" "$label release mutation"
    assert_not_contains "$PUBLISH_CASE_TRACE" "mutation <pages-api>" "$label Pages mutation"
}

run_publish_primitive_case \
    valid \
    "$PUBLISH_EXPECTED_SHA" \
    "$PUBLISH_EXPECTED_SHA" \
    v2.4.0-staging \
    --channel staging \
    --prerelease \
    --expected-commit "$PUBLISH_EXPECTED_SHA" \
    --skip-pages-publish
assert_equal "0" "$PUBLISH_CASE_STATUS" "actual staging publish primitive"
assert_contains "$PUBLISH_CASE_OUTPUT" "완료" "staging publish output"
assert_contains \
    "$PUBLISH_CASE_TRACE" \
    "mutation <git-tag> <tag> <-a> <v2.4.0-staging> <-m> <Release v2.4.0-staging> <$PUBLISH_EXPECTED_SHA>" \
    "staging tag pins explicit expected SHA"
assert_contains \
    "$PUBLISH_CASE_TRACE" \
    "mutation <release-create> <v2.4.0-staging> <--repo> <FixtureOwner/ClaudeUsage> <--title> <v2.4.0-staging> <--prerelease> <--generate-notes> <$PUBLISH_BUILD/ClaudeUsage.dmg> <$PUBLISH_BUILD/ClaudeUsage.zip> <$PUBLISH_BUILD/appcast.xml>" \
    "staging exact repository and three assets"
assert_contains \
    "$PUBLISH_CASE_TRACE" \
    "gh <cwd-name=unrelated-caller> <release> <create>" \
    "staging caller cwd differs while repo is explicit"
assert_ordered "$PUBLISH_CASE_TRACE" "generator <cwd-name=unrelated-caller>" "signature-verify <cwd-name=unrelated-caller>" "staging appcast before signature"
assert_ordered "$PUBLISH_CASE_TRACE" "signature-verify <cwd-name=unrelated-caller>" "mutation <git-tag>" "staging signature gate before tag"
assert_not_contains "$PUBLISH_CASE_TRACE" "mutation <pages-api>" "staging Pages mutation"

run_publish_primitive_case \
    valid \
    "$PUBLISH_EXPECTED_SHA" \
    "$PUBLISH_EXPECTED_SHA" \
    v2.4.0 \
    --channel prod \
    --expected-commit "$PUBLISH_EXPECTED_SHA" \
    --skip-pages-publish
assert_equal "0" "$PUBLISH_CASE_STATUS" "actual prod publish primitive"
assert_contains "$PUBLISH_CASE_OUTPUT" "완료" "prod publish output"
assert_contains \
    "$PUBLISH_CASE_TRACE" \
    "mutation <git-tag> <tag> <-a> <v2.4.0> <-m> <Release v2.4.0> <$PUBLISH_EXPECTED_SHA>" \
    "prod tag pins explicit expected SHA"
assert_contains \
    "$PUBLISH_CASE_TRACE" \
    "mutation <release-create> <v2.4.0> <--repo> <FixtureOwner/ClaudeUsage> <--title> <v2.4.0> <--generate-notes> <$PUBLISH_BUILD/ClaudeUsage.dmg> <$PUBLISH_BUILD/ClaudeUsage.zip> <$PUBLISH_BUILD/appcast.xml>" \
    "prod exact repository and three assets"
assert_not_contains "$PUBLISH_CASE_TRACE" "<--prerelease>" "prod non-prerelease release"
assert_not_contains "$PUBLISH_CASE_TRACE" "mutation <pages-api>" "prod Pages mutation"

PUBLISH_INVALID_CASES=(
    "staging_missing_prerelease"
    "staging_wrong_tag"
    "prod_with_prerelease"
    "invalid_channel"
    "draft"
    "skip_appcast_asset"
    "missing_expected_commit"
)
for invalid_case in "${PUBLISH_INVALID_CASES[@]}"; do
    case "$invalid_case" in
        staging_missing_prerelease)
            invalid_args=(
                v2.4.0-staging
                --channel staging
                --expected-commit "$PUBLISH_EXPECTED_SHA"
            )
            ;;
        staging_wrong_tag)
            invalid_args=(
                v2.4.0
                --channel staging
                --prerelease
                --expected-commit "$PUBLISH_EXPECTED_SHA"
            )
            ;;
        prod_with_prerelease)
            invalid_args=(
                v2.4.0
                --channel prod
                --prerelease
                --expected-commit "$PUBLISH_EXPECTED_SHA"
            )
            ;;
        invalid_channel)
            invalid_args=(
                v2.4.0
                --channel preview
                --expected-commit "$PUBLISH_EXPECTED_SHA"
            )
            ;;
        draft)
            invalid_args=(
                v2.4.0
                --channel prod
                --draft
                --expected-commit "$PUBLISH_EXPECTED_SHA"
            )
            ;;
        skip_appcast_asset)
            invalid_args=(
                v2.4.0
                --channel prod
                --skip-appcast-asset
                --expected-commit "$PUBLISH_EXPECTED_SHA"
            )
            ;;
        missing_expected_commit)
            invalid_args=(
                v2.4.0
                --channel prod
            )
            ;;
    esac
    run_publish_primitive_case \
        valid \
        "$PUBLISH_EXPECTED_SHA" \
        "$PUBLISH_EXPECTED_SHA" \
        "${invalid_args[@]}"
    [[ "$PUBLISH_CASE_STATUS" -ne 0 ]] \
        || fail "$invalid_case publish primitive는 실패해야 합니다."
    pass
    assert_no_publish_mutation "$invalid_case"
done

run_publish_primitive_case \
    valid \
    "$PUBLISH_OTHER_SHA" \
    "$PUBLISH_EXPECTED_SHA" \
    v2.4.0 \
    --channel prod \
    --expected-commit "$PUBLISH_EXPECTED_SHA"
[[ "$PUBLISH_CASE_STATUS" -ne 0 ]] || fail "expected HEAD mismatch는 실패해야 합니다."
pass
assert_no_publish_mutation "expected HEAD mismatch"

run_publish_primitive_case \
    valid \
    "$PUBLISH_EXPECTED_SHA" \
    "$PUBLISH_OTHER_SHA" \
    v2.4.0 \
    --channel prod \
    --expected-commit "$PUBLISH_EXPECTED_SHA"
[[ "$PUBLISH_CASE_STATUS" -ne 0 ]] || fail "origin/main mismatch는 실패해야 합니다."
pass
assert_no_publish_mutation "origin main mismatch"

for invalid_appcast_mode in bad_length bad_enclosure bad_signature; do
    run_publish_primitive_case \
        "$invalid_appcast_mode" \
        "$PUBLISH_EXPECTED_SHA" \
        "$PUBLISH_EXPECTED_SHA" \
        v2.4.0 \
        --channel prod \
        --expected-commit "$PUBLISH_EXPECTED_SHA"
    [[ "$PUBLISH_CASE_STATUS" -ne 0 ]] \
        || fail "$invalid_appcast_mode appcast gate는 실패해야 합니다."
    pass
    assert_no_publish_mutation "$invalid_appcast_mode appcast gate"
done
assert_contains "$PUBLISH_CASE_TRACE" "signature-verify <cwd-name=unrelated-caller>" "invalid signature reaches copied verifier"

CANONICAL_VERIFY_ROOT="$TEST_ROOT/canonical-verifier"
CANONICAL_VERIFY_REPOSITORY="$CANONICAL_VERIFY_ROOT/repository"
CANONICAL_VERIFY_BIN="$CANONICAL_VERIFY_ROOT/bin"
CANONICAL_VERIFY_STATE="$CANONICAL_VERIFY_ROOT/state"
CANONICAL_VERIFY_ASSETS="$CANONICAL_VERIFY_ROOT/assets"
CANONICAL_VERIFY_PHYSICAL_TMP="$CANONICAL_VERIFY_ROOT/physical-tmp"
CANONICAL_VERIFY_LOGICAL_TMP="$CANONICAL_VERIFY_ROOT/logical-tmp"
CANONICAL_VERIFY_TRACE="$CANONICAL_VERIFY_STATE/commands.log"
CANONICAL_VERIFY_MOUNT_STATE="$CANONICAL_VERIFY_STATE/mount-path"
CANONICAL_VERIFY_TEAM="ABCDE12345"
CANONICAL_VERIFY_PUBLIC_KEY="$PUBLISH_PUBLIC_KEY"
mkdir -p \
    "$CANONICAL_VERIFY_REPOSITORY/Scripts/lib" \
    "$CANONICAL_VERIFY_REPOSITORY/Config" \
    "$CANONICAL_VERIFY_REPOSITORY/ClaudeUsage.xcodeproj" \
    "$CANONICAL_VERIFY_BIN" \
    "$CANONICAL_VERIFY_STATE" \
    "$CANONICAL_VERIFY_ASSETS" \
    "$CANONICAL_VERIFY_PHYSICAL_TMP"
ln -s "$CANONICAL_VERIFY_PHYSICAL_TMP" "$CANONICAL_VERIFY_LOGICAL_TMP"
CANONICAL_VERIFY_PHYSICAL_TMP_P="$(
    cd "$CANONICAL_VERIFY_PHYSICAL_TMP"
    pwd -P
)"
cp \
    "$ROOT_DIR/Scripts/lib/release-driver-common.sh" \
    "$CANONICAL_VERIFY_REPOSITORY/Scripts/lib/release-driver-common.sh"
cp \
    "$ROOT_DIR/Scripts/verify-sparkle-signature.swift" \
    "$CANONICAL_VERIFY_REPOSITORY/Scripts/verify-sparkle-signature.swift"
sed \
    "s|/sbin/mount|$CANONICAL_VERIFY_BIN/mount|g" \
    "$ROOT_DIR/Scripts/verify-release-artifact.sh" \
    > "$CANONICAL_VERIFY_REPOSITORY/Scripts/verify-release-artifact.sh"
chmod +x "$CANONICAL_VERIFY_REPOSITORY/Scripts/verify-release-artifact.sh"

cat > "$CANONICAL_VERIFY_REPOSITORY/ClaudeUsage.xcodeproj/project.pbxproj" <<PBX
{
    DEVELOPMENT_TEAM = $CANONICAL_VERIFY_TEAM;
    DEVELOPMENT_TEAM = $CANONICAL_VERIFY_TEAM;
}
PBX
cat > "$CANONICAL_VERIFY_REPOSITORY/Config/Release.xcconfig" <<EOF
SUPublicEDKey = $CANONICAL_VERIFY_PUBLIC_KEY
EOF
cat > "$CANONICAL_VERIFY_STATE/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.seongmin.ClaudeUsage.staging</string>
    <key>CFBundleDisplayName</key>
    <string>ClaudeUsage-stg</string>
    <key>ClaudeUsageReleaseChannel</key>
    <string>staging</string>
    <key>CFBundleShortVersionString</key>
    <string>2.4.0</string>
    <key>CFBundleVersion</key>
    <string>20400</string>
    <key>SUFeedURL</key>
    <string>https://choseongmin1128.github.io/claude-usage/channels/staging/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>$CANONICAL_VERIFY_PUBLIC_KEY</string>
</dict>
</plist>
EOF
cat > "$CANONICAL_VERIFY_STATE/entitlements.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
EOF
printf 'dmg\n' > "$CANONICAL_VERIFY_ASSETS/ClaudeUsage.dmg"
printf 'zip\n' > "$CANONICAL_VERIFY_ASSETS/ClaudeUsage.zip"
CANONICAL_VERIFY_ZIP_SIZE="$(
    stat -f%z "$CANONICAL_VERIFY_ASSETS/ClaudeUsage.zip"
)"
cat > "$CANONICAL_VERIFY_ASSETS/appcast.xml" <<EOF
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:shortVersionString>2.4.0</sparkle:shortVersionString><sparkle:version>20400</sparkle:version><enclosure url="https://github.com/FixtureOwner/ClaudeUsage/releases/download/v2.4.0-staging/ClaudeUsage.zip" length="$CANONICAL_VERIFY_ZIP_SIZE" sparkle:edSignature="$PUBLISH_VALID_SIGNATURE" /></item></channel></rss>
EOF
CANONICAL_VERIFY_DMG_SIZE="$(
    stat -f%z "$CANONICAL_VERIFY_ASSETS/ClaudeUsage.dmg"
)"
CANONICAL_VERIFY_APPCAST_SIZE="$(
    stat -f%z "$CANONICAL_VERIFY_ASSETS/appcast.xml"
)"
CANONICAL_VERIFY_DMG_SHA="$(
    shasum -a 256 "$CANONICAL_VERIFY_ASSETS/ClaudeUsage.dmg" | awk '{print $1}'
)"
CANONICAL_VERIFY_ZIP_SHA="$(
    shasum -a 256 "$CANONICAL_VERIFY_ASSETS/ClaudeUsage.zip" | awk '{print $1}'
)"
CANONICAL_VERIFY_APPCAST_SHA="$(
    shasum -a 256 "$CANONICAL_VERIFY_ASSETS/appcast.xml" | awk '{print $1}'
)"

cat > "$CANONICAL_VERIFY_BIN/gh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'gh'
    printf ' <%s>' "$@"
    printf '\n'
} >> "${CANONICAL_VERIFY_TRACE:?}"
[[ "${1:-}" == "release" ]]
case "${2:-}" in
    view)
        printf '{"tagName":"v2.4.0-staging","isDraft":false,"isPrerelease":true,"assets":['
        printf '{"name":"ClaudeUsage.dmg","size":%s,"digest":"sha256:%s"},' \
            "${CANONICAL_VERIFY_DMG_SIZE:?}" \
            "${CANONICAL_VERIFY_DMG_SHA:?}"
        printf '{"name":"ClaudeUsage.zip","size":%s,"digest":"sha256:%s"},' \
            "${CANONICAL_VERIFY_ZIP_SIZE:?}" \
            "${CANONICAL_VERIFY_ZIP_SHA:?}"
        printf '{"name":"appcast.xml","size":%s,"digest":"sha256:%s"}' \
            "${CANONICAL_VERIFY_APPCAST_SIZE:?}" \
            "${CANONICAL_VERIFY_APPCAST_SHA:?}"
        printf ']}\n'
        ;;
    download)
        shift 2
        pattern=""
        destination=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --pattern)
                    pattern="$2"
                    shift 2
                    ;;
                --dir)
                    destination="$2"
                    shift 2
                    ;;
                *)
                    shift
                    ;;
            esac
        done
        [[ -n "$pattern" && -n "$destination" ]]
        cp "${CANONICAL_VERIFY_ASSETS:?}/$pattern" "$destination/$pattern"
        ;;
    *)
        exit 97
        ;;
esac
SCRIPT

cat > "$CANONICAL_VERIFY_BIN/ditto" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'ditto'
    printf ' <%s>' "$@"
    printf '\n'
} >> "${CANONICAL_VERIFY_TRACE:?}"
[[ "${1:-}" == "-x" && "${2:-}" == "-k" ]]
destination="$4"
mkdir -p "$destination/ClaudeUsage-stg.app/Contents"
cp "${CANONICAL_VERIFY_INFO_PLIST:?}" \
    "$destination/ClaudeUsage-stg.app/Contents/Info.plist"
SCRIPT

cat > "$CANONICAL_VERIFY_BIN/codesign" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'codesign'
    printf ' <%s>' "$@"
    printf '\n'
} >> "${CANONICAL_VERIFY_TRACE:?}"
if [[ " $* " == *" -dv "* ]]; then
    printf 'Identifier=com.seongmin.ClaudeUsage.staging\n' >&2
    printf 'TeamIdentifier=%s\n' "${CANONICAL_VERIFY_TEAM:?}" >&2
elif [[ " $* " == *" --entitlements "* ]]; then
    cat "${CANONICAL_VERIFY_ENTITLEMENTS:?}"
fi
SCRIPT

cat > "$CANONICAL_VERIFY_BIN/xcrun" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'xcrun'
    printf ' <%s>' "$@"
    printf '\n'
} >> "${CANONICAL_VERIFY_TRACE:?}"
SCRIPT

cat > "$CANONICAL_VERIFY_BIN/spctl" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'spctl'
    printf ' <%s>' "$@"
    printf '\n'
} >> "${CANONICAL_VERIFY_TRACE:?}"
SCRIPT

cat > "$CANONICAL_VERIFY_BIN/hdiutil" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'hdiutil'
    printf ' <%s>' "$@"
    printf '\n'
} >> "${CANONICAL_VERIFY_TRACE:?}"
case "${1:-}" in
    attach)
        shift
        mountpoint=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -mountpoint)
                    mountpoint="$2"
                    shift 2
                    ;;
                *)
                    shift
                    ;;
            esac
        done
        [[ -n "$mountpoint" ]]
        mkdir -p "$mountpoint/ClaudeUsage-stg.app/Contents"
        cp "${CANONICAL_VERIFY_INFO_PLIST:?}" \
            "$mountpoint/ClaudeUsage-stg.app/Contents/Info.plist"
        printf '%s\n' "$mountpoint" > "${CANONICAL_VERIFY_MOUNT_STATE:?}"
        ;;
    detach)
        target="${!#}"
        [[ -f "${CANONICAL_VERIFY_MOUNT_STATE:?}" ]]
        [[ "$(cat "$CANONICAL_VERIFY_MOUNT_STATE")" == "$target" ]]
        rm -f "$CANONICAL_VERIFY_MOUNT_STATE"
        ;;
    *)
        exit 97
        ;;
esac
SCRIPT

cat > "$CANONICAL_VERIFY_BIN/mount" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
if [[ -f "${CANONICAL_VERIFY_MOUNT_STATE:?}" ]]; then
    printf '/dev/disk-fixture on %s (apfs, local, read-only)\n' \
        "$(cat "$CANONICAL_VERIFY_MOUNT_STATE")"
fi
SCRIPT

chmod +x \
    "$CANONICAL_VERIFY_BIN/gh" \
    "$CANONICAL_VERIFY_BIN/ditto" \
    "$CANONICAL_VERIFY_BIN/codesign" \
    "$CANONICAL_VERIFY_BIN/xcrun" \
    "$CANONICAL_VERIFY_BIN/spctl" \
    "$CANONICAL_VERIFY_BIN/hdiutil" \
    "$CANONICAL_VERIFY_BIN/mount"

: > "$CANONICAL_VERIFY_TRACE"
set +e
CANONICAL_VERIFY_OUTPUT="$(
    env \
        "PATH=$CANONICAL_VERIFY_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
        "TMPDIR=$CANONICAL_VERIFY_LOGICAL_TMP" \
        "CANONICAL_VERIFY_TRACE=$CANONICAL_VERIFY_TRACE" \
        "CANONICAL_VERIFY_ASSETS=$CANONICAL_VERIFY_ASSETS" \
        "CANONICAL_VERIFY_INFO_PLIST=$CANONICAL_VERIFY_STATE/Info.plist" \
        "CANONICAL_VERIFY_ENTITLEMENTS=$CANONICAL_VERIFY_STATE/entitlements.plist" \
        "CANONICAL_VERIFY_MOUNT_STATE=$CANONICAL_VERIFY_MOUNT_STATE" \
        "CANONICAL_VERIFY_TEAM=$CANONICAL_VERIFY_TEAM" \
        "CANONICAL_VERIFY_DMG_SIZE=$CANONICAL_VERIFY_DMG_SIZE" \
        "CANONICAL_VERIFY_DMG_SHA=$CANONICAL_VERIFY_DMG_SHA" \
        "CANONICAL_VERIFY_ZIP_SIZE=$CANONICAL_VERIFY_ZIP_SIZE" \
        "CANONICAL_VERIFY_ZIP_SHA=$CANONICAL_VERIFY_ZIP_SHA" \
        "CANONICAL_VERIFY_APPCAST_SIZE=$CANONICAL_VERIFY_APPCAST_SIZE" \
        "CANONICAL_VERIFY_APPCAST_SHA=$CANONICAL_VERIFY_APPCAST_SHA" \
        /bin/bash "$CANONICAL_VERIFY_REPOSITORY/Scripts/verify-release-artifact.sh" \
        --tag v2.4.0-staging \
        --channel staging \
        --expected-version 2.4.0 \
        --expected-build 20400 \
        --repo FixtureOwner/ClaudeUsage \
        2>&1
)"
CANONICAL_VERIFY_STATUS=$?
set -e
CANONICAL_VERIFY_COMMANDS="$(cat "$CANONICAL_VERIFY_TRACE")"
assert_equal "0" "$CANONICAL_VERIFY_STATUS" "symlink TMPDIR verifier"
assert_contains "$CANONICAL_VERIFY_OUTPUT" "검증 완료" "symlink TMPDIR verifier output"
assert_contains \
    "$CANONICAL_VERIFY_COMMANDS" \
    "<-mountpoint> <$CANONICAL_VERIFY_PHYSICAL_TMP_P/" \
    "verifier attach uses canonical mountpoint"
assert_contains \
    "$CANONICAL_VERIFY_COMMANDS" \
    "hdiutil <detach> <$CANONICAL_VERIFY_PHYSICAL_TMP_P/" \
    "verifier detach uses canonical mountpoint"
assert_contains \
    "$CANONICAL_VERIFY_COMMANDS" \
    "codesign <--display> <--entitlements> <-> <--xml>" \
    "verifier inspects signed app entitlements"
assert_ordered \
    "$CANONICAL_VERIFY_COMMANDS" \
    "hdiutil <attach>" \
    "hdiutil <detach>" \
    "verifier attach precedes cleanup detach"
assert_not_contains \
    "$CANONICAL_VERIFY_COMMANDS" \
    "$CANONICAL_VERIFY_LOGICAL_TMP/claudeusage-release-verify" \
    "verifier rejects logical mount identity"
[[ ! -e "$CANONICAL_VERIFY_MOUNT_STATE" ]] \
    || fail "verifier canonical mount state가 cleanup 뒤 남았습니다."
pass
assert_equal \
    "" \
    "$(find "$CANONICAL_VERIFY_PHYSICAL_TMP" -mindepth 1 -print -quit)" \
    "verifier canonical temp cleanup"

# Developer ID 배포본은 provisioning profile을 담지 않으므로 restricted
# entitlement가 런타임에서 거부된다. 원격 artifact에 다시 들어오면 검증이
# 실패해야 한다.
cat > "$CANONICAL_VERIFY_STATE/entitlements.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>keychain-access-groups</key>
    <array>
        <string>$CANONICAL_VERIFY_TEAM.com.seongmin.ClaudeUsage</string>
    </array>
</dict>
</plist>
EOF
: > "$CANONICAL_VERIFY_TRACE"
set +e
CANONICAL_VERIFY_RESTRICTED_OUTPUT="$(
    env \
        "PATH=$CANONICAL_VERIFY_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
        "TMPDIR=$CANONICAL_VERIFY_LOGICAL_TMP" \
        "CANONICAL_VERIFY_TRACE=$CANONICAL_VERIFY_TRACE" \
        "CANONICAL_VERIFY_ASSETS=$CANONICAL_VERIFY_ASSETS" \
        "CANONICAL_VERIFY_INFO_PLIST=$CANONICAL_VERIFY_STATE/Info.plist" \
        "CANONICAL_VERIFY_ENTITLEMENTS=$CANONICAL_VERIFY_STATE/entitlements.plist" \
        "CANONICAL_VERIFY_MOUNT_STATE=$CANONICAL_VERIFY_MOUNT_STATE" \
        "CANONICAL_VERIFY_TEAM=$CANONICAL_VERIFY_TEAM" \
        "CANONICAL_VERIFY_DMG_SIZE=$CANONICAL_VERIFY_DMG_SIZE" \
        "CANONICAL_VERIFY_DMG_SHA=$CANONICAL_VERIFY_DMG_SHA" \
        "CANONICAL_VERIFY_ZIP_SIZE=$CANONICAL_VERIFY_ZIP_SIZE" \
        "CANONICAL_VERIFY_ZIP_SHA=$CANONICAL_VERIFY_ZIP_SHA" \
        "CANONICAL_VERIFY_APPCAST_SIZE=$CANONICAL_VERIFY_APPCAST_SIZE" \
        "CANONICAL_VERIFY_APPCAST_SHA=$CANONICAL_VERIFY_APPCAST_SHA" \
        /bin/bash "$CANONICAL_VERIFY_REPOSITORY/Scripts/verify-release-artifact.sh" \
        --tag v2.4.0-staging \
        --channel staging \
        --expected-version 2.4.0 \
        --expected-build 20400 \
        --repo FixtureOwner/ClaudeUsage \
        2>&1
)"
CANONICAL_VERIFY_RESTRICTED_STATUS=$?
set -e
assert_equal \
    "1" \
    "$CANONICAL_VERIFY_RESTRICTED_STATUS" \
    "verifier rejects unauthorizable Keychain access group"
assert_contains \
    "$CANONICAL_VERIFY_RESTRICTED_OUTPUT" \
    "Keychain access group entitlement가 있습니다" \
    "verifier restricted entitlement message"
[[ ! -e "$CANONICAL_VERIFY_MOUNT_STATE" ]] \
    || fail "restricted entitlement 검증 실패 뒤 canonical mount state가 남았습니다."
pass

CANONICAL_PAGES_ROOT="$TEST_ROOT/canonical-pages"
CANONICAL_PAGES_REPOSITORY="$CANONICAL_PAGES_ROOT/repository"
CANONICAL_PAGES_BIN="$CANONICAL_PAGES_ROOT/bin"
CANONICAL_PAGES_STATE="$CANONICAL_PAGES_ROOT/state"
CANONICAL_PAGES_PHYSICAL_TMP="$CANONICAL_PAGES_ROOT/physical-tmp"
CANONICAL_PAGES_LOGICAL_TMP="$CANONICAL_PAGES_ROOT/logical-tmp"
CANONICAL_PAGES_TRACE="$CANONICAL_PAGES_STATE/commands.log"
CANONICAL_PAGES_REGISTRATION="$CANONICAL_PAGES_STATE/registered-worktree"
mkdir -p \
    "$CANONICAL_PAGES_REPOSITORY/Scripts/lib" \
    "$CANONICAL_PAGES_BIN" \
    "$CANONICAL_PAGES_STATE" \
    "$CANONICAL_PAGES_PHYSICAL_TMP"
ln -s "$CANONICAL_PAGES_PHYSICAL_TMP" "$CANONICAL_PAGES_LOGICAL_TMP"
CANONICAL_PAGES_PHYSICAL_TMP_P="$(
    cd "$CANONICAL_PAGES_PHYSICAL_TMP"
    pwd -P
)"
cp \
    "$ROOT_DIR/Scripts/publish-pages-appcast.sh" \
    "$CANONICAL_PAGES_REPOSITORY/Scripts/publish-pages-appcast.sh"
cp \
    "$ROOT_DIR/Scripts/lib/release-driver-common.sh" \
    "$CANONICAL_PAGES_REPOSITORY/Scripts/lib/release-driver-common.sh"
chmod +x "$CANONICAL_PAGES_REPOSITORY/Scripts/publish-pages-appcast.sh"
printf '<appcast>fixture</appcast>\n' \
    > "$CANONICAL_PAGES_STATE/appcast.xml"

cat > "$CANONICAL_PAGES_BIN/gh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'gh'
    printf ' <%s>' "$@"
    printf '\n'
} >> "${CANONICAL_PAGES_TRACE:?}"
[[ "${1:-}" == "repo" && "${2:-}" == "view" ]]
printf 'FixtureOwner/ClaudeUsage\n'
SCRIPT

cat > "$CANONICAL_PAGES_BIN/git" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'git'
    printf ' <%s>' "$@"
    printf '\n'
} >> "${CANONICAL_PAGES_TRACE:?}"
working_directory=""
if [[ "${1:-}" == "-C" ]]; then
    working_directory="$2"
    shift 2
fi
case "${1:-}" in
    fetch|show-ref)
        exit 0
        ;;
    worktree)
        case "${2:-}" in
            list)
                if [[ -f "${CANONICAL_PAGES_REGISTRATION:?}" ]]; then
                    printf 'worktree %s\n' "$(cat "$CANONICAL_PAGES_REGISTRATION")"
                    printf 'HEAD 5555555555555555555555555555555555555555\n'
                    printf 'detached\n\n'
                fi
                ;;
            add)
                worktree_path="$4"
                printf '%s\n' "$worktree_path" > "$CANONICAL_PAGES_REGISTRATION"
                printf 'worktree-add <%s>\n' "$worktree_path" \
                    >> "${CANONICAL_PAGES_TRACE:?}"
                ;;
            remove)
                worktree_path="$4"
                [[ -f "${CANONICAL_PAGES_REGISTRATION:?}" ]]
                [[ "$(cat "$CANONICAL_PAGES_REGISTRATION")" == "$worktree_path" ]]
                printf 'worktree-remove <%s>\n' "$worktree_path" \
                    >> "${CANONICAL_PAGES_TRACE:?}"
                rm -rf "$worktree_path"
                rm -f "$CANONICAL_PAGES_REGISTRATION"
                ;;
            prune)
                exit 0
                ;;
            *)
                exit 97
                ;;
        esac
        ;;
    add)
        [[ -n "$working_directory" ]]
        ;;
    diff)
        [[ -n "$working_directory" ]]
        exit 0
        ;;
    *)
        exit 97
        ;;
esac
SCRIPT

chmod +x "$CANONICAL_PAGES_BIN/gh" "$CANONICAL_PAGES_BIN/git"
: > "$CANONICAL_PAGES_TRACE"
set +e
CANONICAL_PAGES_OUTPUT="$(
    env \
        "PATH=$CANONICAL_PAGES_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
        "TMPDIR=$CANONICAL_PAGES_LOGICAL_TMP" \
        "APPCAST_SOURCE=$CANONICAL_PAGES_STATE/appcast.xml" \
        "GHPAGES_BRANCH=gh-pages" \
        "CANONICAL_PAGES_TRACE=$CANONICAL_PAGES_TRACE" \
        "CANONICAL_PAGES_REGISTRATION=$CANONICAL_PAGES_REGISTRATION" \
        /bin/bash "$CANONICAL_PAGES_REPOSITORY/Scripts/publish-pages-appcast.sh" \
        --feed-url https://fixtureowner.github.io/ClaudeUsage/channels/staging/appcast.xml \
        --channel staging \
        --tag v2.4.0-staging \
        2>&1
)"
CANONICAL_PAGES_STATUS=$?
set -e
CANONICAL_PAGES_COMMANDS="$(cat "$CANONICAL_PAGES_TRACE")"
assert_equal "0" "$CANONICAL_PAGES_STATUS" "symlink TMPDIR Pages worktree"
assert_contains \
    "$CANONICAL_PAGES_OUTPUT" \
    "gh-pages 에 반영할 변경이 없습니다." \
    "symlink TMPDIR Pages output"
assert_contains \
    "$CANONICAL_PAGES_COMMANDS" \
    "worktree-add <$CANONICAL_PAGES_PHYSICAL_TMP_P/" \
    "Pages registers canonical worktree"
assert_contains \
    "$CANONICAL_PAGES_COMMANDS" \
    "worktree-remove <$CANONICAL_PAGES_PHYSICAL_TMP_P/" \
    "Pages removes canonical worktree"
assert_ordered \
    "$CANONICAL_PAGES_COMMANDS" \
    "worktree-add <$CANONICAL_PAGES_PHYSICAL_TMP_P/" \
    "worktree-remove <$CANONICAL_PAGES_PHYSICAL_TMP_P/" \
    "Pages cleanup follows registration"
assert_not_contains \
    "$CANONICAL_PAGES_COMMANDS" \
    "$CANONICAL_PAGES_LOGICAL_TMP/claudeusage-gh-pages" \
    "Pages avoids logical worktree identity"
[[ ! -e "$CANONICAL_PAGES_REGISTRATION" ]] \
    || fail "Pages canonical worktree registration이 cleanup 뒤 남았습니다."
pass
assert_equal \
    "" \
    "$(find "$CANONICAL_PAGES_PHYSICAL_TMP" -mindepth 1 -print -quit)" \
    "Pages canonical temp cleanup"

echo "release driver tests: $PASS_COUNT passed"
