#!/usr/bin/env bash

# GitHub CLI 토큰을 gh 호출에만 넘긴다. 토큰은 export하지 않은 셸 변수에만 두므로
# xcodebuild, notarytool, git 같은 다른 자식 프로세스의 환경에는 들어가지 않는다.
# gh의 전역 활성 계정은 다른 세션과 공유하므로 바꾸지 않는다.

# 호출자가 넘긴 GH_TOKEN(없으면 GITHUB_TOKEN)을 gh 전용으로 옮긴다. 둘 다 없으면 gh에 저장된 로그인을 쓴다.
scope_github_cli_token() {
    local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
    unset GH_TOKEN GITHUB_TOKEN SCOPED_GITHUB_CLI_TOKEN
    SCOPED_GITHUB_CLI_TOKEN="$token"
}

# gh에 저장된 계정 토큰을 이후 gh 호출에 고정한다. 호출자가 넘긴 토큰은 버린다.
pin_github_cli_account_token() {
    local account="$1" token
    unset GH_TOKEN GITHUB_TOKEN SCOPED_GITHUB_CLI_TOKEN
    SCOPED_GITHUB_CLI_TOKEN=""
    token="$(command gh auth token --hostname github.com --user "$account")" || return 1
    [[ -n "$token" ]] || return 1
    SCOPED_GITHUB_CLI_TOKEN="$token"
}

# gh를 호출하는 하위 스크립트에 토큰을 넘긴다. 하위 스크립트는 scope_github_cli_token으로 다시 좁힌다.
with_github_cli_token() {
    if [[ -n "${SCOPED_GITHUB_CLI_TOKEN:-}" ]]; then
        GH_TOKEN="$SCOPED_GITHUB_CLI_TOKEN" "$@"
    else
        "$@"
    fi
}

gh() {
    with_github_cli_token command gh "$@"
}
