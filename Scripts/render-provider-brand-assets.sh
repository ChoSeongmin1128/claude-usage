#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="${SOURCE_DIR:-$ROOT_DIR/DesignAssets/ProviderBrandSources}"
ASSET_DIR="${ASSET_DIR:-$ROOT_DIR/ClaudeUsage/Assets.xcassets}"
HELPER_PATH="$ROOT_DIR/Scripts/render-provider-brand-assets.swift"
MODE="write"
OUTPUT_DIR=""
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/provider-icons.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

usage() {
  cat <<'EOF'
Usage:
  Scripts/render-provider-brand-assets.sh [--output-dir DIR]
  Scripts/render-provider-brand-assets.sh --check

Options:
  --output-dir DIR  현재 asset catalog의 provider 집합을 별도 디렉터리에 생성합니다.
  --check           임시 디렉터리에 재생성한 결과가 저장소 asset과 byte-for-byte 같은지 검증합니다.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      [[ $# -ge 2 ]] || {
        echo "--output-dir 값이 필요합니다." >&2
        exit 2
      }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --check)
      MODE="check"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "알 수 없는 옵션입니다: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$MODE" == "check" && -n "$OUTPUT_DIR" ]]; then
  echo "--check와 --output-dir은 함께 사용할 수 없습니다." >&2
  exit 2
fi

[[ -f "$HELPER_PATH" ]] || {
  echo "Swift renderer를 찾지 못했습니다: $HELPER_PATH" >&2
  exit 1
}

command -v xcrun >/dev/null 2>&1 || {
  echo "Xcode command line tool을 찾지 못했습니다: xcrun" >&2
  exit 1
}

[[ -x /usr/bin/qlmanage ]] || {
  echo "macOS Quick Look renderer를 찾지 못했습니다: /usr/bin/qlmanage" >&2
  exit 1
}

xcrun --find swift >/dev/null 2>&1 || {
  echo "Swift toolchain을 찾지 못했습니다. Xcode command line tool 설치 상태를 확인하세요." >&2
  exit 1
}

render_into() {
  local destination="$1"
  xcrun swift "$HELPER_PATH" \
    --source-dir "$SOURCE_DIR" \
    --catalog-dir "$ASSET_DIR" \
    --output-dir "$destination"
}

if [[ "$MODE" == "check" ]]; then
  GENERATED_DIR="$TMP_DIR/Assets.xcassets"
  render_into "$GENERATED_DIR"

  status=0
  while IFS= read -r imageset_path; do
    imageset_name="$(basename "$imageset_path")"
    generated_imageset="$GENERATED_DIR/$imageset_name"
    if ! diff -rq "$imageset_path" "$generated_imageset"; then
      status=1
    fi
  done < <(find "$ASSET_DIR" -maxdepth 1 -type d -name 'Provider*Icon.imageset' -print | sort)

  if [[ "$status" -ne 0 ]]; then
    echo "Provider 브랜드 asset이 재생성 결과와 다릅니다. 스크립트를 실행해 갱신하세요." >&2
    exit 1
  fi

  echo "Provider 브랜드 asset 재현성 검증 완료"
  exit 0
fi

render_into "${OUTPUT_DIR:-$ASSET_DIR}"
echo "Provider 브랜드 아이콘 렌더링 완료"
