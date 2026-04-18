#!/usr/bin/env bash
#
# ClaudeUsage Sparkle 배포 자격 부트스트랩 (1회 실행 스크립트).
#
# 수행:
#   1. Sparkle SPM artifact 에서 generate_keys 바이너리 위치 확인
#      (없으면 xcodebuild -resolvePackageDependencies 로 다운로드)
#   2. ED25519 키쌍 생성 (개인키는 macOS 키체인, 공개키는 stdout)
#   3. Config/Sparkle.release.local.xcconfig 템플릿 작성 또는 병합
#      - SUPublicEDKey 를 방금 생성한 값으로 채움
#      - SUFeedURL, NOTARY_PROFILE 은 기존 값 유지하거나 placeholder 로
#
# 멱등성:
#   기존에 키가 이미 생성돼 있으면 (Keychain에 "Private key for signing
#   Sparkle updates" 항목 존재) 재생성을 거부하고 기존 공개키만 출력.
#   로컬 xcconfig 가 이미 있으면 덮어쓰지 않고 SUPublicEDKey 줄만 교체
#   제안. --force 플래그로 재생성 강제 가능.
#

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_XCCONFIG="$ROOT_DIR/Config/Sparkle.release.local.xcconfig"
EXAMPLE_XCCONFIG="$ROOT_DIR/Config/Sparkle.release.example.xcconfig"

FORCE=0
DEFAULT_FEED_URL=""
DEFAULT_NOTARY_PROFILE="ClaudeUsage"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)
            FORCE=1
            shift
            ;;
        --feed-url)
            DEFAULT_FEED_URL="$2"
            shift 2
            ;;
        --notary-profile)
            DEFAULT_NOTARY_PROFILE="$2"
            shift 2
            ;;
        -h|--help)
            cat <<USAGE
사용법:
    $0 [--force] [--feed-url URL] [--notary-profile NAME]

옵션:
    --force            기존 키/xcconfig 를 경고 없이 덮어쓰기
    --feed-url URL     SUFeedURL 기본값 (기본: GitHub Pages appcast URL)
    --notary-profile N NOTARY_PROFILE 기본값 (기본: $DEFAULT_NOTARY_PROFILE)
USAGE
            exit 0
            ;;
        *)
            echo "알 수 없는 옵션: $1" >&2
            exit 2
            ;;
    esac
done

# 기본 피드 URL: GitHub Pages appcast URL 을 추정
if [[ -z "$DEFAULT_FEED_URL" ]]; then
    REMOTE_URL="$(git -C "$ROOT_DIR" config --get remote.origin.url 2>/dev/null || echo "")"
    if [[ "$REMOTE_URL" =~ github\.com[:/](.+)/(.+?)(\.git)?$ ]]; then
        OWNER="${BASH_REMATCH[1]}"
        REPO="${BASH_REMATCH[2]}"
        OWNER_LOWER="${OWNER,,}"
        DEFAULT_FEED_URL="https://$OWNER_LOWER.github.io/$REPO/appcast.xml"
    else
        DEFAULT_FEED_URL="https://REPLACE_ME/appcast.xml"
    fi
fi

echo "ClaudeUsage Sparkle 자격 부트스트랩"
echo

# 1) generate_keys 위치 확인
echo "1. generate_keys 바이너리 탐색"

find_sparkle_binary() {
    local name="$1"
    # DerivedData 내 Sparkle SPM artifact
    local candidates=(
        "$HOME/Library/Developer/Xcode/DerivedData/ClaudeUsage"*/SourcePackages/artifacts/sparkle/Sparkle/bin/"$name"
    )
    for c in "${candidates[@]}"; do
        if [[ -x "$c" ]]; then
            echo "$c"
            return 0
        fi
    done
    # PATH 에 있으면 그걸 씀 (Sparkle을 brew 등으로 설치한 경우)
    if command -v "$name" >/dev/null 2>&1; then
        command -v "$name"
        return 0
    fi
    return 1
}

GEN_KEYS="$(find_sparkle_binary generate_keys || true)"
if [[ -z "$GEN_KEYS" ]]; then
    echo "   DerivedData 에 generate_keys 가 없어 SPM 의존성을 resolve 합니다"
    xcodebuild -project "$ROOT_DIR/ClaudeUsage.xcodeproj" \
        -resolvePackageDependencies >/dev/null
    GEN_KEYS="$(find_sparkle_binary generate_keys || true)"
fi

if [[ -z "$GEN_KEYS" ]]; then
    echo "generate_keys 를 찾지 못했습니다." >&2
    echo "Xcode 에서 한 번 빌드한 뒤 다시 시도하거나 Sparkle SPM 설정을 확인해 주세요." >&2
    exit 1
fi
echo "   $GEN_KEYS"
echo

# 2) 키 생성 또는 기존 공개키 추출
echo "2. ED25519 키 생성"

extract_public_key() {
    local output="$1"
    echo "$output" | grep -E '^[A-Za-z0-9+/=]{40,}$' | tail -n1 | tr -d '[:space:]'
}

PUBLIC_KEY=""
EXISTING_OUTPUT="$("$GEN_KEYS" -p 2>&1 || true)"
PUBLIC_KEY="$(extract_public_key "$EXISTING_OUTPUT")"

HAS_EXISTING_KEY=0
if [[ -n "$PUBLIC_KEY" ]]; then
    HAS_EXISTING_KEY=1
elif [[ -n "$EXISTING_OUTPUT" && "$EXISTING_OUTPUT" != *"No existing signing key found"* ]]; then
    echo "   기존 공개키 확인 실패:" >&2
    echo "$EXISTING_OUTPUT" >&2
fi

if [[ "$HAS_EXISTING_KEY" == "0" || "$FORCE" == "1" ]]; then
    if [[ "$FORCE" == "1" ]]; then
        echo "   --force 플래그: 새 키 생성"
    else
        echo "   기존 키 없음: 새 키 생성"
    fi
    # 키 생성 (공개키를 stdout 마지막 줄로 출력)
    GEN_OUTPUT="$("$GEN_KEYS" 2>&1)"
    PUBLIC_KEY="$(extract_public_key "$GEN_OUTPUT")"
else
    echo "   기존 키 사용 (키체인에 보관됨)"
fi

if [[ -z "$PUBLIC_KEY" ]]; then
    echo "공개키 추출 실패." >&2
    echo "   generate_keys 출력을 직접 확인해 주세요: $GEN_KEYS" >&2
    exit 1
fi

echo "   공개키: $PUBLIC_KEY"
echo

# 3) 로컬 xcconfig 작성/병합
echo "3. $LOCAL_XCCONFIG 작성"

write_xcconfig() {
    cat > "$LOCAL_XCCONFIG" <<EOF
// Sparkle release local overrides (gitignored).
// setup-sparkle-keys.sh 가 자동 생성했습니다. 수동 편집해도 됩니다.

SPARKLE_URL_SLASH = /
SUFeedURL = ${DEFAULT_FEED_URL/\/\//\$(SPARKLE_URL_SLASH)\$(SPARKLE_URL_SLASH)}
SUPublicEDKey = $PUBLIC_KEY
NOTARY_PROFILE = $DEFAULT_NOTARY_PROFILE
EOF
}

if [[ -f "$LOCAL_XCCONFIG" && "$FORCE" != "1" ]]; then
    # 기존 파일 보존: SUPublicEDKey 줄만 대체
    if grep -q '^[[:space:]]*SUPublicEDKey' "$LOCAL_XCCONFIG"; then
        # macOS sed 호환 (in-place 편집 시 ''): 공개키 값만 치환
        tmp_file="$(mktemp)"
        awk -v key="$PUBLIC_KEY" '
            /^[[:space:]]*SUPublicEDKey/ {
                print "SUPublicEDKey = " key
                next
            }
            { print }
        ' "$LOCAL_XCCONFIG" > "$tmp_file"
        mv "$tmp_file" "$LOCAL_XCCONFIG"
        echo "   기존 파일의 SUPublicEDKey 만 업데이트"
    else
        echo "SUPublicEDKey = $PUBLIC_KEY" >> "$LOCAL_XCCONFIG"
        echo "   SUPublicEDKey 줄 추가"
    fi
else
    write_xcconfig
    echo "   새 xcconfig 작성 완료"
fi

# .gitignore 반영 확인
if ! grep -q "Sparkle.release.local.xcconfig" "$ROOT_DIR/.gitignore" 2>/dev/null; then
    echo "Sparkle.release.local.xcconfig" >> "$ROOT_DIR/.gitignore"
    echo "   .gitignore 에 로컬 xcconfig 규칙 추가"
fi

echo
echo "완료"
echo "   공개키: $PUBLIC_KEY"
echo "   로컬 xcconfig: $LOCAL_XCCONFIG"
echo
echo "다음 단계"
echo "   1. Config/Sparkle.release.local.xcconfig 의 SUFeedURL 을 확인/수정하세요"
echo "   2. notarytool 자격이 없다면 다음 명령으로 저장:"
echo "        xcrun notarytool store-credentials \"$DEFAULT_NOTARY_PROFILE\" \\"
echo "            --apple-id YOUR@EMAIL --team-id 5YG4V2PLZV"
echo "   3. Scripts/build-notarize-release.sh 실행"
