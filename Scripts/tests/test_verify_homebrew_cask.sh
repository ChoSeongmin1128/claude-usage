#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/claudeusage-homebrew-verify-tests.XXXXXX")"
BIN="$TEST_ROOT/bin"
TAP_REPOSITORY="$TEST_ROOT/tap"
MANIFEST="$TEST_ROOT/manifest.json"
CASK="$TAP_REPOSITORY/Casks/claude-usage.rb"
TRACE="$TEST_ROOT/brew.log"

cleanup() {
    local exit_code=$?
    rm -rf "$TEST_ROOT"
    exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

mkdir -p "$BIN" "$TAP_REPOSITORY/Casks"
python3 "$ROOT_DIR/Scripts/lib/homebrew_cask.py" manifest \
    --repository ChoSeongmin1128/claude-usage \
    --tag v2.5.3 \
    --version 2.5.3 \
    --build 20506 \
    --asset-url https://github.com/ChoSeongmin1128/claude-usage/releases/download/v2.5.3/ClaudeUsage.dmg \
    --asset-size 6157946 \
    --asset-sha256 562fd8f825d3362a2773668cd8770f060ac7b846b041e25b9e9f48692782a1ca \
    --bundle-identifier com.seongmin.ClaudeUsage \
    --feed-url https://choseongmin1128.github.io/claude-usage/appcast.xml \
    --team-identifier ABCDE12345 \
    --minimum-system-version 14.0 \
    > "$MANIFEST"
python3 "$ROOT_DIR/Scripts/lib/homebrew_cask.py" render --manifest "$MANIFEST" > "$CASK"

cat > "$BIN/brew" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf '<%s>\n' "$*" >> "${HOMEBREW_VERIFY_TRACE:?}"
case "${1:-}" in
    --repository)
        printf '%s\n' "${HOMEBREW_VERIFY_TAP_REPOSITORY:?}"
        ;;
    style|audit|fetch)
        ;;
    livecheck)
        printf '[{"cask":"claude-usage","version":{"current":"2.5.3","latest":"2.5.3","outdated":false,"newer_than_upstream":false}}]\n'
        ;;
    info)
        cat <<'JSON'
{"casks":[{"token":"claude-usage","version":"2.5.3","sha256":"562fd8f825d3362a2773668cd8770f060ac7b846b041e25b9e9f48692782a1ca","url":"https://github.com/ChoSeongmin1128/claude-usage/releases/download/v2.5.3/ClaudeUsage.dmg","auto_updates":true,"artifacts":[{"app":["ClaudeUsage.app"]}],"depends_on":{"macos":{">=":["14"]}}}]}
JSON
        ;;
    *)
        exit 97
        ;;
esac
SCRIPT
chmod +x "$BIN/brew"

: > "$TRACE"
env \
    "PATH=$BIN:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "HOMEBREW_VERIFY_TRACE=$TRACE" \
    "HOMEBREW_VERIFY_TAP_REPOSITORY=$TAP_REPOSITORY" \
    "$ROOT_DIR/Scripts/verify-homebrew-cask.sh" --manifest "$MANIFEST" >/dev/null

for expected in \
    "<--repository choseongmin1128/tap>" \
    "<style --cask choseongmin1128/tap/claude-usage>" \
    "<audit --cask --strict --online choseongmin1128/tap/claude-usage>" \
    "<livecheck --cask --json choseongmin1128/tap/claude-usage>" \
    "<info --json=v2 --cask choseongmin1128/tap/claude-usage>" \
    "<fetch --cask choseongmin1128/tap/claude-usage>"; do
    grep -F -- "$expected" "$TRACE" >/dev/null
done

printf '# drift\n' >> "$CASK"
if env \
    "PATH=$BIN:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "HOMEBREW_VERIFY_TRACE=$TRACE" \
    "HOMEBREW_VERIFY_TAP_REPOSITORY=$TAP_REPOSITORY" \
    "$ROOT_DIR/Scripts/verify-homebrew-cask.sh" --manifest "$MANIFEST" >/dev/null 2>&1; then
    echo "변조된 Cask 검증은 실패해야 합니다." >&2
    exit 1
fi

echo "Homebrew Cask verifier 테스트 통과"
