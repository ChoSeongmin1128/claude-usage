#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT_DIR/Scripts/lib/homebrew_cask.py"
MANIFEST=""
OUTPUT=""
WRITE=0
STAGE=""

usage() {
    cat <<'USAGE'
사용법:
  Scripts/render-homebrew-cask.sh \
    --manifest /absolute/path/manifest.json \
    --output /absolute/path/Casks/claude-usage.rb \
    [--write]

기본 동작은 상태만 분류하며 파일을 변경하지 않습니다.
--write는 absent 또는 outdated 상태만 결정적으로 생성·교체합니다.
USAGE
}

die() {
    echo "오류: $*" >&2
    exit 1
}

cleanup() {
    local exit_code=$?
    local cleanup_failed=0
    if [[ -n "$STAGE" && -f "$STAGE" ]]; then
        if ! rm -f "$STAGE" || [[ -e "$STAGE" ]]; then
            echo "오류: Cask staging 파일을 정리하지 못했습니다: $STAGE" >&2
            cleanup_failed=1
        fi
    fi
    trap - EXIT
    if [[ "$exit_code" == "0" && "$cleanup_failed" == "1" ]]; then
        exit 1
    fi
    exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

while [[ $# -gt 0 ]]; do
    case "$1" in
        --manifest)
            [[ $# -ge 2 ]] || die "--manifest 값이 필요합니다."
            MANIFEST="$2"
            shift 2
            ;;
        --output)
            [[ $# -ge 2 ]] || die "--output 값이 필요합니다."
            OUTPUT="$2"
            shift 2
            ;;
        --write)
            WRITE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "알 수 없는 인자: $1"
            ;;
    esac
done

[[ "$MANIFEST" == /*.json && -f "$MANIFEST" && ! -L "$MANIFEST" ]] \
    || die "--manifest는 .json으로 끝나는 절대 일반 파일이어야 합니다."
[[ "$OUTPUT" == /*/Casks/claude-usage.rb ]] \
    || die "--output은 Casks/claude-usage.rb로 끝나는 절대 경로여야 합니다."
OUTPUT_PARENT="$(dirname "$OUTPUT")"
[[ -d "$OUTPUT_PARENT" && ! -L "$OUTPUT_PARENT" ]] \
    || die "Cask 출력 디렉터리가 유효하지 않습니다: $OUTPUT_PARENT"
[[ -f "$TOOL" ]] || die "Homebrew Cask metadata tool을 찾지 못했습니다."

python3 "$TOOL" validate --manifest "$MANIFEST" >/dev/null
STATE="$(python3 "$TOOL" classify --manifest "$MANIFEST" --cask "$OUTPUT")"
case "$STATE" in
    absent|outdated)
        ;;
    matching)
        echo "Homebrew Cask가 manifest와 일치합니다: $OUTPUT"
        exit 0
        ;;
    conflicting-sha)
        die "같은 version의 Cask SHA-256이 달라 불변 운영 자산 위반입니다."
        ;;
    newer)
        die "tap Cask가 manifest보다 새 버전이어서 갱신을 거부합니다."
        ;;
    unexpected)
        die "Cask 구조가 예상 형식과 달라 자동 덮어쓰기를 거부합니다."
        ;;
    *)
        die "알 수 없는 Cask 상태입니다: $STATE"
        ;;
esac

if [[ "$WRITE" != "1" ]]; then
    echo "Homebrew Cask 갱신 필요: state=$STATE output=$OUTPUT"
    exit 0
fi

STAGE="$(mktemp "$OUTPUT_PARENT/.claude-usage.rb.XXXXXX")"
python3 "$TOOL" render --manifest "$MANIFEST" > "$STAGE"
chmod 0644 "$STAGE"
mv "$STAGE" "$OUTPUT"
STAGE=""

FINAL_STATE="$(python3 "$TOOL" classify --manifest "$MANIFEST" --cask "$OUTPUT")"
[[ "$FINAL_STATE" == "matching" ]] \
    || die "생성한 Cask가 manifest와 일치하지 않습니다: $FINAL_STATE"
echo "Homebrew Cask 생성 완료: $OUTPUT"
