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

    # New releases from 2.4.0 use:
    #   major * 10000 + minor * 100 + patch
    # Older 2.3.x releases used a historical patch * 10 convention. That legacy
    # value must be read from its published metadata, never re-derived here.
    (( ${#major} <= 6 )) || return 1
    (( 10#$minor <= 99 )) || return 1
    (( 10#$patch <= 99 )) || return 1
    # Stay safely within signed 32-bit CFBundleVersion consumers.
    (( 10#$major <= 214747 )) || return 1
}

derive_release_build_number() {
    local version="${1:-}"
    local major minor patch

    validate_numeric_release_version "$version" || return 1
    IFS='.' read -r major minor patch <<< "$version"
    printf '%d\n' "$((10#$major * 10000 + 10#$minor * 100 + 10#$patch))"
}

release_tag_for() {
    local environment="${1:-}"
    local version="${2:-}"

    validate_numeric_release_version "$version" || return 1
    case "$environment" in
        staging)
            printf 'v%s-staging\n' "$version"
            ;;
        prod)
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

    if [[ "$tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)(-staging)?$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
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

    [[ -f "$project_file" ]] || return 1
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
