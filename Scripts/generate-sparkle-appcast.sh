#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$ROOT_DIR/build/release}"
APPCAST_OUTPUT="${APPCAST_OUTPUT:-$ARTIFACTS_DIR/appcast.xml}"
LOCAL_XC_CONFIG_PATH="${LOCAL_XC_CONFIG_PATH:-$ROOT_DIR/Config/Sparkle.release.local.xcconfig}"

extract_xcconfig_value() {
  local file="$1"
  local key="$2"
  [[ -f "$file" ]] || return 0
  awk -F '=' -v target="$key" '
    $1 ~ "^[[:space:]]*"target"[[:space:]]*$" {
      value=$2
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      print value
      exit
    }
  ' "$file"
}

is_placeholder_value() {
  local value="${1,,}"
  [[ -z "$value" ]] && return 0
  [[ "$value" == *"change_me"* ]] && return 0
  [[ "$value" == *"placeholder"* ]] && return 0
  [[ "$value" == *"replace_with"* ]] && return 0
  [[ "$value" == *"example.com"* ]] && return 0
  [[ "$value" == *'$('* ]] && return 0
  return 1
}

derive_download_base_url() {
  local feed_url="$1"
  if is_placeholder_value "$feed_url"; then
    return 0
  fi
  printf '%s\n' "${feed_url%/appcast.xml}"
}

FEED_URL="${SU_FEED_URL:-$(extract_xcconfig_value "$LOCAL_XC_CONFIG_PATH" "SUFeedURL")}"
DOWNLOAD_BASE_URL="${DOWNLOAD_BASE_URL:-$(derive_download_base_url "$FEED_URL")}"

echo "Sparkle appcast 생성 준비를 확인합니다"

if [[ ! -d "$ARTIFACTS_DIR" ]]; then
  echo "아티팩트 디렉토리를 찾지 못했습니다: $ARTIFACTS_DIR" >&2
  exit 1
fi

if [[ -z "$DOWNLOAD_BASE_URL" ]]; then
  echo "유효한 DOWNLOAD_BASE_URL을 찾지 못했습니다." >&2
  echo "Config/Sparkle.release.local.xcconfig 의 SUFeedURL 또는 환경변수 DOWNLOAD_BASE_URL을 확인해 주세요." >&2
  exit 1
fi

if ! command -v generate_appcast >/dev/null 2>&1; then
  echo "generate_appcast 명령어를 찾지 못했습니다." >&2
  echo "Sparkle의 generate_appcast 도구를 설치하거나 경로를 PATH에 추가해 주세요." >&2
  exit 1
fi

ZIP_COUNT="$(find "$ARTIFACTS_DIR" -maxdepth 1 -name '*.zip' | wc -l | tr -d ' ')"
if [[ "$ZIP_COUNT" == "0" ]]; then
  echo "appcast에 포함할 ZIP 산출물이 없습니다: $ARTIFACTS_DIR" >&2
  exit 1
fi

echo "- artifacts: $ARTIFACTS_DIR"
echo "- output: $APPCAST_OUTPUT"
echo "- base url: $DOWNLOAD_BASE_URL"

generate_appcast \
  --download-url-prefix "$DOWNLOAD_BASE_URL" \
  --output "$APPCAST_OUTPUT" \
  "$ARTIFACTS_DIR"

echo
echo "완료: $APPCAST_OUTPUT"
echo "생성된 appcast.xml을 ZIP 산출물과 같은 채널에 배포해 주세요."
