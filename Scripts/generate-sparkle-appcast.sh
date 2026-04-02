#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$ROOT_DIR/build/release}"
APPCAST_OUTPUT="${APPCAST_OUTPUT:-$ARTIFACTS_DIR/appcast.xml}"
DOWNLOAD_BASE_URL="${DOWNLOAD_BASE_URL:-}"

echo "Sparkle appcast 생성 준비를 확인합니다"

if [[ ! -d "$ARTIFACTS_DIR" ]]; then
  echo "아티팩트 디렉토리를 찾지 못했습니다: $ARTIFACTS_DIR" >&2
  exit 1
fi

if [[ -z "$DOWNLOAD_BASE_URL" ]]; then
  echo "DOWNLOAD_BASE_URL 환경변수가 비어 있습니다." >&2
  echo "예: export DOWNLOAD_BASE_URL=https://example.com/claude-usage" >&2
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
