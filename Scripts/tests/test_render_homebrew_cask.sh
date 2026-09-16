#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/claudeusage-homebrew-render-tests.XXXXXX")"

cleanup() {
    local exit_code=$?
    rm -rf "$TEST_ROOT"
    exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

mkdir -p "$TEST_ROOT/Casks"
MANIFEST="$TEST_ROOT/manifest.json"
CASK="$TEST_ROOT/Casks/claude-usage.rb"
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

DRY_OUTPUT="$("$ROOT_DIR/Scripts/render-homebrew-cask.sh" --manifest "$MANIFEST" --output "$CASK")"
[[ "$DRY_OUTPUT" == *"state=absent"* && ! -e "$CASK" ]]

"$ROOT_DIR/Scripts/render-homebrew-cask.sh" \
    --manifest "$MANIFEST" --output "$CASK" --write >/dev/null
[[ "$(python3 "$ROOT_DIR/Scripts/lib/homebrew_cask.py" classify --manifest "$MANIFEST" --cask "$CASK")" == matching ]]

BEFORE_SHA="$(shasum -a 256 "$CASK" | awk '{print $1}')"
"$ROOT_DIR/Scripts/render-homebrew-cask.sh" \
    --manifest "$MANIFEST" --output "$CASK" --write >/dev/null
[[ "$(shasum -a 256 "$CASK" | awk '{print $1}')" == "$BEFORE_SHA" ]]

sed -i '' 's/version "2.5.3"/version "2.5.4"/' "$CASK"
if "$ROOT_DIR/Scripts/render-homebrew-cask.sh" \
    --manifest "$MANIFEST" --output "$CASK" --write >/dev/null 2>&1; then
    echo "더 최신 Cask를 덮어쓰면 안 됩니다." >&2
    exit 1
fi

python3 "$ROOT_DIR/Scripts/lib/homebrew_cask.py" render --manifest "$MANIFEST" > "$CASK"
printf '# drift\n' >> "$CASK"
if "$ROOT_DIR/Scripts/render-homebrew-cask.sh" \
    --manifest "$MANIFEST" --output "$CASK" --write >/dev/null 2>&1; then
    echo "예상 밖 Cask 구조를 덮어쓰면 안 됩니다." >&2
    exit 1
fi

echo "Homebrew Cask renderer 테스트 통과"
