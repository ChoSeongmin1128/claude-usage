#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_INFO_PLIST="$ROOT_DIR/ClaudeUsage/Info.plist"
EXAMPLE_CONFIG="$ROOT_DIR/Config/Sparkle.release.example.xcconfig"
LOCAL_CONFIG="$ROOT_DIR/Config/Sparkle.release.local.xcconfig"

FEED_URL="${SU_FEED_URL:-}"
PUBLIC_KEY="${SU_PUBLIC_ED_KEY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

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

if [[ -z "$FEED_URL" ]]; then
  FEED_URL="$(extract_xcconfig_value "$LOCAL_CONFIG" "SUFeedURL")"
fi

if [[ -z "$PUBLIC_KEY" ]]; then
  PUBLIC_KEY="$(extract_xcconfig_value "$LOCAL_CONFIG" "SUPublicEDKey")"
fi

if [[ -z "$NOTARY_PROFILE" ]]; then
  NOTARY_PROFILE="$(extract_xcconfig_value "$LOCAL_CONFIG" "NOTARY_PROFILE")"
fi

echo "Sparkle release 준비 상태를 점검합니다"

if [[ ! -f "$APP_INFO_PLIST" ]]; then
  echo "Info.plist를 찾지 못했습니다: $APP_INFO_PLIST" >&2
  exit 1
fi

if [[ ! -f "$EXAMPLE_CONFIG" ]]; then
  echo "예시 xcconfig를 찾지 못했습니다: $EXAMPLE_CONFIG" >&2
  exit 1
fi

echo "- Info.plist: $APP_INFO_PLIST"
echo "- 예시 xcconfig: $EXAMPLE_CONFIG"
echo "- 로컬 xcconfig: $LOCAL_CONFIG"

if is_placeholder_value "$FEED_URL"; then
  echo "- SU_FEED_URL: 비어 있음"
else
  echo "- SU_FEED_URL: 설정됨"
fi

if is_placeholder_value "$PUBLIC_KEY"; then
  echo "- SU_PUBLIC_ED_KEY: 비어 있음"
else
  echo "- SU_PUBLIC_ED_KEY: 설정됨"
fi

if is_placeholder_value "$NOTARY_PROFILE"; then
  echo "- NOTARY_PROFILE: 비어 있음"
else
  echo "- NOTARY_PROFILE: 설정됨"
fi

cat <<'EOF'

다음 단계
1. Config/Sparkle.release.example.xcconfig 를 복사해 실제 release 전용 xcconfig를 만듭니다
2. SUFeedURL, SUPublicEDKey, NOTARY_PROFILE 값을 채웁니다
3. Release configuration에 해당 xcconfig를 연결합니다
4. Developer ID 서명과 notarization을 거친 산출물을 준비합니다
5. appcast.xml 과 Sparkle 서명을 함께 배포합니다

이 스크립트는 점검용 골격입니다.
실제 서명, notarization, appcast 생성은 별도 release 스크립트나 CI에서 수행해야 합니다.
EOF
