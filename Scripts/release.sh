#!/usr/bin/env bash
#
# ClaudeUsage release driver.
# Existing build/publish scripts remain the release primitives. This script
# resolves the channel/tag, enforces release gates, prepares the previous
# same-channel app for Sparkle upgrade QA, and verifies the published result.

set -euo pipefail

# `git -C`보다 우선하는 caller repository context를 release driver에
# 유입시키지 않는다. 이 unset은 현재 driver process와 child에만 적용된다.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR

SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${RELEASE_DRIVER_TEST_MODE:-0}" == "1" ]]; then
    ROOT_DIR="${RELEASE_DRIVER_ROOT_DIR:-$SCRIPT_ROOT}"
    DOWNLOADS_APP_PATH="${DOWNLOADS_APP_PATH:-$HOME/Downloads/ClaudeUsage.app}"
else
    if [[ -n "${RELEASE_DRIVER_ROOT_DIR:-}" || -n "${DOWNLOADS_APP_PATH:-}" ]]; then
        echo "오류: release source와 Downloads target override는 격리 테스트에서만 허용합니다." >&2
        exit 1
    fi
    ROOT_DIR="$SCRIPT_ROOT"
    DOWNLOADS_APP_PATH="$HOME/Downloads/ClaudeUsage.app"
fi
# shellcheck source=Scripts/lib/release-driver-common.sh
source "$SCRIPT_ROOT/Scripts/lib/release-driver-common.sh"

REPOSITORY="ChoSeongmin1128/claude-usage"
RELEASE_GH_ACCOUNT="ChoSeongmin1128"
RESTORE_GH_ACCOUNT="nathan-glorang"
EXPECTED_ORIGIN_URL="git@github-seongmin:ChoSeongmin1128/claude-usage.git"
export GH_HOST="github.com"
export GH_REPO="$REPOSITORY"
NOTARY_PROFILE="${NOTARY_PROFILE:-ClaudeUsageNotary}"
PROJECT_FILE="$ROOT_DIR/ClaudeUsage.xcodeproj/project.pbxproj"
PROJECT_PATH="$ROOT_DIR/ClaudeUsage.xcodeproj"
RELEASE_XCCONFIG_PATH="$ROOT_DIR/Config/Release.xcconfig"
LOCAL_RELEASE_XCCONFIG_PATH="$ROOT_DIR/Config/Sparkle.release.local.xcconfig"
ENTITLEMENTS_PATH="$ROOT_DIR/ClaudeUsage/ClaudeUsage.entitlements"
BUILD_SCRIPT="$ROOT_DIR/Scripts/build-notarize-release.sh"
PUBLISH_SCRIPT="$ROOT_DIR/Scripts/publish-release.sh"
VERIFY_SCRIPT="$ROOT_DIR/Scripts/verify-release-artifact.sh"
DRIVER_TEST_SCRIPT="$ROOT_DIR/Scripts/tests/release-driver-tests.sh"
PAGES_PUBLISH_SCRIPT="$ROOT_DIR/Scripts/publish-pages-appcast.sh"
PAGES_BRANCH="gh-pages"

ENVIRONMENT_INPUT=""
RELEASE_ENVIRONMENT=""
VERSION=""
NOTES=""
NON_INTERACTIVE=0
DRY_RUN=0
CONFIRM_PUBLISH=""
ORIGINAL_GH_ACCOUNT=""
RESTORE_GH_ACCOUNT_ON_EXIT=0
RUN_ROOT=""
BUILD_DIR=""
ARCHIVE_PATH=""
DRIVER_TMP_DIR=""
VERIFIED_CANDIDATE_APPCAST=""

PROD_RELEASE_TAG=""
STAGING_RELEASE_TAG=""
PROD_FEED_VERSION=""
PROD_FEED_BUILD=""
PROD_FEED_TAG=""
STAGING_FEED_VERSION=""
STAGING_FEED_BUILD=""
STAGING_FEED_TAG=""

usage() {
    cat <<'USAGE'
사용법:
  ./Scripts/release.sh [stg|staging|prod] [X.Y.Z] [옵션]

예:
  ./Scripts/release.sh
  ./Scripts/release.sh stg 2.4.0
  ./Scripts/release.sh prod 2.4.0 --notes "2.4.0"

옵션:
  --environment stg|staging|prod
  --version X.Y.Z
  --notes TEXT
  --non-interactive
  --confirm-publish vX.Y.Z[-staging]
  --dry-run
  --help

규칙:
  - stg/staging 입력은 staging 채널과 vX.Y.Z-staging tag로 정규화됩니다.
  - prod 입력은 prod 채널과 vX.Y.Z tag로 정규화됩니다.
  - 입력은 숫자 X.Y.Z만 허용합니다. v prefix나 suffix를 직접 입력하지 않습니다.
  - 새 build number는 major*10000 + minor*100 + patch입니다.
  - --non-interactive 실제 게시는 --confirm-publish에 exact tag가 필요합니다.
  - --dry-run은 네트워크의 읽기 전용 상태만 조회하고 Git, 파일, 계정,
    Downloads, Keychain, 빌드 및 Release를 변경하지 않습니다.
USAGE
}

die() {
    echo "오류: $*" >&2
    exit 1
}

cleanup_release_driver() {
    local exit_code=$?
    local cleanup_failed=0
    local restore_failed=0

    if [[ -n "$RUN_ROOT" && -d "$RUN_ROOT" ]]; then
        if ! rm -rf "$RUN_ROOT" || [[ -e "$RUN_ROOT" ]]; then
            echo "오류: release 임시 디렉터리를 정리하지 못했습니다: $RUN_ROOT" >&2
            cleanup_failed=1
        fi
    fi
    if [[ "$RESTORE_GH_ACCOUNT_ON_EXIT" == "1" ]]; then
        echo
        echo "GitHub CLI 계정 복원: $RESTORE_GH_ACCOUNT"
        if ! gh auth switch --hostname github.com --user "$RESTORE_GH_ACCOUNT" >/dev/null 2>&1; then
            echo "오류: GitHub CLI 계정을 $RESTORE_GH_ACCOUNT 로 복원하지 못했습니다." >&2
            restore_failed=1
        fi
    fi
    exit "$(release_cleanup_exit_code "$exit_code" "$cleanup_failed" "$restore_failed")"
}

exit_on_signal() {
    exit 130
}

trap cleanup_release_driver EXIT
trap exit_on_signal INT TERM HUP

POSITIONAL_COUNT=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --environment)
            [[ $# -ge 2 ]] || die "--environment 값이 필요합니다."
            ENVIRONMENT_INPUT="$2"
            shift 2
            ;;
        --version)
            [[ $# -ge 2 ]] || die "--version 값이 필요합니다."
            VERSION="$2"
            shift 2
            ;;
        --notes)
            [[ $# -ge 2 ]] || die "--notes 값이 필요합니다."
            NOTES="$2"
            shift 2
            ;;
        --non-interactive)
            NON_INTERACTIVE=1
            shift
            ;;
        --confirm-publish)
            [[ $# -ge 2 ]] || die "--confirm-publish 값이 필요합니다."
            CONFIRM_PUBLISH="$2"
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
        --*)
            die "알 수 없는 옵션: $1"
            ;;
        *)
            POSITIONAL_COUNT=$((POSITIONAL_COUNT + 1))
            case "$POSITIONAL_COUNT" in
                1)
                    [[ -z "$ENVIRONMENT_INPUT" ]] || die "배포 환경이 중복 지정됐습니다."
                    ENVIRONMENT_INPUT="$1"
                    ;;
                2)
                    [[ -z "$VERSION" ]] || die "버전이 중복 지정됐습니다."
                    VERSION="$1"
                    ;;
                *)
                    die "위치 인자는 환경과 버전까지만 허용합니다: $1"
                    ;;
            esac
            shift
            ;;
    esac
done

if [[ -z "$ENVIRONMENT_INPUT" ]]; then
    [[ "$NON_INTERACTIVE" == "0" && -t 0 ]] \
        || die "배포 환경을 지정해 주세요: stg 또는 prod"
    read -r -p "배포 환경 (stg/prod): " ENVIRONMENT_INPUT
fi
RELEASE_ENVIRONMENT="$(normalize_release_environment "$ENVIRONMENT_INPUT")" \
    || die "지원하지 않는 배포 환경입니다: $ENVIRONMENT_INPUT (stg, staging, prod만 허용)"

read_channel_feed_state() {
    local channel="$1"
    local feed_url xml version build enclosure tag
    local test_feed_state

    if [[ "${RELEASE_DRIVER_TEST_MODE:-0}" == "1" ]]; then
        case "$channel" in
            prod)
                test_feed_state="${RELEASE_DRIVER_TEST_PROD_FEED_STATE:-}"
                if [[ -n "${RELEASE_DRIVER_TEST_FEED_SWITCH_FILE:-}" \
                    && -f "$RELEASE_DRIVER_TEST_FEED_SWITCH_FILE" \
                    && -n "${RELEASE_DRIVER_TEST_PROD_FEED_STATE_AFTER:-}" ]]; then
                    test_feed_state="$RELEASE_DRIVER_TEST_PROD_FEED_STATE_AFTER"
                fi
                ;;
            staging)
                test_feed_state="${RELEASE_DRIVER_TEST_STAGING_FEED_STATE:-}"
                if [[ -n "${RELEASE_DRIVER_TEST_FEED_SWITCH_FILE:-}" \
                    && -f "$RELEASE_DRIVER_TEST_FEED_SWITCH_FILE" \
                    && -n "${RELEASE_DRIVER_TEST_STAGING_FEED_STATE_AFTER:-}" ]]; then
                    test_feed_state="$RELEASE_DRIVER_TEST_STAGING_FEED_STATE_AFTER"
                fi
                ;;
        esac
        printf '%s\n' "$test_feed_state"
        return 0
    fi

    feed_url="$(release_feed_url_for "$channel")"
    xml="$(curl -fsSL "$feed_url")"
    version="$(
        printf '%s\n' "$xml" \
            | sed -n 's|.*<sparkle:shortVersionString>\([^<]*\)</sparkle:shortVersionString>.*|\1|p' \
            | sed -n '1p'
    )"
    build="$(
        printf '%s\n' "$xml" \
            | sed -n 's|.*<sparkle:version>\([^<]*\)</sparkle:version>.*|\1|p' \
            | sed -n '1p'
    )"
    enclosure="$(
        printf '%s\n' "$xml" \
            | sed -n 's|.*<enclosure[^>]*url="\([^"]*\)".*|\1|p' \
            | sed -n '1p'
    )"
    if [[ "$enclosure" =~ /releases/download/(v[^/]+)/ClaudeUsage\.zip$ ]]; then
        tag="${BASH_REMATCH[1]}"
    else
        return 1
    fi
    [[ -n "$version" && "$build" =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s\t%s\t%s\n' "$version" "$build" "$tag"
}

read_latest_release_tag() {
    local channel="$1"

    if [[ "${RELEASE_DRIVER_TEST_MODE:-0}" == "1" ]]; then
        case "$channel" in
            prod)
                printf '%s\n' "${RELEASE_DRIVER_TEST_PROD_TAG:-}"
                ;;
            staging)
                printf '%s\n' "${RELEASE_DRIVER_TEST_STAGING_TAG:-}"
                ;;
        esac
        return 0
    fi

    case "$channel" in
        prod)
            gh release list \
                --repo "$REPOSITORY" \
                --limit 100 \
                --json tagName,isDraft,isPrerelease \
                --jq 'map(select(.isDraft == false and .isPrerelease == false and (.tagName | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))))[0].tagName // ""'
            ;;
        staging)
            gh release list \
                --repo "$REPOSITORY" \
                --limit 100 \
                --json tagName,isDraft,isPrerelease \
                --jq 'map(select(.isDraft == false and .isPrerelease == true and (.tagName | test("^v[0-9]+\\.[0-9]+\\.[0-9]+-staging$"))))[0].tagName // ""'
            ;;
    esac
}

refresh_release_state() {
    local prod_feed_state staging_feed_state

    PROD_RELEASE_TAG="$(read_latest_release_tag prod)"
    STAGING_RELEASE_TAG="$(read_latest_release_tag staging)"
    prod_feed_state="$(read_channel_feed_state prod)" \
        || die "prod appcast의 version/build/tag를 읽지 못했습니다."
    staging_feed_state="$(read_channel_feed_state staging)" \
        || die "staging appcast의 version/build/tag를 읽지 못했습니다."
    IFS=$'\t' read -r PROD_FEED_VERSION PROD_FEED_BUILD PROD_FEED_TAG <<< "$prod_feed_state"
    IFS=$'\t' read -r STAGING_FEED_VERSION STAGING_FEED_BUILD STAGING_FEED_TAG <<< "$staging_feed_state"
}

validate_release_state() {
    local prod_release_version staging_release_version

    prod_release_version="$(release_version_from_tag "$PROD_RELEASE_TAG")" \
        || die "현재 prod Release tag 형식이 유효하지 않습니다: ${PROD_RELEASE_TAG:-<없음>}"
    staging_release_version="$(release_version_from_tag "$STAGING_RELEASE_TAG")" \
        || die "현재 staging Release tag 형식이 유효하지 않습니다: ${STAGING_RELEASE_TAG:-<없음>}"
    [[ "$PROD_RELEASE_TAG" == "$PROD_FEED_TAG" && "$prod_release_version" == "$PROD_FEED_VERSION" ]] \
        || die "prod Release와 public appcast가 다릅니다: release=$PROD_RELEASE_TAG, feed=$PROD_FEED_TAG/$PROD_FEED_VERSION"
    [[ "$STAGING_RELEASE_TAG" == "$STAGING_FEED_TAG" && "$staging_release_version" == "$STAGING_FEED_VERSION" ]] \
        || die "staging Release와 public appcast가 다릅니다: release=$STAGING_RELEASE_TAG, feed=$STAGING_FEED_TAG/$STAGING_FEED_VERSION"
}

validate_feed_state() {
    local prod_feed_version staging_feed_version

    prod_feed_version="$(release_version_from_tag "$PROD_FEED_TAG")" \
        || die "prod appcast tag 형식이 유효하지 않습니다: ${PROD_FEED_TAG:-<없음>}"
    staging_feed_version="$(release_version_from_tag "$STAGING_FEED_TAG")" \
        || die "staging appcast tag 형식이 유효하지 않습니다: ${STAGING_FEED_TAG:-<없음>}"
    [[ "$prod_feed_version" == "$PROD_FEED_VERSION" ]] \
        || die "prod appcast tag/version이 다릅니다: $PROD_FEED_TAG/$PROD_FEED_VERSION"
    [[ "$staging_feed_version" == "$STAGING_FEED_VERSION" ]] \
        || die "staging appcast tag/version이 다릅니다: $STAGING_FEED_TAG/$STAGING_FEED_VERSION"
}

validate_non_target_release_state() {
    case "$RELEASE_ENVIRONMENT" in
        staging)
            local prod_release_version
            prod_release_version="$(release_version_from_tag "$PROD_RELEASE_TAG")" \
                || die "현재 prod Release tag 형식이 유효하지 않습니다."
            [[ "$PROD_RELEASE_TAG" == "$PROD_FEED_TAG" \
                && "$prod_release_version" == "$PROD_FEED_VERSION" ]] \
                || die "prod Release와 public appcast가 다릅니다."
            ;;
        prod)
            local staging_release_version
            staging_release_version="$(release_version_from_tag "$STAGING_RELEASE_TAG")" \
                || die "현재 staging Release tag 형식이 유효하지 않습니다."
            [[ "$STAGING_RELEASE_TAG" == "$STAGING_FEED_TAG" \
                && "$staging_release_version" == "$STAGING_FEED_VERSION" ]] \
                || die "staging Release와 public appcast가 다릅니다."
            ;;
    esac
}

request_pages_build_if_needed() {
    local force_current_build="${1:-0}"
    local pages_state pages_status pages_commit

    pages_state="$(
        gh api "repos/$REPOSITORY/pages/builds/latest" \
            --jq '[.status, .commit] | @tsv'
    )"
    IFS=$'\t' read -r pages_status pages_commit <<< "$pages_state"
    if [[ "$pages_commit" == "$GH_PAGES_SHA" \
        && ( "$pages_status" == "building" || "$pages_status" == "queued" ) ]]; then
        return 0
    fi
    if [[ "$pages_commit" == "$GH_PAGES_SHA" \
        && "$pages_status" == "built" \
        && "$force_current_build" != "1" ]]; then
        return 0
    fi
    [[ "${PAGES_REBUILD_REQUESTED:-0}" == "0" ]] || return 0

    echo "GitHub Pages build 재요청: status=$pages_status, commit=$pages_commit"
    gh api \
        --method POST \
        "repos/$REPOSITORY/pages/builds" \
        >/dev/null
    PAGES_REBUILD_REQUESTED=1
}

wait_for_pages_and_feed() {
    local force_current_build="${1:-0}"
    local pages_deadline pages_state pages_status pages_commit
    local feed_deadline feed_rebuild_at current_feed_state now
    local current_feed_version current_feed_build current_feed_tag

    echo
    echo "GitHub Pages build 확인"
    GH_PAGES_SHA="$(
        git -C "$ROOT_DIR" ls-remote origin refs/heads/gh-pages \
            | awk '{print $1}'
    )"
    [[ "$GH_PAGES_SHA" =~ ^[0-9a-f]{40}$ ]] \
        || die "gh-pages 원격 commit을 확인하지 못했습니다."
    PAGES_REBUILD_REQUESTED=0
    request_pages_build_if_needed "$force_current_build"

    pages_deadline=$(( $(date +%s) + 300 ))
    while true; do
        pages_state="$(
            gh api "repos/$REPOSITORY/pages/builds/latest" \
                --jq '[.status, .commit] | @tsv'
        )"
        IFS=$'\t' read -r pages_status pages_commit <<< "$pages_state"
        if [[ "$pages_status" == "built" && "$pages_commit" == "$GH_PAGES_SHA" ]]; then
            break
        fi
        if [[ "$pages_commit" != "$GH_PAGES_SHA" \
            || ( "$pages_status" != "queued" && "$pages_status" != "building" ) ]]; then
            if [[ "$PAGES_REBUILD_REQUESTED" == "0" ]]; then
                request_pages_build_if_needed 1
                pages_deadline=$(( $(date +%s) + 300 ))
            fi
        fi
        (( $(date +%s) < pages_deadline )) \
            || die "GitHub Pages build가 300초 안에 완료되지 않았습니다: status=$pages_status, commit=$pages_commit"
        sleep 5
    done

    echo "public appcast 전파 확인"
    feed_deadline=$(( $(date +%s) + 300 ))
    feed_rebuild_at=$(( $(date +%s) + 60 ))
    while true; do
        current_feed_state="$(
            read_channel_feed_state "$RELEASE_ENVIRONMENT" 2>/dev/null || true
        )"
        IFS=$'\t' read -r \
            current_feed_version \
            current_feed_build \
            current_feed_tag \
            <<< "$current_feed_state"
        if [[ "$current_feed_version" == "$VERSION" \
            && "$current_feed_build" == "$EXPECTED_BUILD" \
            && "$current_feed_tag" == "$TAG" ]]; then
            break
        fi
        now="$(date +%s)"
        if (( now >= feed_rebuild_at )) \
            && [[ "$PAGES_REBUILD_REQUESTED" == "0" ]]; then
            request_pages_build_if_needed 1
            feed_deadline=$(( now + 300 ))
        fi
        (( now < feed_deadline )) \
            || die "public appcast가 300초 안에 새 후보로 전파되지 않았습니다: $current_feed_tag/$current_feed_version ($current_feed_build)"
        sleep 5
    done
}

repair_pages_from_candidate_release() {
    [[ -f "$VERIFIED_CANDIDATE_APPCAST" && ! -L "$VERIFIED_CANDIDATE_APPCAST" ]] \
        || die "검증된 Pages 복구용 appcast.xml을 찾지 못했습니다."

    TMPDIR="$DRIVER_TMP_DIR" \
    GH_HOST="github.com" \
    GH_REPO="$REPOSITORY" \
    APPCAST_SOURCE="$VERIFIED_CANDIDATE_APPCAST" \
    GHPAGES_BRANCH="$PAGES_BRANCH" \
        "$PAGES_PUBLISH_SCRIPT" \
        --feed-url "$FEED_URL" \
        --channel "$RELEASE_ENVIRONMENT" \
        --tag "$TAG"
    rm -f "$VERIFIED_CANDIDATE_APPCAST"
    [[ ! -e "$VERIFIED_CANDIDATE_APPCAST" ]] \
        || die "검증된 Pages 복구용 appcast.xml을 정리하지 못했습니다."
    VERIFIED_CANDIDATE_APPCAST=""
    wait_for_pages_and_feed 1
}

if [[ "${RELEASE_DRIVER_TEST_MODE:-0}" != "1" ]]; then
    for binary in gh curl git; do
        command -v "$binary" >/dev/null 2>&1 || die "필수 명령을 찾지 못했습니다: $binary"
    done
    gh auth status >/dev/null 2>&1 || die "GitHub CLI 로그인이 필요합니다."
fi

CODE_VERSION="$(read_project_release_version "$PROJECT_FILE")" \
    || die "project.pbxproj의 MARKETING_VERSION이 하나의 값으로 일치하지 않습니다."
CODE_BUILD="$(read_project_release_build "$PROJECT_FILE")" \
    || die "project.pbxproj의 CURRENT_PROJECT_VERSION이 하나의 값으로 일치하지 않습니다."
[[ "$CODE_BUILD" =~ ^[1-9][0-9]*$ ]] || die "CURRENT_PROJECT_VERSION이 양의 정수가 아닙니다: $CODE_BUILD"

refresh_release_state
validate_feed_state

echo
echo "ClaudeUsage 배포 상태"
echo "  code:       $CODE_VERSION ($CODE_BUILD)"
echo "  prod:       $PROD_RELEASE_TAG / $PROD_FEED_VERSION ($PROD_FEED_BUILD)"
echo "  staging:    $STAGING_RELEASE_TAG / $STAGING_FEED_VERSION ($STAGING_FEED_BUILD)"
echo "  환경 입력:  $ENVIRONMENT_INPUT -> $RELEASE_ENVIRONMENT"
echo "  버전 후보:  $CODE_VERSION (현재 project 값)"

if [[ -z "$VERSION" ]]; then
    [[ "$NON_INTERACTIVE" == "0" && -t 0 ]] \
        || die "배포 버전을 숫자 X.Y.Z 형식으로 지정해 주세요."
    read -r -p "배포할 버전 [$CODE_VERSION]: " VERSION
    VERSION="${VERSION:-$CODE_VERSION}"
fi
validate_numeric_release_version "$VERSION" \
    || die "버전은 leading zero 없는 X.Y.Z 숫자 형식이어야 하며 minor/patch는 0~99 범위여야 합니다: $VERSION"

MINIMUM_NEW_RULE_VERSION="2.4.0"
VERSION_MINIMUM_COMPARISON="$(compare_numeric_release_versions "$VERSION" "$MINIMUM_NEW_RULE_VERSION")"
[[ "$VERSION_MINIMUM_COMPARISON" != "-1" ]] \
    || die "release driver의 새 build 규칙은 2.4.0부터 적용합니다: 입력=$VERSION"

EXPECTED_BUILD="$(derive_release_build_number "$VERSION")" \
    || die "입력 버전에서 build number를 안전하게 계산할 수 없습니다: $VERSION"
TAG="$(release_tag_for "$RELEASE_ENVIRONMENT" "$VERSION")"
FEED_URL="$(release_feed_url_for "$RELEASE_ENVIRONMENT")"

echo
echo "배포 후보"
echo "  channel:           $RELEASE_ENVIRONMENT"
echo "  numeric version:   $VERSION"
echo "  expected build:    $EXPECTED_BUILD (= major*10000 + minor*100 + patch)"
echo "  generated tag:     $TAG"
echo "  feed URL:          $FEED_URL"

if [[ "$CODE_VERSION" != "$VERSION" || "$CODE_BUILD" != "$EXPECTED_BUILD" ]]; then
    cat >&2 <<EOF
오류: 입력 버전과 project release 설정이 일치하지 않습니다.
  입력 기대값: MARKETING_VERSION=$VERSION, CURRENT_PROJECT_VERSION=$EXPECTED_BUILD
  project 값:  MARKETING_VERSION=$CODE_VERSION, CURRENT_PROJECT_VERSION=$CODE_BUILD
  수정 위치:   ClaudeUsage.xcodeproj/project.pbxproj

dev에서 위 값을 모든 build configuration에 일관되게 반영하고 전체 검증한 뒤,
검증된 dev tree를 main에 squash한 다음 release driver를 다시 실행하세요.
EOF
    exit 1
fi

PROD_VERSION="$PROD_FEED_VERSION"
STAGING_VERSION="$STAGING_FEED_VERSION"
case "$RELEASE_ENVIRONMENT" in
    staging)
        [[ "$(compare_numeric_release_versions "$VERSION" "$STAGING_VERSION")" == "1" \
            || "$STAGING_FEED_TAG" == "$TAG" ]] \
            || die "staging version은 현재 staging보다 커야 합니다: 현재=$STAGING_VERSION, 입력=$VERSION"
        [[ "$(compare_numeric_release_versions "$VERSION" "$PROD_VERSION")" == "1" ]] \
            || die "staging version은 현재 prod보다 커야 합니다: 현재=$PROD_VERSION, 입력=$VERSION"
        PREVIOUS_TAG="$STAGING_FEED_TAG"
        PREVIOUS_VERSION="$STAGING_FEED_VERSION"
        PREVIOUS_BUILD="$STAGING_FEED_BUILD"
        ;;
    prod)
        [[ "$(compare_numeric_release_versions "$VERSION" "$PROD_VERSION")" == "1" \
            || "$PROD_FEED_TAG" == "$TAG" ]] \
            || die "prod version은 현재 prod보다 커야 합니다: 현재=$PROD_VERSION, 입력=$VERSION"
        PREVIOUS_TAG="$PROD_FEED_TAG"
        PREVIOUS_VERSION="$PROD_FEED_VERSION"
        PREVIOUS_BUILD="$PROD_FEED_BUILD"
        ;;
esac

echo "  upgrade 기준:     $PREVIOUS_TAG / $PREVIOUS_VERSION ($PREVIOUS_BUILD)"
echo "  Downloads 기준:   $DOWNLOADS_APP_PATH"
echo "                    (새 publish 전에 위 동일 채널 원격 앱으로 교체)"

if [[ "$DRY_RUN" == "1" ]]; then
    cat <<EOF

DRY-RUN 실행 계획
  1. release 계정/저장소, clean main, origin/main, 미사용 tag 확인
  2. notary profile '$NOTARY_PROFILE' 사전 검증
  3. release driver shell 회귀 테스트 실행
  4. 격리된 임시 DerivedData/xcresult로 전체 XCTest 실행 후 즉시 정리
  5. $PREVIOUS_TAG 원격 DMG/ZIP/appcast digest 및 앱 서명/notarization 검증
  6. 검증한 이전 앱을 $DOWNLOADS_APP_PATH 로 교체
  7. RELEASE_CHANNEL=$RELEASE_ENVIRONMENT 로 build-notarize-release.sh 실행
  8. 게시 직전 exact tag '$TAG' 재확인
  9. publish-release.sh로 immutable tag와 세 Release asset 게시
 10. 새 원격 $TAG DMG/ZIP/appcast를 검증하고 정확한 appcast bytes export
 11. 검증된 appcast만 Pages에 게시하고 public feed 전파 확인
 12. public feed를 포함해 새 원격 산출물을 최종 재검증

DRY-RUN 완료: Git ref, GitHub 계정, Keychain, build, 임시 파일,
Downloads 앱, tag, Release, appcast를 변경하지 않았습니다.
EOF
    exit 0
fi

if [[ "${RELEASE_DRIVER_TEST_MODE:-0}" == "1" ]]; then
    [[ "${RELEASE_DRIVER_TEST_EXECUTE:-0}" == "1" ]] \
        || die "RELEASE_DRIVER_TEST_MODE 실제 경로는 RELEASE_DRIVER_TEST_EXECUTE=1이 필요합니다."
    TEST_SANDBOX_ROOT="${RELEASE_DRIVER_TEST_SANDBOX_ROOT:-}"
    TEST_BIN_DIR="${RELEASE_DRIVER_TEST_BIN_DIR:-}"
    [[ -n "$TEST_SANDBOX_ROOT" && "$TEST_SANDBOX_ROOT" != "/" && -d "$TEST_SANDBOX_ROOT" ]] \
        || die "release driver test sandbox root가 유효하지 않습니다."
    [[ -n "$TEST_BIN_DIR" && -d "$TEST_BIN_DIR" ]] \
        || die "release driver test shim 디렉터리가 유효하지 않습니다."
    case "$ROOT_DIR" in
        "$TEST_SANDBOX_ROOT"/*) ;;
        *) die "test repository가 test sandbox 밖에 있습니다: $ROOT_DIR" ;;
    esac
    case "${TMPDIR:-/tmp}" in
        "$TEST_SANDBOX_ROOT"/*) ;;
        *) die "test TMPDIR이 test sandbox 밖에 있습니다: ${TMPDIR:-/tmp}" ;;
    esac
    case "$DOWNLOADS_APP_PATH" in
        "$TEST_SANDBOX_ROOT"/*) ;;
        *) die "test Downloads 앱 경로가 test sandbox 밖에 있습니다: $DOWNLOADS_APP_PATH" ;;
    esac
    for binary in gh git xcodebuild xcrun codesign; do
        RESOLVED_TEST_BINARY="$(command -v "$binary" 2>/dev/null || true)"
        [[ "$RESOLVED_TEST_BINARY" == "$TEST_BIN_DIR/$binary" ]] \
            || die "test 명령이 격리 shim을 사용하지 않습니다: $binary=$RESOLVED_TEST_BINARY"
    done
fi

for binary in xcodebuild xcrun codesign; do
    command -v "$binary" >/dev/null 2>&1 || die "필수 명령을 찾지 못했습니다: $binary"
done
[[ -x "$BUILD_SCRIPT" ]] || die "빌드 primitive를 실행할 수 없습니다: $BUILD_SCRIPT"
[[ -x "$PUBLISH_SCRIPT" ]] || die "게시 primitive를 실행할 수 없습니다: $PUBLISH_SCRIPT"
[[ -x "$VERIFY_SCRIPT" ]] || die "원격 artifact verifier를 실행할 수 없습니다: $VERIFY_SCRIPT"
[[ -x "$DRIVER_TEST_SCRIPT" ]] || die "release driver 테스트를 실행할 수 없습니다: $DRIVER_TEST_SCRIPT"
[[ -x "$PAGES_PUBLISH_SCRIPT" ]] || die "Pages 게시 primitive를 실행할 수 없습니다: $PAGES_PUBLISH_SCRIPT"

GH_AUTH_STATUS="$(gh auth status --hostname github.com 2>&1)" \
    || die "GitHub CLI 인증 상태를 확인하지 못했습니다."
[[ "$GH_AUTH_STATUS" == *"$RELEASE_GH_ACCOUNT"* ]] \
    || die "release GitHub 계정 인증이 없습니다: $RELEASE_GH_ACCOUNT"
[[ "$GH_AUTH_STATUS" == *"$RESTORE_GH_ACCOUNT"* ]] \
    || die "종료 시 복원할 GitHub 계정 인증이 없습니다: $RESTORE_GH_ACCOUNT"
RESTORE_GH_ACCOUNT_ON_EXIT=1

ORIGINAL_GH_ACCOUNT="$(gh api user --jq .login)"
if [[ "$ORIGINAL_GH_ACCOUNT" != "$RELEASE_GH_ACCOUNT" ]]; then
    echo
    echo "GitHub CLI 계정 전환: $ORIGINAL_GH_ACCOUNT -> $RELEASE_GH_ACCOUNT"
    gh auth switch --hostname github.com --user "$RELEASE_GH_ACCOUNT"
fi
ACTIVE_GH_ACCOUNT="$(gh api user --jq .login)"
[[ "$ACTIVE_GH_ACCOUNT" == "$RELEASE_GH_ACCOUNT" ]] \
    || die "GitHub CLI active 계정이 release 계정이 아닙니다: $ACTIVE_GH_ACCOUNT"
REPO_NAME_WITH_OWNER="$(gh repo view "$REPOSITORY" --json nameWithOwner -q .nameWithOwner)"
[[ "$REPO_NAME_WITH_OWNER" == "$REPOSITORY" ]] \
    || die "GitHub target repository가 다릅니다: $REPO_NAME_WITH_OWNER"

echo
echo "원격 refs 최신화"
git -C "$ROOT_DIR" fetch --prune --tags origin

INITIAL_STATE="$PROD_RELEASE_TAG|$STAGING_RELEASE_TAG|$PROD_FEED_VERSION|$PROD_FEED_BUILD|$PROD_FEED_TAG|$STAGING_FEED_VERSION|$STAGING_FEED_BUILD|$STAGING_FEED_TAG"
refresh_release_state
validate_feed_state
REFRESHED_STATE="$PROD_RELEASE_TAG|$STAGING_RELEASE_TAG|$PROD_FEED_VERSION|$PROD_FEED_BUILD|$PROD_FEED_TAG|$STAGING_FEED_VERSION|$STAGING_FEED_BUILD|$STAGING_FEED_TAG"
[[ "$INITIAL_STATE" == "$REFRESHED_STATE" ]] \
    || die "입력 이후 release/feed 상태가 변경됐습니다. 새 상태를 확인하도록 다시 실행하세요."

[[ -z "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=all)" ]] \
    || die "working tree가 clean하지 않습니다."
CURRENT_BRANCH="$(git -C "$ROOT_DIR" branch --show-current)"
[[ "$CURRENT_BRANCH" == "main" ]] || die "release source branch는 main이어야 합니다: $CURRENT_BRANCH"
ORIGIN_URL="$(git -C "$ROOT_DIR" remote get-url origin)"
[[ "$ORIGIN_URL" == "$EXPECTED_ORIGIN_URL" ]] \
    || die "origin URL이 release 기준과 다릅니다: $ORIGIN_URL"
HEAD_SHA="$(git -C "$ROOT_DIR" rev-parse HEAD)"
ORIGIN_MAIN_SHA="$(git -C "$ROOT_DIR" rev-parse origin/main)"
[[ "$HEAD_SHA" == "$ORIGIN_MAIN_SHA" ]] \
    || die "HEAD가 최신 origin/main과 일치하지 않습니다: HEAD=$HEAD_SHA, origin/main=$ORIGIN_MAIN_SHA"

LOCAL_TAG_COMMIT="$(resolve_local_tag_commit "$ROOT_DIR" "$TAG")"
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
if [[ -z "$LOCAL_TAG_COMMIT" && -z "$REMOTE_TAG_COMMIT" ]]; then
    CANDIDATE_TAG_STATE="absent"
elif [[ ( -z "$LOCAL_TAG_COMMIT" || "$LOCAL_TAG_COMMIT" == "$HEAD_SHA" ) \
    && ( -z "$REMOTE_TAG_COMMIT" || "$REMOTE_TAG_COMMIT" == "$HEAD_SHA" ) ]]; then
    CANDIDATE_TAG_STATE="matching"
else
    CANDIDATE_TAG_STATE="mismatched"
fi

if CANDIDATE_RELEASE_LOOKUP="$(
    gh api "repos/$REPOSITORY/releases/tags/$TAG" 2>&1
)"; then
    CANDIDATE_RELEASE_EXISTS=1
else
    if [[ "$CANDIDATE_RELEASE_LOOKUP" == *"HTTP 404"* ]]; then
        CANDIDATE_RELEASE_EXISTS=0
    else
        printf '%s\n' "$CANDIDATE_RELEASE_LOOKUP" >&2
        die "후보 GitHub Release 상태를 확인하지 못했습니다: $TAG"
    fi
fi
if [[ "$CANDIDATE_RELEASE_EXISTS" == "0" ]]; then
    CANDIDATE_RELEASE_STATE="absent"
else
    if [[ "$RELEASE_ENVIRONMENT" == "staging" ]]; then
        EXPECTED_PRERELEASE="true"
        TARGET_LATEST_RELEASE_TAG="$STAGING_RELEASE_TAG"
    else
        EXPECTED_PRERELEASE="false"
        TARGET_LATEST_RELEASE_TAG="$PROD_RELEASE_TAG"
    fi
    CANDIDATE_RELEASE_STATE="$(
        gh release view "$TAG" \
            --repo "$REPOSITORY" \
            --json tagName,isDraft,isPrerelease,assets \
            --jq "if (
                .tagName == \"$TAG\"
                and .isDraft == false
                and .isPrerelease == $EXPECTED_PRERELEASE
                and (.assets | length) == 3
                and (([.assets[].name] | sort) == [\"ClaudeUsage.dmg\", \"ClaudeUsage.zip\", \"appcast.xml\"])
                and all(.assets[]; (
                    .size > 0
                    and (.digest | type) == \"string\"
                    and (.digest | test(\"^sha256:[0-9a-fA-F]{64}$\"))
                ))
            ) then \"complete\" else \"partial\" end"
    )"
    if [[ "$TARGET_LATEST_RELEASE_TAG" != "$TAG" ]]; then
        CANDIDATE_RELEASE_STATE="partial"
    fi
fi

case "$RELEASE_ENVIRONMENT" in
    staging)
        TARGET_FEED_TAG="$STAGING_FEED_TAG"
        TARGET_FEED_VERSION="$STAGING_FEED_VERSION"
        TARGET_FEED_BUILD="$STAGING_FEED_BUILD"
        ;;
    prod)
        TARGET_FEED_TAG="$PROD_FEED_TAG"
        TARGET_FEED_VERSION="$PROD_FEED_VERSION"
        TARGET_FEED_BUILD="$PROD_FEED_BUILD"
        ;;
esac
if [[ "$TARGET_FEED_TAG" == "$TAG" \
    && "$TARGET_FEED_VERSION" == "$VERSION" \
    && "$TARGET_FEED_BUILD" == "$EXPECTED_BUILD" ]]; then
    CANDIDATE_FEED_STATE="candidate"
elif [[ "$(compare_numeric_release_versions "$VERSION" "$TARGET_FEED_VERSION")" == "1" ]]; then
    CANDIDATE_FEED_STATE="previous"
else
    CANDIDATE_FEED_STATE="diverged"
fi

CANDIDATE_STATE="$(
    classify_release_candidate_state \
        "$CANDIDATE_TAG_STATE" \
        "$CANDIDATE_RELEASE_STATE" \
        "$CANDIDATE_FEED_STATE"
)"
case "$CANDIDATE_STATE" in
    fresh|tag_only)
        validate_release_state
        ;;
    pages_pending|complete)
        validate_non_target_release_state
        ;;
    burned)
        die "후보 $TAG 상태가 불완전하거나 분기됐습니다(tag=$CANDIDATE_TAG_STATE, release=$CANDIDATE_RELEASE_STATE, feed=$CANDIDATE_FEED_STATE). 기존 tag/Release/asset은 수정하지 않으며 다음 숫자 버전이 필요합니다."
        ;;
esac
echo "  candidate metadata state: $CANDIDATE_STATE"

if [[ "$RELEASE_ENVIRONMENT" == "prod" ]]; then
    STAGING_CANDIDATE_TAG="$(release_tag_for staging "$VERSION")"
    STAGING_TAG_SHA="$(git -C "$ROOT_DIR" rev-parse "refs/tags/$STAGING_CANDIDATE_TAG^{}" 2>/dev/null)" \
        || die "동일 버전 staging tag가 없습니다: $STAGING_CANDIDATE_TAG"
    [[ "$STAGING_TAG_SHA" == "$HEAD_SHA" ]] \
        || die "prod HEAD와 staging 검증 commit이 다릅니다: HEAD=$HEAD_SHA, staging=$STAGING_TAG_SHA"
    STAGING_RELEASE_METADATA="$(
        gh release view "$STAGING_CANDIDATE_TAG" \
            --repo "$REPOSITORY" \
            --json isDraft,isPrerelease \
            --jq '[.isDraft, .isPrerelease] | @tsv'
    )"
    IFS=$'\t' read -r STAGING_IS_DRAFT STAGING_IS_PRERELEASE <<< "$STAGING_RELEASE_METADATA"
    [[ "$STAGING_IS_DRAFT" == "false" && "$STAGING_IS_PRERELEASE" == "true" ]] \
        || die "동일 버전 staging Release가 검증 가능한 prerelease 상태가 아닙니다."
fi

FINAL_CODE_VERSION="$(read_project_release_version "$PROJECT_FILE")"
FINAL_CODE_BUILD="$(read_project_release_build "$PROJECT_FILE")"
[[ "$FINAL_CODE_VERSION" == "$VERSION" && "$FINAL_CODE_BUILD" == "$EXPECTED_BUILD" ]] \
    || die "fetch 이후 project version/build가 배포 후보와 다릅니다."

case "$CANDIDATE_STATE" in
    pages_pending)
        RUN_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/claudeusage-release-driver.XXXXXX")"
        DRIVER_TMP_DIR="$RUN_ROOT/tmp"
        mkdir -p "$DRIVER_TMP_DIR"
        VERIFIED_CANDIDATE_APPCAST="$RUN_ROOT/appcast.xml"

        echo
        echo "부분 배포 복구: Release 산출물 검증"
        if ! "$VERIFY_SCRIPT" \
            --tag "$TAG" \
            --channel "$RELEASE_ENVIRONMENT" \
            --expected-version "$VERSION" \
            --expected-build "$EXPECTED_BUILD" \
            --export-verified-appcast-to "$VERIFIED_CANDIDATE_APPCAST" \
            --repo "$REPOSITORY"; then
            die "후보 Release가 full verifier를 통과하지 못해 Pages를 변경하지 않았습니다. 일시적 조회 장애를 배제한 뒤에도 재현되면 기존 tag/Release/asset은 수정하지 말고 다음 숫자 버전을 사용하세요."
        fi

        echo
        echo "현재 public feed 기준 산출물 검증: $PREVIOUS_TAG"
        "$VERIFY_SCRIPT" \
            --tag "$PREVIOUS_TAG" \
            --channel "$RELEASE_ENVIRONMENT" \
            --expected-version "$PREVIOUS_VERSION" \
            --expected-build "$PREVIOUS_BUILD" \
            --verify-public-feed \
            --repo "$REPOSITORY"

        repair_pages_from_candidate_release

        echo
        echo "복구된 public feed와 원격 산출물 최종 검증: $TAG"
        "$VERIFY_SCRIPT" \
            --tag "$TAG" \
            --channel "$RELEASE_ENVIRONMENT" \
            --expected-version "$VERSION" \
            --expected-build "$EXPECTED_BUILD" \
            --verify-public-feed \
            --repo "$REPOSITORY"

        echo
        cat <<EOF
부분 배포 복구 및 원격 검증 완료
  channel:       $RELEASE_ENVIRONMENT
  tag:           $TAG
  version/build: $VERSION ($EXPECTED_BUILD)
  source:        $HEAD_SHA
  local temp:    정리 완료

기존 tag, Release, asset은 수정하지 않고 Pages와 public feed만 복구했습니다.
EOF
        exit 0
        ;;
    complete)
        echo
        echo "이미 완료된 배포의 원격 산출물과 public feed 재검증: $TAG"
        if ! "$VERIFY_SCRIPT" \
            --tag "$TAG" \
            --channel "$RELEASE_ENVIRONMENT" \
            --expected-version "$VERSION" \
            --expected-build "$EXPECTED_BUILD" \
            --verify-public-feed \
            --repo "$REPOSITORY"; then
            die "완료로 보이던 후보가 full verifier를 통과하지 못했습니다. 원격을 수정하지 않았으며, 일시적 조회 장애가 아니라면 다음 숫자 버전으로 복구해야 합니다."
        fi

        echo
        cat <<EOF
기존 배포 원격 검증 완료
  channel:       $RELEASE_ENVIRONMENT
  tag:           $TAG
  version/build: $VERSION ($EXPECTED_BUILD)
  source:        $HEAD_SHA

tag, Release, asset, Pages, Downloads 및 로컬 build를 변경하지 않았습니다.
EOF
        exit 0
        ;;
esac

echo
echo "notary profile 사전 검증: $NOTARY_PROFILE"
xcrun notarytool history \
    --keychain-profile "$NOTARY_PROFILE" \
    --output-format json \
    --no-progress >/dev/null

echo
echo "release driver shell 회귀 테스트"
TMPDIR="${TMPDIR:-/tmp}" "$DRIVER_TEST_SCRIPT"

RUN_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/claudeusage-release-driver.XXXXXX")"
BUILD_DIR="$RUN_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/ClaudeUsage.xcarchive"
ARCHIVE_DERIVED_DATA="$RUN_ROOT/archive-derived-data"
DRIVER_TMP_DIR="$RUN_ROOT/tmp"
TEST_DERIVED_DATA="$RUN_ROOT/test/DerivedData"
TEST_RESULT_BUNDLE="$RUN_ROOT/test/ClaudeUsageTests.xcresult"
mkdir -p "$RUN_ROOT/test" "$DRIVER_TMP_DIR"

echo
echo "전체 XCTest 실행"
TMPDIR="$DRIVER_TMP_DIR" xcodebuild \
    -project "$ROOT_DIR/ClaudeUsage.xcodeproj" \
    -scheme ClaudeUsage \
    -destination 'platform=macOS' \
    -derivedDataPath "$TEST_DERIVED_DATA" \
    -resultBundlePath "$TEST_RESULT_BUNDLE" \
    test
TEST_SUMMARY="$(
    xcrun xcresulttool get test-results summary \
        --path "$TEST_RESULT_BUNDLE" \
        --compact
)"
echo "$TEST_SUMMARY"
rm -rf "$TEST_DERIVED_DATA" "$TEST_RESULT_BUNDLE"
rm -rf "$RUN_ROOT/test"
[[ ! -e "$RUN_ROOT/test" ]] || die "XCTest 임시 디렉터리를 정리하지 못했습니다."
echo "XCTest 임시 DerivedData/xcresult 정리 완료"

echo
echo "이전 동일 채널 앱 준비: $PREVIOUS_TAG"
"$VERIFY_SCRIPT" \
    --tag "$PREVIOUS_TAG" \
    --channel "$RELEASE_ENVIRONMENT" \
    --expected-version "$PREVIOUS_VERSION" \
    --expected-build "$PREVIOUS_BUILD" \
    --install-to "$DOWNLOADS_APP_PATH" \
    --verify-public-feed \
    --repo "$REPOSITORY"

echo
echo "notarized release build"
env \
    "TMPDIR=$DRIVER_TMP_DIR" \
    "GH_HOST=github.com" \
    "GH_REPO=$REPOSITORY" \
    "BUILD_DIR=$BUILD_DIR" \
    "ARCHIVE_PATH=$ARCHIVE_PATH" \
    "ZIP_PATH=$BUILD_DIR/ClaudeUsage.zip" \
    "DMG_PATH=$BUILD_DIR/ClaudeUsage.dmg" \
    "SCHEME=ClaudeUsage" \
    "CONFIGURATION=Release" \
    "PROJECT_PATH=$PROJECT_PATH" \
    "XC_CONFIG_PATH=$RELEASE_XCCONFIG_PATH" \
    "LOCAL_XC_CONFIG_PATH=$LOCAL_RELEASE_XCCONFIG_PATH" \
    "DERIVED_DATA_PATH=$ARCHIVE_DERIVED_DATA" \
    "ENTITLEMENTS_PATH=$ENTITLEMENTS_PATH" \
    "SKIP_DMG=0" \
    "RELEASE_CHANNEL=$RELEASE_ENVIRONMENT" \
    "RELEASE_DISTRIBUTION=notarized" \
    "NOTARY_PROFILE=$NOTARY_PROFILE" \
    "NOTARY_APPLE_ID=" \
    "NOTARY_PASSWORD=" \
    "NOTARY_TEAM_ID=" \
    "NOTARY_KEY_PATH=" \
    "NOTARY_KEY_ID=" \
    "NOTARY_ISSUER=" \
    "APP_STORE_CONNECT_API_KEY_P8=" \
    "APP_STORE_CONNECT_KEY_ID=" \
    "APP_STORE_CONNECT_ISSUER_ID=" \
    "APPLE_ID=" \
    "APPLE_PASSWORD=" \
    "APPLE_TEAM_ID=" \
    "DEVELOPMENT_TEAM=" \
    "SU_FEED_URL=$FEED_URL" \
    "SU_PUBLIC_ED_KEY=" \
    "VOLUME_NAME=Install ClaudeUsage" \
    "BACKGROUND_PNG=$ROOT_DIR/Scripts/dmg-assets/background.png" \
    "VOLUME_ICON=$ARCHIVE_PATH/Products/Applications/ClaudeUsage.app/Contents/Resources/AppIcon.icns" \
    "APP_ICON_X=150" \
    "APP_ICON_Y=190" \
    "APPS_ICON_X=390" \
    "APPS_ICON_Y=190" \
    "WINDOW_W=540" \
    "WINDOW_H=380" \
    "$BUILD_SCRIPT"

LOCAL_APP="$ARCHIVE_PATH/Products/Applications/ClaudeUsage.app"
LOCAL_INFO="$LOCAL_APP/Contents/Info.plist"
[[ -d "$LOCAL_APP" && -f "$LOCAL_INFO" ]] || die "release archive 앱을 찾지 못했습니다: $LOCAL_APP"
LOCAL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$LOCAL_INFO")"
LOCAL_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$LOCAL_INFO")"
LOCAL_FEED="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$LOCAL_INFO")"
[[ "$LOCAL_VERSION" == "$VERSION" ]] || die "release app version이 다릅니다: $LOCAL_VERSION"
[[ "$LOCAL_BUILD" == "$EXPECTED_BUILD" ]] || die "release app build가 다릅니다: $LOCAL_BUILD"
[[ "$LOCAL_FEED" == "$FEED_URL" ]] || die "release app feed URL이 다릅니다: $LOCAL_FEED"
SPARKLE_TOOLS_DIR="$ARCHIVE_DERIVED_DATA/SourcePackages/artifacts/sparkle/Sparkle/bin"
[[ -x "$SPARKLE_TOOLS_DIR/generate_appcast" && -x "$SPARKLE_TOOLS_DIR/sign_update" ]] \
    || die "격리된 DerivedData에서 Sparkle release tool을 찾지 못했습니다: $SPARKLE_TOOLS_DIR"

echo
echo "게시 직전 최종 확인"
echo "  source:      main@$HEAD_SHA"
echo "  channel:     $RELEASE_ENVIRONMENT"
echo "  version:     $VERSION ($EXPECTED_BUILD)"
echo "  tag:         $TAG"
echo "  previous QA: $DOWNLOADS_APP_PATH <= $PREVIOUS_TAG"
echo "  artifacts:   $BUILD_DIR"

if [[ "$NON_INTERACTIVE" == "1" ]]; then
    [[ "$CONFIRM_PUBLISH" == "$TAG" ]] \
        || die "non-interactive 게시는 --confirm-publish '$TAG'가 정확히 필요합니다."
else
    [[ -t 0 ]] || die "게시 확인 입력을 받을 TTY가 없습니다. --non-interactive와 --confirm-publish를 사용하세요."
    read -r -p "게시하려면 exact tag '$TAG'를 입력하세요: " CONFIRM_PUBLISH
    [[ "$CONFIRM_PUBLISH" == "$TAG" ]] || die "exact tag 확인이 일치하지 않아 게시하지 않습니다."
fi

PUBLISH_ARGS=(
    "$TAG"
    --channel "$RELEASE_ENVIRONMENT"
    --expected-commit "$HEAD_SHA"
    --skip-pages-publish
)
if [[ "$RELEASE_ENVIRONMENT" == "staging" ]]; then
    PUBLISH_ARGS+=(--prerelease)
fi
if [[ "$CANDIDATE_STATE" == "tag_only" ]]; then
    PUBLISH_ARGS+=(--resume-exact-tag)
fi
if [[ -n "$NOTES" ]]; then
    PUBLISH_ARGS+=(--notes "$NOTES")
fi

echo
echo "GitHub Release 및 appcast 게시"
env \
    "TMPDIR=$DRIVER_TMP_DIR" \
    "GH_HOST=github.com" \
    "GH_REPO=$REPOSITORY" \
    "BUILD_DIR=$BUILD_DIR" \
    "DMG_PATH=$BUILD_DIR/ClaudeUsage.dmg" \
    "ZIP_PATH=$BUILD_DIR/ClaudeUsage.zip" \
    "APPCAST_PATH=$BUILD_DIR/appcast.xml" \
    "LOCAL_XC_CONFIG_PATH=$LOCAL_RELEASE_XCCONFIG_PATH" \
    "SPARKLE_TOOLS_DIR=$SPARKLE_TOOLS_DIR" \
    "SU_FEED_URL=$FEED_URL" \
    "DOWNLOAD_BASE_URL=https://github.com/$REPOSITORY/releases/download/$TAG" \
    "RELEASE_TAG=$TAG" \
    "$PUBLISH_SCRIPT" "${PUBLISH_ARGS[@]}"

rm -rf "$ARCHIVE_DERIVED_DATA"
[[ ! -e "$ARCHIVE_DERIVED_DATA" ]] \
    || die "archive DerivedData를 정리하지 못했습니다: $ARCHIVE_DERIVED_DATA"
echo "archive DerivedData 정리 완료"

rm -rf "$BUILD_DIR"
[[ ! -e "$BUILD_DIR" ]] || die "로컬 release build 산출물을 정리하지 못했습니다: $BUILD_DIR"
echo "로컬 release build 산출물 정리 완료: $BUILD_DIR"

VERIFIED_CANDIDATE_APPCAST="$RUN_ROOT/appcast.xml"
echo
echo "public feed 게시 전 새 원격 산출물 검증: $TAG"
if ! "$VERIFY_SCRIPT" \
    --tag "$TAG" \
    --channel "$RELEASE_ENVIRONMENT" \
    --expected-version "$VERSION" \
    --expected-build "$EXPECTED_BUILD" \
    --export-verified-appcast-to "$VERIFIED_CANDIDATE_APPCAST" \
    --repo "$REPOSITORY"; then
    die "새 Release가 full verifier를 통과하지 못해 public feed를 변경하지 않았습니다. 일시적 조회 장애를 배제한 뒤에도 재현되면 기존 tag/Release/asset은 수정하지 말고 다음 숫자 버전을 사용하세요."
fi

echo
echo "검증된 appcast public Pages 게시"
repair_pages_from_candidate_release

echo
echo "새 원격 산출물 재다운로드 검증: $TAG"
"$VERIFY_SCRIPT" \
    --tag "$TAG" \
    --channel "$RELEASE_ENVIRONMENT" \
    --expected-version "$VERSION" \
    --expected-build "$EXPECTED_BUILD" \
    --verify-public-feed \
    --repo "$REPOSITORY"

echo
cat <<EOF
배포 및 원격 검증 완료
  channel:       $RELEASE_ENVIRONMENT
  tag:           $TAG
  version/build: $VERSION ($EXPECTED_BUILD)
  source:        $HEAD_SHA
  local temp:    정리 완료
  upgrade app:   $DOWNLOADS_APP_PATH ($PREVIOUS_TAG)

Downloads 앱은 새 후보가 아니라 이전 동일 채널 앱으로 유지했습니다.
이 앱에서 Sparkle 업데이트를 실행해 실제 upgrade QA를 진행할 수 있습니다.
EOF
