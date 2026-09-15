#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Scripts/lib/release-driver-common.sh
source "$ROOT_DIR/Scripts/lib/release-driver-common.sh"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$ROOT_DIR/build/release}"
APPCAST_OUTPUT="${APPCAST_OUTPUT:-$ARTIFACTS_DIR/appcast.xml}"
LOCAL_XC_CONFIG_PATH="${LOCAL_XC_CONFIG_PATH:-$ROOT_DIR/Config/Sparkle.release.local.xcconfig}"

FEED_URL_OVERRIDE=""
DOWNLOAD_BASE_URL_OVERRIDE=""
RELEASE_TAG_OVERRIDE=""
NOTES_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes-file)
      [[ $# -ge 2 && -n "$2" && -z "$NOTES_FILE" ]] || { echo "유효한 --notes-file을 한 번 지정해 주세요." >&2; exit 2; }
      NOTES_FILE="$2"
      shift 2
      ;;
    --feed-url)
      FEED_URL_OVERRIDE="$2"
      shift 2
      ;;
    --download-base-url)
      DOWNLOAD_BASE_URL_OVERRIDE="$2"
      shift 2
      ;;
    --tag)
      RELEASE_TAG_OVERRIDE="$2"
      shift 2
      ;;
    -h|--help)
      cat <<USAGE
사용법:
  $0 [--feed-url URL] [--download-base-url URL] --tag vX.Y.Z [--notes-file docs/release-notes/X.Y.Z.md]

우선순위:
  1. 명시적 옵션
  2. 환경변수 SU_FEED_URL / DOWNLOAD_BASE_URL
  3. Config/Sparkle.release.local.xcconfig 값

비고:
  - feed URL 과 download base URL 은 서로 다른 호스트를 가리켜도 됩니다.
  - download base URL 을 명시하지 않으면, 필요 시 feed URL 에서만 보수적으로 추론합니다.
  - download base URL 에 __TAG__ 템플릿을 쓰려면 --tag 또는 RELEASE_TAG 를 함께 넘기세요.
USAGE
      exit 0
      ;;
    *)
      echo "알 수 없는 옵션: $1" >&2
      exit 2
      ;;
  esac
done

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
  [[ "$value" == *"example.com"* ]] && return 0
  [[ "$value" == *"\$("* ]] && return 0
  return 1
}

find_sparkle_binary() {
  local name="$1"
  if [[ -n "${SPARKLE_TOOLS_DIR:-}" && -x "$SPARKLE_TOOLS_DIR/$name" ]]; then
    printf '%s\n' "$SPARKLE_TOOLS_DIR/$name"
    return 0
  fi
  local candidates=(
    "$HOME/Library/Developer/Xcode/DerivedData/ClaudeUsage"*/SourcePackages/artifacts/sparkle/Sparkle/bin/"$name"
  )
  for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
    return 0
  fi
  return 1
}

derive_download_base_url_from_feed_url() {
  local feed_url="$1"
  if is_placeholder_value "$feed_url"; then
    return 0
  fi
  # GitHub latest URL 에서는 현재 태그를 알 수 없어 잘못된 enclosure 를 만들 수 있습니다.
  if [[ "$feed_url" == *"/releases/latest/download/appcast.xml" ]]; then
    return 0
  fi
  printf '%s\n' "${feed_url%/appcast.xml}"
}

expand_tag_placeholder() {
  local value="$1"
  local tag="$2"
  if [[ "$value" == *"__TAG__"* ]]; then
    if [[ -z "$tag" ]]; then
      echo "__TAG__ 템플릿을 쓰려면 --tag 또는 RELEASE_TAG 가 필요합니다." >&2
      exit 1
    fi
    printf '%s\n' "${value//__TAG__/$tag}"
    return 0
  fi
  printf '%s\n' "$value"
}

FEED_URL="${FEED_URL_OVERRIDE:-${SU_FEED_URL:-$(extract_xcconfig_value "$LOCAL_XC_CONFIG_PATH" "SUFeedURL")}}"
RELEASE_TAG="${RELEASE_TAG_OVERRIDE:-${RELEASE_TAG:-}}"
DOWNLOAD_BASE_URL="${DOWNLOAD_BASE_URL_OVERRIDE:-${DOWNLOAD_BASE_URL:-$(extract_xcconfig_value "$LOCAL_XC_CONFIG_PATH" "SPARKLE_DOWNLOAD_BASE_URL")}}"
DOWNLOAD_BASE_URL="$(expand_tag_placeholder "$DOWNLOAD_BASE_URL" "$RELEASE_TAG")"

if [[ -z "$DOWNLOAD_BASE_URL" ]]; then
  DOWNLOAD_BASE_URL="$(derive_download_base_url_from_feed_url "$FEED_URL")"
fi

DOWNLOAD_URL_PREFIX="${DOWNLOAD_BASE_URL%/}/"

echo "Sparkle appcast 생성 준비를 확인합니다"

if [[ ! -d "$ARTIFACTS_DIR" ]]; then
  echo "아티팩트 디렉토리를 찾지 못했습니다: $ARTIFACTS_DIR" >&2
  exit 1
fi

if [[ -z "$DOWNLOAD_BASE_URL" ]]; then
  echo "유효한 DOWNLOAD_BASE_URL을 찾지 못했습니다." >&2
  echo "Pages 와 Releases 를 분리 운영한다면 --download-base-url 또는 DOWNLOAD_BASE_URL 을 명시해 주세요." >&2
  exit 1
fi

GEN_APPCAST="$(find_sparkle_binary generate_appcast || true)"
if [[ -z "$GEN_APPCAST" ]]; then
  echo "generate_appcast 명령어를 찾지 못했습니다." >&2
  echo "Xcode 에서 한 번 빌드한 뒤 다시 시도하거나 Sparkle SPM 설정을 확인해 주세요." >&2
  exit 1
fi

SIGN_UPDATE="$(find_sparkle_binary sign_update || true)"
if [[ -z "$SIGN_UPDATE" ]]; then
  echo "sign_update 명령어를 찾지 못했습니다." >&2
  echo "Sparkle 서명 정보를 appcast에 주입할 수 없으니 설정을 확인해 주세요." >&2
  exit 1
fi

DMG_COUNT="$(find "$ARTIFACTS_DIR" -maxdepth 1 -name 'ClaudeUsage.dmg' | wc -l | tr -d ' ')"
if [[ "$DMG_COUNT" == "0" ]]; then
  echo "appcast에 포함할 DMG 산출물이 없습니다: $ARTIFACTS_DIR" >&2
  exit 1
fi

NOTES_VERSION="${RELEASE_TAG#v}"
NOTES_VERSION="${NOTES_VERSION%%-*}"
if [[ -z "$NOTES_FILE" ]]; then
  NOTES_FILE="$(python3 "$ROOT_DIR/Scripts/lib/release_metadata.py" notes-path \
    --root "$ROOT_DIR" --version "$NOTES_VERSION")"
fi
python3 "$ROOT_DIR/Scripts/lib/release_metadata.py" validate-notes \
  --notes-file "$NOTES_FILE" --version "$NOTES_VERSION"

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/claudeusage-appcast.XXXXXX")"
cleanup() {
  local exit_code=$?
  local cleanup_failed=0

  if [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" ]]; then
    if ! rm -rf "$STAGING_DIR" || [[ -e "$STAGING_DIR" ]]; then
      echo "appcast 임시 디렉터리를 정리하지 못했습니다: $STAGING_DIR" >&2
      cleanup_failed=1
    fi
  fi
  exit "$(release_cleanup_exit_code "$exit_code" "$cleanup_failed" 0)"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

find "$ARTIFACTS_DIR" -maxdepth 1 -name 'ClaudeUsage.dmg' -print0 | while IFS= read -r -d '' dmg_path; do
  cp "$dmg_path" "$STAGING_DIR/"
done

echo "- generate_appcast: $GEN_APPCAST"
echo "- sign_update: $SIGN_UPDATE"
echo "- artifacts: $ARTIFACTS_DIR"
echo "- staged archive dir: $STAGING_DIR"
echo "- output: $APPCAST_OUTPUT"
if [[ -n "$FEED_URL" ]]; then
  echo "- feed url: $FEED_URL"
fi
echo "- download base url: $DOWNLOAD_URL_PREFIX"

# generate_appcast는 기존 output을 읽어 과거 item을 유지할 수 있습니다.
# ClaudeUsage.dmg 파일명이 릴리스마다 같기 때문에 과거 item을 유지하면 현재 DMG의
# length/signature가 과거 item에도 주입됩니다. 채널 appcast는 최신 릴리스 1개만
# 생성해 잘못된 과거 enclosure 오염을 막습니다.
rm -f "$APPCAST_OUTPUT"

"$GEN_APPCAST" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  -o "$APPCAST_OUTPUT" \
  "$STAGING_DIR"

python3 "$ROOT_DIR/Scripts/lib/release_metadata.py" embed-notes \
  --appcast "$APPCAST_OUTPUT" --notes-file "$NOTES_FILE" --version "${NOTES_VERSION}" --tag "$RELEASE_TAG"
python3 "$ROOT_DIR/Scripts/lib/release_metadata.py" bind-zip \
  --appcast "$APPCAST_OUTPUT" --zip-file "$ARTIFACTS_DIR/ClaudeUsage.zip"
# This is the final mutation. No XML serialization may follow feed signing.
"$SIGN_UPDATE" "$APPCAST_OUTPUT"
rm -rf "$STAGING_DIR"
[[ ! -e "$STAGING_DIR" ]] || {
  echo "appcast 임시 디렉터리를 정리하지 못했습니다: $STAGING_DIR" >&2
  exit 1
}
STAGING_DIR=""

echo
echo "완료: $APPCAST_OUTPUT"
if [[ -n "$FEED_URL" ]]; then
  echo "배포 시 appcast.xml 은 다음 feed URL 경로에 반영하세요: $FEED_URL"
fi
