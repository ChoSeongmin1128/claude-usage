#!/usr/bin/env bash

# Pure helpers shared by the release driver and its shell tests.
# Keep network, Git mutation, signing, and filesystem installation out of this file.

normalize_release_environment() {
    case "${1:-}" in
        stg|staging)
            printf 'staging\n'
            ;;
        prod)
            printf 'prod\n'
            ;;
        *)
            return 1
            ;;
    esac
}

validate_numeric_release_version() {
    local version="${1:-}"
    local major minor patch

    [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || return 1
    IFS='.' read -r major minor patch <<< "$version"

    # Keep the established numeric marketing-version range. Build numbers are
    # independent monotonic integers; do not derive new builds from this value.
    (( ${#major} <= 6 )) || return 1
    (( 10#$minor <= 99 )) || return 1
    (( 10#$patch <= 99 )) || return 1
    # Stay safely within signed 32-bit CFBundleVersion consumers.
    (( 10#$major <= 214747 )) || return 1
}

validate_release_build_number() {
    local value="${1:-}"
    [[ "$value" =~ ^[1-9][0-9]*$ && ${#value} -le 10 ]] || return 1
    (( 10#$value <= 2147483647 ))
}

release_tag_for() {
    local environment="${1:-}"
    local version="${2:-}"
    local candidate="${3:-}"

    validate_numeric_release_version "$version" || return 1
    case "$environment" in
        staging)
            validate_release_build_number "$candidate" || return 1
            printf 'v%s-stg.%s\n' "$version" "$candidate"
            ;;
        prod)
            [[ -z "$candidate" ]] || return 1
            printf 'v%s\n' "$version"
            ;;
        *)
            return 1
            ;;
    esac
}

release_feed_url_for() {
    case "${1:-}" in
        staging)
            printf 'https://choseongmin1128.github.io/claude-usage/channels/staging/appcast.xml\n'
            ;;
        prod)
            printf 'https://choseongmin1128.github.io/claude-usage/appcast.xml\n'
            ;;
        *)
            return 1
            ;;
    esac
}

release_version_from_tag() {
    local tag="${1:-}"

    if [[ "$tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)(-staging|-stg\.[1-9][0-9]*)?$ ]]; then
        local version="${BASH_REMATCH[1]}"
        validate_numeric_release_version "$version" || return 1
        printf '%s\n' "$version"
        return 0
    fi
    return 1
}

release_candidate_from_tag() {
    local tag="${1:-}"
    release_version_from_tag "$tag" >/dev/null || return 1
    if [[ "$tag" =~ -stg\.([1-9][0-9]*)$ ]]; then
        local candidate="${BASH_REMATCH[1]}"
        validate_release_build_number "$candidate" || return 1
        printf '%s\n' "$candidate"
    elif [[ "$tag" == *-staging ]]; then
        printf '0\n'
    else
        return 1
    fi
}

validate_release_tag_identity() {
    local tag="$1" channel="$2" version="$3"
    [[ "$(release_version_from_tag "$tag")" == "$version" ]] || return 1
    case "$channel" in
        staging) release_candidate_from_tag "$tag" >/dev/null ;;
        prod) [[ "$tag" == "v$version" ]] ;;
        *) return 1 ;;
    esac
}

compare_numeric_release_versions() {
    local lhs="${1:-}"
    local rhs="${2:-}"
    local lhs_major lhs_minor lhs_patch
    local rhs_major rhs_minor rhs_patch

    validate_numeric_release_version "$lhs" || return 2
    validate_numeric_release_version "$rhs" || return 2
    IFS='.' read -r lhs_major lhs_minor lhs_patch <<< "$lhs"
    IFS='.' read -r rhs_major rhs_minor rhs_patch <<< "$rhs"

    if (( 10#$lhs_major > 10#$rhs_major )); then
        printf '1\n'
    elif (( 10#$lhs_major < 10#$rhs_major )); then
        printf '%s\n' '-1'
    elif (( 10#$lhs_minor > 10#$rhs_minor )); then
        printf '1\n'
    elif (( 10#$lhs_minor < 10#$rhs_minor )); then
        printf '%s\n' '-1'
    elif (( 10#$lhs_patch > 10#$rhs_patch )); then
        printf '1\n'
    elif (( 10#$lhs_patch < 10#$rhs_patch )); then
        printf '%s\n' '-1'
    else
        printf '0\n'
    fi
}

# 2.4.0에서 prod/staging 채널 식별자가 Info.plist에 명시적으로 추가됐다.
# 그보다 오래된 prod 배포본은 CFBundleDisplayName과
# ClaudeUsageReleaseChannel이 없으므로, 이전 버전 upgrade 검증에서만
# 서명된 CFBundleName과 prod bundle/feed identity를 사용한다.
release_artifact_identity_metadata_policy() {
    local environment="${1:-}"
    local version="${2:-}"
    local comparison

    [[ "$environment" == "prod" || "$environment" == "staging" ]] || return 1
    validate_numeric_release_version "$version" || return 1
    comparison="$(compare_numeric_release_versions "$version" "2.4.0")" || return 1

    if [[ "$environment" == "prod" && "$comparison" == "-1" ]]; then
        printf 'legacy-prod\n'
    else
        printf 'strict\n'
    fi
}

release_cleanup_exit_code() {
    local original_status="${1:-}"
    local cleanup_failed="${2:-}"
    local restore_failed="${3:-}"

    [[ "$original_status" =~ ^[0-9]+$ ]] || return 1
    [[ "$cleanup_failed" == "0" || "$cleanup_failed" == "1" ]] || return 1
    [[ "$restore_failed" == "0" || "$restore_failed" == "1" ]] || return 1

    if [[ "$original_status" == "0" \
        && ( "$cleanup_failed" == "1" || "$restore_failed" == "1" ) ]]; then
        printf '1\n'
    else
        printf '%s\n' "$original_status"
    fi
}

# `git rev-parse <ref>`는 해석하지 못한 ref를 stdout에 그대로 출력하고 non-zero로
# 끝난다. `|| true`로 종료 코드만 삼키면 그 리터럴 문자열이 commit SHA인 것처럼
# 흘러가, 아직 존재하지 않는 새 tag가 mismatched로 오판된다. `--verify --quiet`은
# 해석에 실패하면 아무것도 출력하지 않으므로 "없음"을 빈 문자열로 표현할 수 있다.
resolve_local_tag_commit() {
    local repository="$1"
    local tag="$2"

    git -C "$repository" rev-parse --verify --quiet "refs/tags/$tag^{commit}" || true
}

# 같은 팀에 Developer ID Application 인증서가 여러 개 있을 때 어느 것으로
# 서명하는지는 임의로 정할 수 없다. 서명 인증서가 바뀌면 기존 사용자의 Keychain
# ACL 연속성이 끊겨 업데이트 후 자격증명 접근에 prompt가 뜬다. 그래서 같은 채널의
# 현재 배포본이 실제로 쓴 인증서와 일치하는 후보만 고른다.
#
# 반환: 0 선택 성공(stdout에 SHA-1) / 1 후보 없음 / 2 기준 없음 / 3 기준 불일치
select_signing_certificate() {
    local reference_sha="$1"
    shift
    local candidates=("$@")

    [[ "${#candidates[@]}" -gt 0 ]] || return 1
    if [[ "${#candidates[@]}" -eq 1 ]]; then
        printf '%s\n' "${candidates[0]}"
        return 0
    fi
    [[ -n "$reference_sha" ]] || return 2

    local candidate
    for candidate in "${candidates[@]}"; do
        if [[ "$candidate" == "$reference_sha" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 3
}

classify_release_candidate_state() {
    local tag_state="${1:-}"
    local release_state="${2:-}"
    local feed_state="${3:-}"

    case "$tag_state" in
        absent|matching|mismatched) ;;
        *) return 1 ;;
    esac
    case "$release_state" in
        absent|complete|partial) ;;
        *) return 1 ;;
    esac
    case "$feed_state" in
        previous|candidate|diverged) ;;
        *) return 1 ;;
    esac

    case "$tag_state|$release_state|$feed_state" in
        absent\|absent\|previous)
            printf 'fresh\n'
            ;;
        matching\|absent\|previous)
            printf 'tag_only\n'
            ;;
        matching\|complete\|previous)
            printf 'pages_pending\n'
            ;;
        matching\|complete\|candidate)
            printf 'complete\n'
            ;;
        *)
            printf 'burned\n'
            ;;
    esac
}

read_unique_xcode_build_setting() {
    local project_file="${1:-}"
    local key="${2:-}"

    [[ "$project_file" == "-" || -f "$project_file" ]] || return 1
    awk -v target="$key" '
        $0 ~ "^[[:space:]]*" target "[[:space:]]*=" {
            value = $0
            sub("^[[:space:]]*" target "[[:space:]]*=[[:space:]]*", "", value)
            sub(/[[:space:]]*;[[:space:]]*$/, "", value)
            seen[value] = 1
        }
        END {
            count = 0
            for (value in seen) {
                result = value
                count += 1
            }
            if (count != 1) {
                exit 3
            }
            print result
        }
    ' "$project_file"
}

read_project_release_version() {
    read_unique_xcode_build_setting "$1" "MARKETING_VERSION"
}

read_project_release_build() {
    read_unique_xcode_build_setting "$1" "CURRENT_PROJECT_VERSION"
}

# 이미 배포된 앱의 leaf 서명 인증서 SHA-1. 후보가 여러 개일 때 어느 인증서가
# "현재 쓰이고 있는 것"인지 판단하는 기준이 된다.
resolve_app_signing_certificate_sha1() {
    local app_path="$1"
    [[ -d "$app_path" ]] || return 1

    local work
    work="$(mktemp -d "${TMPDIR:-/tmp}/claudeusage-cert.XXXXXX")" || return 1
    local sha=""
    if codesign -d --extract-certificates="$work/cert" "$app_path" >/dev/null 2>&1 \
        && [[ -f "$work/cert0" ]]; then
        sha="$(openssl x509 -inform DER -in "$work/cert0" -noout -fingerprint -sha1 2>/dev/null \
            | sed 's/.*=//; s/://g' \
            | tr '[:lower:]' '[:upper:]')" || sha=""
    fi
    rm -rf "$work"

    [[ "$sha" =~ ^[0-9A-F]{40}$ ]] || return 1
    printf '%s\n' "$sha"
}
