#!/bin/bash
# ClaudeUsage 설치 스크립트
# 이 파일을 더블클릭하면 터미널에서 자동 실행됩니다.

APP_NAME="ClaudeUsage.app"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="$SCRIPT_DIR/$APP_NAME"
DEST="/Applications/$APP_NAME"

echo ""
echo "=================================="
echo "  ClaudeUsage 설치"
echo "=================================="
echo ""
echo "이 앱은 Apple Developer 인증서로 서명되지 않은 개인 배포 앱입니다."
echo "macOS는 인터넷에서 다운로드한 미서명 앱을 기본적으로 차단합니다."
echo ""
echo "이 스크립트는 다음 두 가지 작업을 수행합니다:"
echo "  1. macOS가 다운로드 시 붙인 '격리(quarantine)' 태그를 제거합니다."
echo "     (실행 명령: xattr -rd com.apple.quarantine ClaudeUsage.app)"
echo "  2. 앱을 /Applications 폴더로 복사합니다."
echo ""
echo "※ 앱의 코드를 변경하거나 시스템 보안 설정을 수정하지 않습니다."
echo ""

# 앱 파일 확인
if [ ! -d "$APP_PATH" ]; then
    echo "❌ $APP_NAME을(를) 찾을 수 없습니다."
    echo "   이 스크립트와 같은 폴더에 $APP_NAME이 있어야 합니다."
    echo ""
    read -p "아무 키나 누르면 종료합니다..."
    exit 1
fi

read -p "계속 진행할까요? (y/n): " proceed
if [ "$proceed" != "y" ] && [ "$proceed" != "Y" ] && [ "$proceed" != "" ]; then
    echo "설치를 취소했습니다."
    exit 0
fi

echo ""

# quarantine 속성 제거
echo "→ 다운로드 격리(quarantine) 태그 제거 중..."
echo "  (sudo 비밀번호를 입력해주세요)"
sudo xattr -rd com.apple.quarantine "$APP_PATH"

# Applications 폴더로 복사
echo "→ /Applications 폴더로 복사 중..."
if [ -d "$DEST" ]; then
    rm -rf "$DEST"
fi
cp -R "$APP_PATH" "$DEST"
sudo xattr -rd com.apple.quarantine "$DEST"

echo ""
echo "✅ 설치 완료!"
echo ""

# 앱 실행
read -p "지금 앱을 실행할까요? (y/n): " answer
if [ "$answer" = "y" ] || [ "$answer" = "Y" ] || [ "$answer" = "" ]; then
    open "$DEST"
    echo "→ ClaudeUsage를 실행합니다."
fi

echo ""

# 설치 파일 정리
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
ZIP_FILE="$PARENT_DIR/ClaudeUsage.zip"

echo "앱이 /Applications 폴더에 복사되었으므로"
echo "다운로드한 설치 파일은 더 이상 필요하지 않습니다."
echo ""
echo "  삭제 대상:"
echo "    - 압축 해제 폴더: $SCRIPT_DIR"
if [ -f "$ZIP_FILE" ]; then
    echo "    - 압축 파일:       $ZIP_FILE"
fi
echo ""
read -p "설치 파일을 삭제할까요? (y/n): " cleanup
if [ "$cleanup" = "y" ] || [ "$cleanup" = "Y" ]; then
    if [ -f "$ZIP_FILE" ]; then
        rm -f "$ZIP_FILE"
        echo "→ 압축 파일을 삭제했습니다."
    fi
    rm -rf "$SCRIPT_DIR"
    echo "→ 압축 해제 폴더를 삭제했습니다."
else
    echo "→ 설치 파일을 유지합니다."
fi

echo ""
