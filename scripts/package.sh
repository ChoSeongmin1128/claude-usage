#!/bin/bash
# ClaudeUsage 배포용 zip 패키징 스크립트

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build/Build/Products/Release"
STAGING_DIR="$PROJECT_DIR/build/staging"
APP_NAME="ClaudeUsage.app"
OUTPUT="$PROJECT_DIR/build/ClaudeUsage.zip"

echo "=== ClaudeUsage 패키징 ==="

# 1. Release 빌드
echo "→ Release 빌드 중..."
xcodebuild -project "$PROJECT_DIR/ClaudeUsage.xcodeproj" \
    -scheme ClaudeUsage \
    -configuration Release \
    -derivedDataPath "$PROJECT_DIR/build" \
    build -quiet

# 2. 스테이징 폴더 준비
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

# 3. 앱 복사 + quarantine 제거
cp -R "$BUILD_DIR/$APP_NAME" "$STAGING_DIR/"
xattr -cr "$STAGING_DIR/$APP_NAME"

# 4. README 복사
cp "$PROJECT_DIR/scripts/README.txt" "$STAGING_DIR/"

# 5. zip 생성
rm -f "$OUTPUT"
cd "$STAGING_DIR"
zip -r "$OUTPUT" . -x ".*"

# 정리
rm -rf "$STAGING_DIR"

echo ""
echo "✅ 패키징 완료: $OUTPUT"
echo "   $(du -h "$OUTPUT" | cut -f1) 크기"
