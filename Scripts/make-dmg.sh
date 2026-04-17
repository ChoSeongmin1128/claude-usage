#!/usr/bin/env bash
#
# ClaudeUsage 설치용 DMG 빌더.
#
# dmgbuild (Python) 를 사용합니다. AppleScript + Finder 경로의 캐시/타이밍
# 이슈 없이 .DS_Store 를 바이너리로 직접 기록해 창 크기/배경/아이콘 좌표를
# 확정적으로 지정합니다.
#
# 입력 (환경변수):
#   APP_PATH        : 감쌀 .app 의 절대 경로 (필수)
#   DMG_PATH        : 생성할 DMG 의 절대 경로 (필수)
#   VOLUME_NAME     : 마운트 볼륨 이름 (기본 "Install ClaudeUsage")
#   BACKGROUND_PNG  : 배경 이미지 (기본 Scripts/dmg-assets/background.png)
#   CERT_HASH       : Developer ID 인증서 SHA-1 해시 (선택)
#   APP_ICON_X/Y    : 앱 아이콘 좌표 (기본 150, 190)
#   APPS_ICON_X/Y   : Applications alias 좌표 (기본 390, 190)
#   WINDOW_W/H      : 창 크기 (기본 540, 380)
#
# 전제:
#   pipx 로 dmgbuild 설치  (pipx install dmgbuild)
#
# 호출 예:
#   APP_PATH=/path/to/ClaudeUsage.app \
#   DMG_PATH=/path/to/ClaudeUsage.dmg \
#   CERT_HASH=9A12730390B85461D1A98C907C61A7AA265EE214 \
#   Scripts/make-dmg.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS_FILE="$ROOT_DIR/Scripts/dmg-assets/dmgbuild-settings.py"

APP_PATH="${APP_PATH:?APP_PATH is required}"
DMG_PATH="${DMG_PATH:?DMG_PATH is required}"
VOLUME_NAME="${VOLUME_NAME:-Install ClaudeUsage}"
BACKGROUND_PNG="${BACKGROUND_PNG:-$ROOT_DIR/Scripts/dmg-assets/background.png}"
# 볼륨 아이콘: 미지정 시 앱 번들의 AppIcon.icns 자동 사용
VOLUME_ICON="${VOLUME_ICON:-$APP_PATH/Contents/Resources/AppIcon.icns}"
APP_ICON_X="${APP_ICON_X:-150}"
APP_ICON_Y="${APP_ICON_Y:-190}"
APPS_ICON_X="${APPS_ICON_X:-390}"
APPS_ICON_Y="${APPS_ICON_Y:-190}"
WINDOW_W="${WINDOW_W:-540}"
WINDOW_H="${WINDOW_H:-380}"
CERT_HASH="${CERT_HASH:-}"

if [[ ! -d "$APP_PATH" ]]; then
    echo "앱 경로를 찾지 못했습니다: $APP_PATH" >&2
    exit 1
fi

if [[ ! -f "$SETTINGS_FILE" ]]; then
    echo "dmgbuild settings 파일을 찾지 못했습니다: $SETTINGS_FILE" >&2
    exit 1
fi

# dmgbuild 위치 탐색 (PATH, pipx 기본 경로, ~/.local/bin)
DMGBUILD_BIN=""
for candidate in dmgbuild "$HOME/.local/bin/dmgbuild"; do
    if command -v "$candidate" >/dev/null 2>&1; then
        DMGBUILD_BIN="$(command -v "$candidate")"
        break
    fi
done

if [[ -z "$DMGBUILD_BIN" ]]; then
    echo "dmgbuild 가 설치돼있지 않습니다." >&2
    echo "  pipx install dmgbuild" >&2
    exit 1
fi

# 잔존 마운트 정리 (이전 실패 흔적이 남아있으면)
if [[ -d "/Volumes/$VOLUME_NAME" ]]; then
    hdiutil detach "/Volumes/$VOLUME_NAME" -force >/dev/null 2>&1 || true
fi

rm -f "$DMG_PATH"

echo "1. dmgbuild 로 DMG 생성"
echo "   설정: $SETTINGS_FILE"
if [[ -f "$BACKGROUND_PNG" ]]; then
    echo "   배경: $(basename "$BACKGROUND_PNG")"
else
    echo "   배경 없음 (builtin-arrow 사용)"
fi
if [[ -f "$VOLUME_ICON" ]]; then
    echo "   볼륨 아이콘: $VOLUME_ICON"
else
    echo "   볼륨 아이콘 없음 (기본 디스크 아이콘 사용)"
    VOLUME_ICON=""
fi

DMG_APP_PATH="$APP_PATH" \
DMG_BACKGROUND_PNG="$BACKGROUND_PNG" \
DMG_VOLUME_ICON="$VOLUME_ICON" \
DMG_WINDOW_W="$WINDOW_W" \
DMG_WINDOW_H="$WINDOW_H" \
DMG_APP_ICON_X="$APP_ICON_X" \
DMG_APP_ICON_Y="$APP_ICON_Y" \
DMG_APPS_ICON_X="$APPS_ICON_X" \
DMG_APPS_ICON_Y="$APPS_ICON_Y" \
"$DMGBUILD_BIN" \
    -s "$SETTINGS_FILE" \
    "$VOLUME_NAME" \
    "$DMG_PATH"

if [[ ! -f "$DMG_PATH" ]]; then
    echo "DMG 생성 실패" >&2
    exit 1
fi

if [[ -n "$CERT_HASH" ]]; then
    echo "2. DMG 서명 ($CERT_HASH)"
    codesign --force --timestamp --sign "$CERT_HASH" "$DMG_PATH"
    codesign --verify --verbose=2 "$DMG_PATH" 2>&1 | tail -2
fi

SIZE_BYTES=$(stat -f%z "$DMG_PATH")
SIZE_MB=$(awk -v b="$SIZE_BYTES" 'BEGIN { printf "%.2f", b / 1024 / 1024 }')

echo
echo "완료: $DMG_PATH (${SIZE_MB}MB)"
