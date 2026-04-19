#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$ROOT_DIR/build/release}"
APPCAST_OUTPUT="${APPCAST_OUTPUT:-$ARTIFACTS_DIR/appcast.xml}"
LOCAL_XC_CONFIG_PATH="${LOCAL_XC_CONFIG_PATH:-$ROOT_DIR/Config/Sparkle.release.local.xcconfig}"

FEED_URL_OVERRIDE=""
DOWNLOAD_BASE_URL_OVERRIDE=""
RELEASE_TAG_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
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
  $0 [--feed-url URL] [--download-base-url URL] [--tag vX.Y.Z]

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
  awk -F '=' -v target="$key" '
    $1 ~ "^[[:space:]]*"target"[[:space:]]*$" {
      value=$2
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
  [[ "$value" == *'$('* ]] && return 0
  return 1
}

find_sparkle_binary() {
  local name="$1"
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

attach_signatures_to_appcast() {
  local appcast_path="$1"
  local archives_dir="$2"
  local sign_update_bin="$3"

  python3 - "$appcast_path" "$archives_dir" "$sign_update_bin" <<'PY'
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

appcast_path, archives_dir, sign_update_bin = sys.argv[1:4]
sparkle_namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
signature_key = f"{{{sparkle_namespace}}}edSignature"

ET.register_namespace("sparkle", sparkle_namespace)
tree = ET.parse(appcast_path)
root = tree.getroot()
updated = False

for enclosure in root.findall(".//enclosure"):
    url = enclosure.get("url", "")
    archive_name = os.path.basename(url)
    archive_path = os.path.join(archives_dir, archive_name)
    if not archive_name or not os.path.isfile(archive_path):
        continue

    command_output = subprocess.check_output([sign_update_bin, archive_path], text=True).strip()
    signature_match = re.search(r'sparkle:edSignature="([^"]+)"', command_output)
    length_match = re.search(r'length="([^"]+)"', command_output)
    if not signature_match or not length_match:
        raise SystemExit(f"sign_update 출력에서 서명 정보를 찾지 못했습니다: {archive_name}")

    signature = signature_match.group(1)
    length = length_match.group(1)

    if enclosure.get(signature_key) != signature:
        enclosure.set(signature_key, signature)
        updated = True
    if enclosure.get("length") != length:
        enclosure.set("length", length)
        updated = True

if updated:
    tree.write(appcast_path, encoding="utf-8", xml_declaration=True)
PY
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

ZIP_COUNT="$(find "$ARTIFACTS_DIR" -maxdepth 1 -name '*.zip' | wc -l | tr -d ' ')"
if [[ "$ZIP_COUNT" == "0" ]]; then
  echo "appcast에 포함할 ZIP 산출물이 없습니다: $ARTIFACTS_DIR" >&2
  exit 1
fi

STAGING_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

find "$ARTIFACTS_DIR" -maxdepth 1 -name '*.zip' -print0 | while IFS= read -r -d '' zip_path; do
  cp "$zip_path" "$STAGING_DIR/"
done

echo "- generate_appcast: $GEN_APPCAST"
echo "- sign_update: $SIGN_UPDATE"
echo "- artifacts: $ARTIFACTS_DIR"
echo "- staged zip dir: $STAGING_DIR"
echo "- output: $APPCAST_OUTPUT"
if [[ -n "$FEED_URL" ]]; then
  echo "- feed url: $FEED_URL"
fi
echo "- download base url: $DOWNLOAD_URL_PREFIX"

"$GEN_APPCAST" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  -o "$APPCAST_OUTPUT" \
  "$STAGING_DIR"

attach_signatures_to_appcast "$APPCAST_OUTPUT" "$STAGING_DIR" "$SIGN_UPDATE"

echo
echo "완료: $APPCAST_OUTPUT"
if [[ -n "$FEED_URL" ]]; then
  echo "배포 시 appcast.xml 은 다음 feed URL 경로에 반영하세요: $FEED_URL"
fi
