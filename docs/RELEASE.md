# ClaudeUsage 배포 가이드

## 개요

배포는 네 단계로 구성됩니다.

1. **계정/원격 확인** — GitHub CLI active 계정과 repository 확인
2. **1회성 세팅** — Sparkle 키 + notarization 자격 등록
3. **릴리스 빌드** — notarized 배포 또는 signed-only 내부 배포 산출물 생성
4. **게시** — git tag + GitHub Release 업로드 + Sparkle appcast 발행

스크립트는 모두 `Scripts/` 에 있고 독립 실행 가능합니다.

---

## 0. 계정/브랜치 기준

현재 운영 기준:

- 작업 브랜치: 최신 `main`에서 만든 `dev`, 작업 단위별 커밋과 push
- 릴리스 브랜치: 검증된 `dev`를 squash한 `main`
- staging: 코드 브랜치가 아니라 `vX.Y.Z-staging` prerelease + `/channels/staging/appcast.xml` channel
- prod: staging 검증 후 `vX.Y.Z` stable release + root `/appcast.xml` channel
- `gh-pages`: appcast 정적 호스팅 브랜치이며 수동 코드 작업 대상이 아님

릴리스 전에 GitHub CLI 계정과 원격을 확인합니다.

```bash
gh auth status
gh auth switch --hostname github.com --user ChoSeongmin1128
gh repo view --json nameWithOwner -q .nameWithOwner
git remote -v
```

정상 기준:

- `gh repo view`: `ChoSeongmin1128/claude-usage`
- `origin`: `git@github-seongmin:ChoSeongmin1128/claude-usage.git`

개인 SSH 설정, Apple ID, app-specific password, notarization key, local xcconfig는 저장소에 커밋하지 않습니다. 자세한 작업 방식은 [PROJECT_WORKFLOW.md](PROJECT_WORKFLOW.md)를 기준으로 합니다.

배포 후 평소 작업 계정으로 되돌려야 하는 환경이면 `gh auth switch --hostname github.com --user nathan-glorang` 를 실행합니다.

---

## 1. 1회성 세팅 (머신당 1회)

### 1.1 Notarization 자격 저장

Apple ID 또는 App Store Connect API 키 중 하나:

```bash
# 옵션 A: Apple ID + app-specific password
xcrun notarytool store-credentials "ClaudeUsageNotary" \
    --apple-id "YOUR@EMAIL" \
    --team-id "YOUR_TEAM_ID"
# 프롬프트에서 app-specific password 입력

# 옵션 B: App Store Connect API key (.p8 파일)
xcrun notarytool store-credentials "ClaudeUsageNotary" \
    --key /path/to/AuthKey_XXXX.p8 \
    --key-id XXXXXXXXXX \
    --issuer xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

키체인 프로파일 이름 `ClaudeUsageNotary` 는 이후 스크립트 전체에서 사용됩니다.
앱이 자체 세션 저장에 쓰는 `ClaudeUsage` Keychain 서비스명과 혼동되지 않도록,
공증 프로필에는 별도 이름을 사용합니다.

키체인 프로파일을 쓰지 않고 CodexBar처럼 CI/로컬 환경 변수로만 넘기려면
아래 세 값을 모두 지정합니다. `APP_STORE_CONNECT_API_KEY_P8` 는 `.p8` 파일
내용 전체이며, `\n` 이스케이프가 들어간 한 줄 값도 허용합니다.

```bash
APP_STORE_CONNECT_API_KEY_P8="$(cat /path/to/AuthKey_XXXX.p8)" \
APP_STORE_CONNECT_KEY_ID="XXXXXXXXXX" \
APP_STORE_CONNECT_ISSUER_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" \
RELEASE_CHANNEL=prod \
BUILD_DIR="$HOME/Downloads/ClaudeUsage-release-$(date +%Y%m%d-%H%M)" \
./Scripts/build-notarize-release.sh
```

### 1.2 Sparkle 키 + 로컬 xcconfig 생성

```bash
./Scripts/setup-sparkle-keys.sh
```

수행 내용:
- Sparkle SPM artifact 에서 `generate_keys` 를 찾아 ED25519 키쌍 생성 (개인키는 macOS 키체인에 자동 보관)
- 공개키 출력
- `Config/Sparkle.release.local.xcconfig` 자동 작성:
  - `SUFeedURL` = 기본적으로 GitHub Pages `prod` 채널 (`https://choseongmin1128.github.io/claude-usage/appcast.xml`) 로 추정
  - `SUPublicEDKey` = 방금 생성한 공개키
  - `NOTARY_PROFILE` = "ClaudeUsageNotary"
- `.gitignore` 에 로컬 xcconfig 규칙 추가

키가 이미 있다면 공개키만 재사용하고 새로 생성하지 않습니다. 강제 재생성은 `--force` 플래그.

staging 채널을 기본값으로 쓰고 싶다면:

```bash
./Scripts/setup-sparkle-keys.sh --channel staging
```

SUFeedURL 을 직접 정하고 싶다면 스크립트 실행 후 xcconfig 를 편집하거나 `--feed-url URL` 로 지정:

```bash
./Scripts/setup-sparkle-keys.sh --feed-url https://my-server.com/appcast.xml
```

### 1.3 추가 도구

| 도구 | 설치 | 용도 |
|---|---|---|
| `dmgbuild` | `pipx install dmgbuild` | DMG 레이아웃을 바이너리로 기록 |
| `gh` (GitHub CLI) | `brew install gh` + `gh auth login` | GitHub Release 업로드 |

---

## 2. 릴리스 후보 확정과 빌드

릴리스 전에는 `dev`의 작업 단위 커밋을 모두 push하고 전체 테스트, Release build, 실제 앱 QA, 코드 리뷰를 마칩니다. 그 뒤 `main`에 squash commit 하나로 반영합니다.

다음 릴리스 작업을 시작할 때 `dev`를 최신 `main`으로 다시 맞추는 작업은 직전
`dev`의 최종 tree가 `git diff --exit-code main dev` 기준으로 `main`과 동일해
squash 반영이 끝났음을 확인한 뒤에만 수행합니다. 진행 중인 `dev`를 무조건
재생성하거나 reset하지 않습니다.

```bash
git status --short
git switch main
git pull --ff-only origin main
git merge --squash dev
git commit -m "릴리스 변경 요약"
xcodebuild test -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -destination 'platform=macOS'
git push origin main
```

이후 산출물은 반드시 최종 `main`에서 새로 만듭니다. squash 전 산출물은 commit provenance가 다르므로 게시하지 않습니다.

배포 기준은 `RELEASE_DISTRIBUTION` 으로 고릅니다.

- `notarized` 기본값: Developer ID 서명, Apple notarization, staple, Gatekeeper 검증까지 수행합니다. 웹/공개 다운로드 또는 일반 사용자 배포 기준입니다.
- `internal`: 사내 배포용 signed-only DMG 를 만듭니다. Developer ID 서명과 codesign 검증은 수행하지만 Apple notarization 과 staple 은 건너뜁니다. 다운로드 quarantine 경로에서는 macOS Gatekeeper 경고나 차단이 나올 수 있습니다.

같은 이름의 유효한 `Developer ID Application` 인증서가 둘 이상이면 빌드
스크립트는 임의 선택하지 않고 중단합니다. 먼저 기존 배포 앱 또는 직전 정상
산출물의 서명 인증서 SHA-1을 확인하고, 현재 Keychain에 같은 인증서가 유효한지
대조한 뒤 그 값을 `CERT_HASH`로 명시합니다.

```bash
# 직전 정상 앱의 서명 인증서 SHA-1
codesign -d --extract-certificates /path/to/ClaudeUsage.app
openssl x509 -inform DER -in codesign0 -noout -fingerprint -sha1

# 현재 사용 가능한 Developer ID Application 인증서
security find-identity -v -p codesigning

CERT_HASH="확인한_SHA1_공백_없이" \
RELEASE_CHANNEL=staging \
./Scripts/build-notarize-release.sh
```

인증서 이름이 같다는 이유만으로 첫 번째 identity를 택하지 않습니다. 일치하는
기존 정상 산출물이 없으면 인증서 만료일과 팀 ID를 확인하고 릴리스 담당자가
대상을 명시적으로 결정해야 합니다.

```bash
# staging
RELEASE_CHANNEL=staging ./Scripts/build-notarize-release.sh

# prod
RELEASE_CHANNEL=prod ./Scripts/build-notarize-release.sh

# signed-only 사내 배포
RELEASE_DISTRIBUTION=internal \
BUILD_DIR="$HOME/Downloads/ClaudeUsage-internal-$(date +%Y%m%d-%H%M)" \
./Scripts/build-notarize-release.sh
```

notarized 수행 단계:

1. Xcode archive (`build/release/ClaudeUsage.xcarchive`)
2. 앱을 ZIP 으로 감싸 notarytool 제출 (`--wait`)
3. stapler 로 앱에 티켓 부착 후 `stapler validate` / `spctl --type execute` 검증
4. stapled ZIP 재생성 (Sparkle appcast 다운로드 대상)
5. `Scripts/make-dmg.sh` 호출 → `dmgbuild` 로 UI DMG 생성 + Developer ID 서명
6. DMG notarization 제출 (`--wait`)
7. DMG 에 티켓 부착 후 `stapler validate`
8. `spctl --type open --context context:primary-signature` 최종 검증

산출물:
- `build/release/ClaudeUsage.xcarchive/Products/Applications/ClaudeUsage.app` (스테이플됨)
- `build/release/ClaudeUsage.zip` (Sparkle 용)
- `build/release/ClaudeUsage.dmg` (설치 배포용)

internal 수행 단계:

1. Xcode archive
2. Sparkle helper 와 앱을 Developer ID 로 재서명
3. signed-only ZIP 생성
4. `codesign --verify --deep --strict` 로 앱 검증
5. `Scripts/make-dmg.sh` 호출 → `dmgbuild` 로 UI DMG 생성 + Developer ID 서명
6. `codesign --verify` 로 DMG 검증, `spctl` 은 참고 결과로만 출력

빠른 로컬 테스트로 DMG 를 건너뛰려면:

```bash
SKIP_DMG=1 ./Scripts/build-notarize-release.sh
```

### DMG UI 커스터마이징

`Scripts/make-dmg.sh` 환경변수로 조정:
- `WINDOW_W`, `WINDOW_H` — 창 크기 (기본 540×380)
- `APP_ICON_X/Y`, `APPS_ICON_X/Y` — 아이콘 좌표
- `BACKGROUND_PNG` — 배경 이미지 (기본 `Scripts/dmg-assets/background.png`)

배경 이미지를 재생성하려면:

```bash
swift Scripts/dmg-assets/generate-background.swift Scripts/dmg-assets/background.png
```

---

## 3. GitHub 게시

```bash
# working tree 가 clean 하고 HEAD 가 릴리스 대상 커밋일 때
./Scripts/publish-release.sh vX.Y.Z
```

수행 단계:

1. 태그 형식/중복 검증
2. `build/release/` 에 DMG + ZIP 존재 확인
3. Sparkle `generate_appcast` 로 `appcast.xml` 생성
   - 다운로드 URL prefix 는 `--download-base-url`, `SPARKLE_DOWNLOAD_BASE_URL`, 또는 저장소의 `releases/download/<TAG>` 추론값을 사용
   - `SUFeedURL` 은 Sparkle 클라이언트가 읽을 feed 위치로만 사용하며, GitHub Pages 채널 URL이어도 됩니다
4. `git tag` + `git push origin <TAG>`
5. `gh release create` 로 DMG + ZIP + appcast.xml 업로드
6. feed URL 이 GitHub Pages 채널이면 [publish-pages-appcast.sh](../Scripts/publish-pages-appcast.sh) 로 `gh-pages` 브랜치의 appcast도 함께 갱신

옵션:
- `--draft` — 초안으로 생성 (공개 전 수동 승인)
- `--prerelease` — pre-release 표시
- `--channel prod|staging` — 기본 채널 지정 (미지정 시 stable=prod, prerelease=staging)
- `--notes "..."` — 릴리스 노트 직접 지정 (미지정 시 `--generate-notes`)

staging 예:

```bash
RELEASE_CHANNEL=staging ./Scripts/build-notarize-release.sh
./Scripts/publish-release.sh vX.Y.Z-staging --prerelease --channel staging --notes "릴리스 요약"
```

게시 후에는 release의 원격 DMG를 다시 다운로드해 최종 사용자 경로를 검증합니다. 로컬 build 산출물을 Downloads에 복사한 것으로 원격 배포 검증을 대신하지 않습니다.

```bash
DOWNLOAD_DIR="$HOME/Downloads/ClaudeUsage-X.Y.Z-staging"
mkdir -p "$DOWNLOAD_DIR"
gh release download vX.Y.Z-staging \
  --repo ChoSeongmin1128/claude-usage \
  --pattern ClaudeUsage.dmg \
  --dir "$DOWNLOAD_DIR"

xcrun stapler validate "$DOWNLOAD_DIR/ClaudeUsage.dmg"
spctl -a -t open --context context:primary-signature -vv "$DOWNLOAD_DIR/ClaudeUsage.dmg"
shasum -a 256 "$DOWNLOAD_DIR/ClaudeUsage.dmg"
```

DMG를 mount한 뒤 앱도 별도로 확인합니다.

```bash
xcrun stapler validate "/Volumes/ClaudeUsage/ClaudeUsage.app"
spctl -a -t exec -vv "/Volumes/ClaudeUsage/ClaudeUsage.app"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "/Volumes/ClaudeUsage/ClaudeUsage.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "/Volumes/ClaudeUsage/ClaudeUsage.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "/Volumes/ClaudeUsage/ClaudeUsage.app/Contents/Info.plist"
```

검증 완료 후 사용자가 요청한 경우에만 mount한 앱으로 `~/Downloads/ClaudeUsage.app`을 교체합니다. 배포 작업이 끝나면 GitHub CLI 계정을 평소 계정으로 복원합니다.

```bash
gh auth switch --hostname github.com --user nathan-glorang
```

prod 예:

```bash
RELEASE_CHANNEL=prod ./Scripts/build-notarize-release.sh
./Scripts/publish-release.sh vX.Y.Z --channel prod --notes "릴리스 요약"
```

---

## 자동 업데이트 동작

Sparkle 이 클라이언트 앱에서 하는 일:
1. `SUFeedURL` (= GitHub Pages channel URL) 을 30분마다 폴링
2. `appcast.xml` 파싱 → 현재 설치 버전과 비교
3. 새 버전이 있으면 `ClaudeUsage.zip` 다운로드
4. `SUPublicEDKey` 로 ED25519 서명 검증
5. popover 설치 버튼을 누르면 `XPCServices/Installer.xpc` 가 교체 설치

권장 feed 구조:

- `prod`: `https://choseongmin1128.github.io/claude-usage/appcast.xml`
- `staging`: `https://choseongmin1128.github.io/claude-usage/channels/staging/appcast.xml`

`gh-pages` 브랜치는 위 appcast를 배포하는 정적 브랜치입니다. 코드용 `stg` 브랜치와는 역할이 다릅니다. 현재는 별도 `stg` 코드 브랜치를 운용하지 않고, `main`에서 staging channel을 먼저 게시한 뒤 검증 완료분만 prod channel로 게시합니다.

### 업데이트 채널 분리

staging 빌드는 `RELEASE_CHANNEL=staging ./Scripts/build-notarize-release.sh` 또는 `SU_FEED_URL` 로 채널을 고정하세요.
stable/prod 릴리스는 `RELEASE_CHANNEL=prod ./Scripts/build-notarize-release.sh` 로 root `appcast.xml` 을 명시합니다. staging 과 prod 는 앱에 들어가는 `SUFeedURL` 이 다르므로 staging 산출물을 prod에 재사용하지 않습니다.

---

## 문제 해결

### "No Keychain password item found for profile"

notarytool 자격이 키체인에서 지워졌거나 잠겨있습니다.

```bash
security unlock-keychain ~/Library/Keychains/login.keychain-db
# 또는 자격 재등록
xcrun notarytool store-credentials "ClaudeUsageNotary" --apple-id ... --team-id ...
```

### "HTTP status code: 401. Invalid credentials"

`ClaudeUsageNotary` notarytool keychain profile 은 존재하지만 Apple ID, team ID,
또는 app-specific password 가 더 이상 유효하지 않은 상태입니다.
`Scripts/build-notarize-release.sh` 는 archive 전에 `notarytool history` 로
공증 자격을 사전 검증하므로, 이 오류가 나면 새 산출물은 만들어지지 않습니다.

`keychain profile "ClaudeUsage" 이름이 ClaudeUsage 앱 세션 Keychain 항목과 충돌합니다`
메시지가 함께 나오면, 로컬 `Config/Sparkle.release.local.xcconfig` 가 예전 기본값
`NOTARY_PROFILE = ClaudeUsage` 를 가리키는 상태입니다. 이 이름은 앱의 기존
세션 Keychain 서비스명과 충돌하므로 `NOTARY_PROFILE = ClaudeUsageNotary` 로
바꾼 뒤 아래 복구 명령을 실행합니다.

복구:

```bash
xcrun notarytool store-credentials "ClaudeUsageNotary" \
    --apple-id "YOUR@EMAIL" \
    --team-id "5YG4V2PLZV"
# 프롬프트에서 appleid.apple.com 에서 새로 발급한 app-specific password 입력

xcrun notarytool history --keychain-profile "ClaudeUsageNotary"
```

환경변수로 우회하려면 세 값을 모두 지정해야 합니다.

```bash
NOTARY_APPLE_ID="YOUR@EMAIL" \
NOTARY_PASSWORD="APP_SPECIFIC_PASSWORD" \
NOTARY_TEAM_ID="5YG4V2PLZV" \
RELEASE_CHANNEL=prod \
BUILD_DIR="$HOME/Downloads/ClaudeUsage-release-$(date +%Y%m%d-%H%M)" \
./Scripts/build-notarize-release.sh
```

App Store Connect API key 를 쓰는 경우에는 `NOTARY_KEY_PATH`,
`NOTARY_KEY_ID`, `NOTARY_ISSUER` 를 모두 지정하거나, CodexBar와 같은
`APP_STORE_CONNECT_API_KEY_P8`, `APP_STORE_CONNECT_KEY_ID`,
`APP_STORE_CONNECT_ISSUER_ID` 조합을 지정합니다. 후자는 스크립트가 임시
`.p8` 파일로 변환해 `notarytool` 에 넘기고 종료 시 삭제합니다.

### "SUFeedURL 을 찾지 못했습니다"

`Config/Sparkle.release.local.xcconfig` 가 없거나 값이 placeholder 입니다. `Scripts/setup-sparkle-keys.sh` 재실행.

### DMG UI 가 이상하게 뜸

Finder 가 동명 볼륨의 과거 상태를 캐싱했을 수 있습니다.

```bash
killall Finder
hdiutil detach "/Volumes/Install ClaudeUsage" -force 2>/dev/null
```

후 DMG 재마운트.

### Notarization 이 "In Progress" 로 멈춤

`--wait` 는 최대 3시간 대기합니다. 체크:

```bash
xcrun notarytool history --keychain-profile "ClaudeUsageNotary"
xcrun notarytool log <submission-id> --keychain-profile "ClaudeUsageNotary"
```

대부분의 실패 원인은 hardened runtime 비활성이거나 entitlements 누락.

### `generate_keys` / `generate_appcast` 를 못 찾음

Xcode 에서 한 번 Release 빌드를 돌리면 Sparkle SPM artifact 가 `~/Library/Developer/Xcode/DerivedData` 에 다운로드됩니다. 그 후 재시도.

---

## 체크리스트 요약

릴리스 전:
- [ ] `gh auth switch --hostname github.com --user ChoSeongmin1128`
- [ ] `gh repo view --json nameWithOwner -q .nameWithOwner` 가 `ChoSeongmin1128/claude-usage` 출력
- [ ] `git remote -v` 가 `git@github-seongmin:ChoSeongmin1128/claude-usage.git` 기준
- [ ] working tree clean

1회성:
- [ ] `xcrun notarytool store-credentials ClaudeUsageNotary ...`
- [ ] `./Scripts/setup-sparkle-keys.sh`
- [ ] `pipx install dmgbuild` / `brew install gh`

릴리스마다:
- [ ] `xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -destination 'platform=macOS' test`
- [ ] 버전 bump 커밋 + push
- [ ] staging 이면 `RELEASE_CHANNEL=staging ./Scripts/build-notarize-release.sh`
- [ ] prod 이면 `RELEASE_CHANNEL=prod ./Scripts/build-notarize-release.sh`
- [ ] `PlistBuddy` 로 `SUFeedURL` 이 의도한 채널인지 확인
- [ ] stable 이면 `./Scripts/publish-release.sh vX.Y.Z --channel prod`
- [ ] staging 이면 `./Scripts/publish-release.sh vX.Y.Z-staging --prerelease --channel staging`
- [ ] `gh-pages` 의 `appcast.xml` / `channels/staging/appcast.xml` 확인
- [ ] 별도 Mac 에서 앱 실행 후 "업데이트 확인" 눌러 Sparkle 경로 검증
- [ ] 필요 시 `gh auth switch --hostname github.com --user nathan-glorang` 로 평소 작업 계정 복구
