# ClaudeUsage 배포 가이드

## 개요

배포는 네 단계로 구성됩니다.

1. **계정/원격 확인** — GitHub CLI active 계정과 repository 확인
2. **1회성 세팅** — Sparkle 키 + notarization 자격 등록
3. **릴리스 빌드** — archive → notarize → staple → DMG 생성/서명/공증
4. **게시** — git tag + GitHub Release 업로드 + Sparkle appcast 발행

스크립트는 모두 `Scripts/` 에 있고 독립 실행 가능합니다.

---

## 0. 계정/브랜치 기준

현재 운영 기준:

- 코드 브랜치: `main`
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
xcrun notarytool store-credentials "ClaudeUsage" \
    --apple-id "YOUR@EMAIL" \
    --team-id "YOUR_TEAM_ID"
# 프롬프트에서 app-specific password 입력

# 옵션 B: App Store Connect API key (.p8 파일)
xcrun notarytool store-credentials "ClaudeUsage" \
    --key /path/to/AuthKey_XXXX.p8 \
    --key-id XXXXXXXXXX \
    --issuer xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

키체인 프로파일 이름 `ClaudeUsage` 는 이후 스크립트 전체에서 사용됩니다.

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
  - `NOTARY_PROFILE` = "ClaudeUsage"
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

## 2. 릴리스 빌드 (버전마다)

```bash
# staging
RELEASE_CHANNEL=staging ./Scripts/build-notarize-release.sh

# prod
RELEASE_CHANNEL=prod ./Scripts/build-notarize-release.sh
```

수행 단계:

1. Xcode archive (`build/release/ClaudeUsage.xcarchive`)
2. 앱을 ZIP 으로 감싸 notarytool 제출 (`--wait`)
3. stapler 로 앱에 티켓 부착
4. stapled ZIP 재생성 (Sparkle appcast 다운로드 대상)
5. `Scripts/make-dmg.sh` 호출 → `dmgbuild` 로 UI DMG 생성 + Developer ID 서명
6. DMG notarization 제출 (`--wait`)
7. DMG 에 티켓 부착
8. `spctl -a -t open` 최종 검증

산출물:
- `build/release/ClaudeUsage.xcarchive/Products/Applications/ClaudeUsage.app` (스테이플됨)
- `build/release/ClaudeUsage.zip` (Sparkle 용)
- `build/release/ClaudeUsage.dmg` (설치 배포용)

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

prod 예:

```bash
RELEASE_CHANNEL=prod ./Scripts/build-notarize-release.sh
./Scripts/publish-release.sh vX.Y.Z --channel prod --notes "릴리스 요약"
```

---

## 자동 업데이트 동작

Sparkle 이 클라이언트 앱에서 하는 일:
1. `SUFeedURL` (= GitHub Pages channel URL) 을 주기적으로 폴링
2. `appcast.xml` 파싱 → 현재 설치 버전과 비교
3. 새 버전이 있으면 `ClaudeUsage.zip` 다운로드
4. `SUPublicEDKey` 로 ED25519 서명 검증
5. 사용자에게 설치 프롬프트 → `XPCServices/Installer.xpc` 가 교체 설치

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
xcrun notarytool store-credentials "ClaudeUsage" --apple-id ... --team-id ...
```

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
xcrun notarytool history --keychain-profile "ClaudeUsage"
xcrun notarytool log <submission-id> --keychain-profile "ClaudeUsage"
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
- [ ] `xcrun notarytool store-credentials ClaudeUsage ...`
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
