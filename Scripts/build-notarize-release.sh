#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build/release}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$BUILD_DIR/ClaudeUsage.xcarchive}"
APP_PATH="$ARCHIVE_PATH/Products/Applications/ClaudeUsage.app"
ZIP_PATH="${ZIP_PATH:-$BUILD_DIR/ClaudeUsage.zip}"
SCHEME="${SCHEME:-ClaudeUsage}"
CONFIGURATION="${CONFIGURATION:-Release}"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/ClaudeUsage.xcodeproj}"
XC_CONFIG_PATH="${XC_CONFIG_PATH:-$ROOT_DIR/Config/Release.xcconfig}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

echo "ClaudeUsage release 산출물 빌드와 notarization을 시작합니다"

if [[ ! -f "$PROJECT_PATH/project.pbxproj" ]]; then
  echo "Xcode 프로젝트를 찾지 못했습니다: $PROJECT_PATH" >&2
  exit 1
fi

if [[ ! -f "$XC_CONFIG_PATH" ]]; then
  echo "release xcconfig를 찾지 못했습니다: $XC_CONFIG_PATH" >&2
  echo "Config/Release.xcconfig 와 Config/Sparkle.release.local.xcconfig 구성을 확인한 뒤 다시 실행해 주세요." >&2
  exit 1
fi

if [[ -z "$NOTARY_PROFILE" ]]; then
  echo "NOTARY_PROFILE 환경변수가 비어 있습니다." >&2
  echo "예: export NOTARY_PROFILE=ClaudeUsageNotary" >&2
  exit 1
fi

command -v xcodebuild >/dev/null 2>&1 || {
  echo "xcodebuild를 찾지 못했습니다." >&2
  exit 1
}

command -v xcrun >/dev/null 2>&1 || {
  echo "xcrun을 찾지 못했습니다." >&2
  exit 1
}

mkdir -p "$BUILD_DIR"
rm -rf "$ARCHIVE_PATH" "$ZIP_PATH"

echo
echo "1. Xcode archive 생성"
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -xcconfig "$XC_CONFIG_PATH" \
  -archivePath "$ARCHIVE_PATH" \
  archive

if [[ ! -d "$APP_PATH" ]]; then
  echo "archive 안에서 앱을 찾지 못했습니다: $APP_PATH" >&2
  exit 1
fi

echo
echo "2. notarization용 ZIP 생성"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

if [[ ! -f "$ZIP_PATH" ]]; then
  echo "ZIP 산출물 생성에 실패했습니다: $ZIP_PATH" >&2
  exit 1
fi

echo
echo "3. notarization 제출"
xcrun notarytool submit "$ZIP_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo
echo "4. 앱 staple 적용"
xcrun stapler staple "$APP_PATH"

echo
cat <<EOF
완료
- archive: $ARCHIVE_PATH
- app: $APP_PATH
- zip: $ZIP_PATH

다음 단계
1. notarized ZIP을 GitHub Releases 또는 정적 호스팅에 업로드합니다
2. Sparkle appcast.xml을 생성하고 동일한 채널에 배포합니다
3. 설정 화면에서 appcast와 공개키가 모두 준비됨으로 보이는지 확인합니다
4. 실제 배포 전 다른 Mac에서 Gatekeeper 설치 테스트를 합니다
EOF
