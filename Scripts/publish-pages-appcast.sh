#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APPCAST_SOURCE="${APPCAST_SOURCE:-$ROOT_DIR/build/release/appcast.xml}"
GHPAGES_BRANCH="${GHPAGES_BRANCH:-gh-pages}"

FEED_URL=""
CHANNEL=""
TAG=""
COMMIT_MESSAGE=""

validate_channel() {
    case "${1:-}" in
        prod|staging) ;;
        *)
            echo "지원하지 않는 채널입니다: ${1:-<empty>} (prod 또는 staging만 허용)" >&2
            exit 2
            ;;
    esac
}

derive_repo_pages_metadata() {
    local name_with_owner=""
    local remote_url=""

    if command -v gh >/dev/null 2>&1; then
        name_with_owner="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
    fi

    if [[ "$name_with_owner" =~ ^([^/]+)/([^/]+)$ ]]; then
        REPO_OWNER="${BASH_REMATCH[1]}"
        REPO_NAME="${BASH_REMATCH[2]}"
    else
        remote_url="$(git -C "$ROOT_DIR" config --get remote.origin.url 2>/dev/null || echo "")"
        if [[ "$remote_url" =~ github\.com[:/](.+)/(.+?)(\.git)?$ ]]; then
            REPO_OWNER="${BASH_REMATCH[1]}"
            REPO_NAME="${BASH_REMATCH[2]}"
        else
            echo "remote.origin URL 에서 GitHub 저장소를 추론하지 못했습니다." >&2
            exit 1
        fi
    fi

    REPO_OWNER_LOWER="$(printf '%s' "$REPO_OWNER" | tr '[:upper:]' '[:lower:]')"
    PAGES_BASE_URL="https://${REPO_OWNER_LOWER}.github.io/${REPO_NAME}"
    PAGES_SITE_PATH="/${REPO_NAME}"
}

derive_default_feed_url_for_channel() {
    local channel="$1"
    case "$channel" in
        prod) printf '%s/appcast.xml\n' "$PAGES_BASE_URL" ;;
        staging) printf '%s/channels/staging/appcast.xml\n' "$PAGES_BASE_URL" ;;
    esac
}

infer_channel_from_feed_path() {
    local path="$1"
    case "$path" in
        appcast.xml|channels/prod/appcast.xml) printf 'prod\n' ;;
        channels/staging/appcast.xml) printf 'staging\n' ;;
        *)
            echo "feed URL 경로에서 채널을 추론하지 못했습니다: $path" >&2
            exit 1
            ;;
    esac
}

build_index_html() {
    local output_path="$1"
    local prod_root_link=""
    local prod_channel_link=""
    local staging_link=""

    [[ -f "$WORKTREE_DIR/appcast.xml" ]] && prod_root_link="      <li><a href=\"$PAGES_SITE_PATH/appcast.xml\">prod appcast (root alias)</a></li>"
    [[ -f "$WORKTREE_DIR/channels/prod/appcast.xml" ]] && prod_channel_link="      <li><a href=\"$PAGES_SITE_PATH/channels/prod/appcast.xml\">prod appcast (channel)</a></li>"
    [[ -f "$WORKTREE_DIR/channels/staging/appcast.xml" ]] && staging_link="      <li><a href=\"$PAGES_SITE_PATH/channels/staging/appcast.xml\">staging appcast</a></li>"

    cat > "$output_path" <<EOF
<!DOCTYPE html>
<html lang="ko">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>ClaudeUsage Update Channels</title>
</head>
<body>
  <main>
    <h1>ClaudeUsage Update Channels</h1>
    <p>이 Pages 브랜치는 Sparkle appcast 채널을 제공합니다.</p>
    <ul>
${prod_root_link}
${prod_channel_link}
${staging_link}
    </ul>
  </main>
</body>
</html>
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --feed-url)
            FEED_URL="$2"
            shift 2
            ;;
        --channel)
            CHANNEL="$2"
            shift 2
            ;;
        --tag)
            TAG="$2"
            shift 2
            ;;
        --message)
            COMMIT_MESSAGE="$2"
            shift 2
            ;;
        -h|--help)
            cat <<USAGE
사용법:
    $0 [--feed-url URL] [--channel prod|staging] [--tag vX.Y.Z] [--message "커밋 메시지"]

비고:
    - appcast.xml 을 gh-pages 브랜치에 게시합니다.
    - prod 채널은 root /appcast.xml 과 /channels/prod/appcast.xml 을 함께 갱신합니다.
    - staging 채널은 /channels/staging/appcast.xml 만 갱신합니다.
USAGE
            exit 0
            ;;
        *)
            echo "알 수 없는 인자: $1" >&2
            exit 2
            ;;
    esac
done

[[ -f "$APPCAST_SOURCE" ]] || {
    echo "게시할 appcast.xml 을 찾지 못했습니다: $APPCAST_SOURCE" >&2
    exit 1
}

derive_repo_pages_metadata

if [[ -n "$CHANNEL" ]]; then
    validate_channel "$CHANNEL"
fi

if [[ -z "$FEED_URL" ]]; then
    if [[ -z "$CHANNEL" ]]; then
        echo "--feed-url 또는 --channel 중 하나는 필요합니다." >&2
        exit 2
    fi
    FEED_URL="$(derive_default_feed_url_for_channel "$CHANNEL")"
fi

case "$FEED_URL" in
    "$PAGES_BASE_URL"/appcast.xml)
        RELATIVE_FEED_PATH="appcast.xml"
        ;;
    "$PAGES_BASE_URL"/channels/*)
        RELATIVE_FEED_PATH="${FEED_URL#"$PAGES_BASE_URL"/}"
        ;;
    *)
        echo "GitHub Pages feed URL 만 지원합니다: $FEED_URL" >&2
        exit 1
        ;;
esac

if [[ -z "$CHANNEL" ]]; then
    CHANNEL="$(infer_channel_from_feed_path "$RELATIVE_FEED_PATH")"
fi

WORKTREE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/claudeusage-gh-pages.XXXXXX")"
cleanup() {
    git -C "$ROOT_DIR" worktree remove --force "$WORKTREE_DIR" >/dev/null 2>&1 || rm -rf "$WORKTREE_DIR"
}
trap cleanup EXIT

git -C "$ROOT_DIR" fetch origin "$GHPAGES_BRANCH" >/dev/null 2>&1
if ! git -C "$ROOT_DIR" show-ref --verify --quiet "refs/remotes/origin/$GHPAGES_BRANCH"; then
    echo "원격 브랜치를 찾지 못했습니다: origin/$GHPAGES_BRANCH" >&2
    exit 1
fi

git -C "$ROOT_DIR" worktree add --detach "$WORKTREE_DIR" "origin/$GHPAGES_BRANCH" >/dev/null

mkdir -p "$WORKTREE_DIR/$(dirname "$RELATIVE_FEED_PATH")"
cp "$APPCAST_SOURCE" "$WORKTREE_DIR/$RELATIVE_FEED_PATH"

if [[ "$CHANNEL" == "prod" ]]; then
    mkdir -p "$WORKTREE_DIR/channels/prod"
    cp "$APPCAST_SOURCE" "$WORKTREE_DIR/channels/prod/appcast.xml"
    cp "$APPCAST_SOURCE" "$WORKTREE_DIR/appcast.xml"
fi

: > "$WORKTREE_DIR/.nojekyll"
build_index_html "$WORKTREE_DIR/index.html"

git -C "$WORKTREE_DIR" add .nojekyll index.html
git -C "$WORKTREE_DIR" add "$RELATIVE_FEED_PATH"
if [[ "$CHANNEL" == "prod" ]]; then
    git -C "$WORKTREE_DIR" add appcast.xml channels/prod/appcast.xml
fi

if git -C "$WORKTREE_DIR" diff --cached --quiet; then
    echo "gh-pages 에 반영할 변경이 없습니다."
    exit 0
fi

if [[ -z "$COMMIT_MESSAGE" ]]; then
    if [[ -n "$TAG" ]]; then
        COMMIT_MESSAGE="$CHANNEL: Sparkle appcast를 ${TAG}로 갱신"
    else
        COMMIT_MESSAGE="$CHANNEL: Sparkle appcast 갱신"
    fi
fi

git -C "$WORKTREE_DIR" commit -m "$COMMIT_MESSAGE" >/dev/null
git -C "$WORKTREE_DIR" push origin HEAD:"$GHPAGES_BRANCH"

echo "gh-pages 게시 완료"
echo "  - channel: $CHANNEL"
echo "  - feed url: $FEED_URL"
echo "  - branch: $GHPAGES_BRANCH"
