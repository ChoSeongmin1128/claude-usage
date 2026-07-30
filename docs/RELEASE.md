# ClaudeUsage 배포 가이드

## 개요

일반 배포는 통합 driver 한 명령으로 실행합니다.

```bash
# 환경과 버전을 화면에서 입력
./Scripts/release.sh

# 환경/버전을 인자로 입력
./Scripts/release.sh stg 2.4.0
./Scripts/release.sh prod 2.4.0
```

배포 흐름은 네 단계로 구분됩니다.

1. **계정/원격 확인** — GitHub CLI active 계정과 repository 확인
2. **1회성 사전조건** — Sparkle 키 + notarization 자격 등록
3. **릴리스 빌드** — driver는 notarized 배포 산출물만 생성
4. **게시** — immutable tag/Release 업로드 → 원격 검증 → 검증된 Sparkle appcast 발행

`Scripts/build-notarize-release.sh`와 `Scripts/publish-release.sh`는 driver가
호출하는 저수준 primitive입니다. 복구나 진단 목적이 아니면 두 스크립트를
따로 조합하지 않습니다. signed-only 내부 배포는 통합 driver 범위가 아니며,
필요할 때만 build primitive를 `RELEASE_DISTRIBUTION=internal`로 직접
실행합니다.

### 통합 driver 계약

driver는 먼저 현재 project, prod Release/feed, staging Release/feed의
version과 build를 보여줍니다. 환경은 `stg`, `staging`, `prod`만 받으며,
버전은 suffix 없는 숫자 `X.Y.Z`만 받습니다.

| 입력 환경 | 실제 channel | 자동 생성 tag |
|---|---|---|
| `stg`, `staging` | `staging` | `vX.Y.Z-staging` |
| `prod` | `prod` | `vX.Y.Z` |

채널별 앱 identity도 분리합니다.

| channel | app bundle | bundle identifier | Application Support |
|---|---|---|---|
| `staging` | `ClaudeUsage-stg.app` | `com.seongmin.ClaudeUsage.staging` | `ClaudeUsage-stg` |
| `prod` | `ClaudeUsage.app` | `com.seongmin.ClaudeUsage` | `ClaudeUsage` |

각 채널은 advisory lock으로 한 프로세스만 허용하므로 staging과 prod는 하나씩
동시에 실행할 수 있지만, 같은 채널 앱을 두 번 실행해 provider runtime을
중복 생성할 수는 없습니다. 로컬 QA 설치·실행 기준도 `/Applications`의 위
두 앱이며 임시 build/Downloads 앱을 실행본으로 사용하지 않습니다.

`2.4.4`부터 분리된 staging identity를 사용합니다. 실제 최초 공개 staging이
`2.4.5`처럼 더 높은 버전이면 그 버전을 bootstrap release로 취급합니다. 이전 staging은 prod와
같은 bundle identifier를 썼으므로 Sparkle upgrade 대상이 될 수 없습니다.
driver는 이 최초 전환에서만 구 staging 앱 설치/upgrade QA를 생략하고,
`/Applications/ClaudeUsage.app`의 Developer ID 인증서를 서명 기준으로
사용합니다. 다음 staging 버전부터는 `ClaudeUsage-stg.app`끼리 정상 upgrade
QA를 수행합니다.

`2.4.0`부터 `CURRENT_PROJECT_VERSION`은
`major * 10000 + minor * 100 + patch`로 계산합니다. 따라서
`2.4.0 → 20400`, `2.4.1 → 20401`, `2.4.10 → 20410`입니다.
minor와 patch는 각각 `0...99`만 허용합니다. 과거 `2.3.x`의 `20310`,
`20320`, `20330`은 이전 규칙으로 게시된 역사적 build이며, driver는 이전
앱을 준비할 때 이를 새 공식으로 역산하지 않고 해당 채널 appcast의 실제
published build를 사용합니다.

입력 version/build와 `ClaudeUsage.xcodeproj/project.pbxproj`가 다르면 driver는
source를 자동 수정하거나 commit하지 않고 정확한 차이를 출력한 뒤 중단합니다.
버전 변경도 `dev` 검증과 `main` squash에 포함되어야 release source
provenance가 유지되기 때문입니다.

mutation 없는 계획만 보려면:

```bash
./Scripts/release.sh stg 2.4.0 --non-interactive --dry-run
```

자동화 환경에서도 publish 확인은 생략할 수 없습니다.

```bash
./Scripts/release.sh stg 2.4.0 \
  --non-interactive \
  --confirm-publish v2.4.0-staging \
  --notes "2.4.0 staging"
```

실제 driver는 계정/원격/clean main/tag/notary/test gate, 이전 동일 채널
원격 앱 준비, 기존 build/publish primitive 실행, 새 원격 artifact 검증,
검증된 appcast의 Pages/feed 전파, public feed 포함 최종 재검증을 순서대로
수행합니다. DMG·ZIP·appcast는 GitHub의
SHA-256/size metadata와 대조하고, DMG 및 ZIP의 앱 모두 notarization,
Gatekeeper, bundle version/build/feed를 확인합니다. appcast의 ZIP length,
Sparkle Ed25519 signature와 앱의 `SUPublicEDKey`도 검증하며, public feed는
Release의 `appcast.xml` asset과 byte-for-byte로 대조합니다.

테스트 DerivedData/xcresult, archive용 임시 xcconfig, appcast staging,
archive DerivedData와 release build는 각 사용 단계가 끝나는 즉시
삭제합니다. 실패·중단 시에도 trap이 남은 download, mount, worktree와
실행 임시 루트를 정리하고 GitHub CLI 계정을 `nathan-glorang`으로
복원합니다. fresh/tag-only 게시에서 최종적으로 남는 QA 앱은 prod의
`~/Downloads/ClaudeUsage.app` 또는 staging의
`~/Downloads/ClaudeUsage-stg.app` 하나이며, 새 후보가 아니라 Sparkle
upgrade를 시작할 이전 동일 identity 버전입니다. 분리된 staging identity의
최초 공개 전환에는 이전 QA 앱을 남기지 않습니다. backup app은 만들지
않습니다.

### 중단 후 재실행

tag, GitHub Release와 기존 asset은 한번 만들어지면 이동·수정·덮어쓰기하지
않습니다. driver는 재실행 때 원격 상태를 다시 분류합니다.

| 상태 | 조건 | 재실행 동작 |
|---|---|---|
| `fresh` | 후보 tag와 Release가 모두 없음 | 전체 검증·빌드·게시 |
| `tag_only` | tag가 정확히 현재 `main`을 가리키고 Release는 없음 | 전체 검증·빌드 후 기존 tag를 재사용해 Release 생성 |
| `pages_pending` | tag와 세 asset이 완전하고 public feed만 이전 버전 | Release를 재검증한 뒤 Pages/feed만 복구 |
| `complete` | tag, Release 세 asset, public feed가 모두 후보와 일치 | 원격 산출물과 public feed만 재검증 |
| `burned` | tag commit 불일치, partial/추가 asset, metadata 불일치, feed 분기 | 원격 변경 없이 중단하고 다음 숫자 버전 사용 |

`pages_pending`과 `complete`에서는 XCTest, notarization build, Downloads 앱
교체를 다시 실행하지 않습니다. partial Release에 asset을 추가 업로드하거나
`--clobber`, tag 강제 이동·삭제로 같은 버전을 되살리는 경로는 없습니다.

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
- 공개 trust root인 `Config/Release.xcconfig`의 `SUPublicEDKey`도 같은 값으로 갱신
- `.gitignore` 에 로컬 xcconfig 규칙 추가

키가 이미 있다면 공개키만 재사용하고 새로 생성하지 않습니다. `--force`는
local xcconfig 전체를 다시 작성하는 옵션이며 signing key를 회전하지 않습니다.
[Sparkle의 `generate_keys` 기본 동작](https://github.com/sparkle-project/Sparkle/blob/2.x/generate_keys/main.swift#L1083-L1092)도
기존 Keychain key를 덮어쓰지 않습니다. 실제 키 회전은 기존 설치 앱의 update
trust chain에 영향을 주므로 일반 release와 분리합니다. 기존 private key를
`generate_keys -x`로 안전한 위치에 export한 뒤 Keychain Access에서 정확한
Sparkle signing key를 수동으로 제거하고 새 키를 생성하는 별도 incident
절차와 구버전 upgrade 호환성 검토가 필요합니다. 바뀐 tracked public key는
source diff로 검토·commit해야 하며, local/env key가 tracked trust root와
다르면 archive 전에 중단합니다.

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

정상 배포에서는 이 시점부터 통합 driver를 실행합니다.

```bash
./Scripts/release.sh stg X.Y.Z
```

아래 build 명령은 driver 내부 primitive를 수동 진단할 때의 참고입니다.

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

정상 경로에서는 이 절의 build/publish/download/verification을
`./Scripts/release.sh stg|prod X.Y.Z`가 수행합니다. 아래 명령은 게시
primitive를 독립적으로 복구·진단할 때만 사용합니다.

```bash
# working tree가 clean한 main이고, 산출물을 만든 commit을 고정할 때
EXPECTED_COMMIT="$(git rev-parse HEAD)"
./Scripts/publish-release.sh vX.Y.Z \
  --channel prod \
  --expected-commit "$EXPECTED_COMMIT" \
  --skip-pages-publish
```

수행 단계:

1. 태그 형식/중복 검증
2. `build/release/` 에 DMG + ZIP 존재 확인
3. Sparkle `generate_appcast` 로 `appcast.xml` 생성
   - 다운로드 URL prefix 는 `--download-base-url`, `SPARKLE_DOWNLOAD_BASE_URL`, 또는 저장소의 `releases/download/<TAG>` 추론값을 사용
   - `SUFeedURL` 은 Sparkle 클라이언트가 읽을 feed 위치로만 사용하며, GitHub Pages 채널 URL이어도 됩니다
4. tracked 공개키로 appcast enclosure/length/Ed25519 signature 사전 검증
5. 고정한 `--expected-commit`에만 `git tag` + `git push origin <TAG>`
6. `gh release create` 로 DMG + ZIP + appcast.xml 업로드
7. public Pages는 변경하지 않음. driver가 원격 세 asset을 완전히 검증한 뒤
   verifier에서 export한 정확한 appcast 바이트만
   [publish-pages-appcast.sh](../Scripts/publish-pages-appcast.sh)로 게시

옵션:
- `--prerelease` — pre-release 표시
- `--channel prod|staging` — 기본 채널 지정 (미지정 시 stable=prod, prerelease=staging)
- `--expected-commit SHA` — 검증·빌드한 main commit 고정(필수)
- `--resume-exact-tag` — 같은 commit의 기존 tag만 재사용
- `--notes "..."` — 릴리스 노트 직접 지정 (미지정 시 `--generate-notes`)

staging 예:

```bash
RELEASE_CHANNEL=staging ./Scripts/build-notarize-release.sh
./Scripts/publish-release.sh vX.Y.Z-staging \
  --prerelease \
  --channel staging \
  --expected-commit "$(git rev-parse HEAD)" \
  --skip-pages-publish \
  --notes "릴리스 요약"
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

통합 driver는 새 publish 전에 이전 동일 채널 앱을 실제 Sparkle upgrade
기준으로 준비하기 위해, 검증한 DMG의 앱으로
`~/Downloads/ClaudeUsage.app`을 교체합니다. standalone verifier를 직접
실행할 때는 `--install-to`를 지정한 경우에만 앱을 교체합니다. 배포 작업이
끝나면 GitHub CLI 계정을 평소 계정으로 복원합니다.

```bash
gh auth switch --hostname github.com --user nathan-glorang
```

prod 예:

```bash
RELEASE_CHANNEL=prod ./Scripts/build-notarize-release.sh
./Scripts/publish-release.sh vX.Y.Z \
  --channel prod \
  --expected-commit "$(git rev-parse HEAD)" \
  --skip-pages-publish \
  --notes "릴리스 요약"
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

정상 배포에서는 `./Scripts/release.sh stg|prod X.Y.Z`가 채널을 고정합니다.
저수준 build 진단에서만 `RELEASE_CHANNEL=staging|prod
./Scripts/build-notarize-release.sh` 또는 `SU_FEED_URL`을 직접 사용합니다.
staging과 prod는 앱에 들어가는 `SUFeedURL`이 다르므로 staging 산출물을 prod에
재사용하지 않습니다.

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
- [ ] 버전 bump와 전체 검증을 `dev`에서 완료하고 `main`에 squash + push
- [ ] `./Scripts/release.sh stg|prod X.Y.Z` 실행
- [ ] 출력된 이전 prod/staging/code version과 계산된 build/tag 확인
- [ ] 게시 직전 exact tag 입력
- [ ] `gh-pages`의 `appcast.xml` / `channels/staging/appcast.xml` 확인
- [ ] 원격 DMG·ZIP·appcast digest와 앱 notarization/Gatekeeper 검증 통과
- [ ] `~/Downloads/ClaudeUsage.app`이 이전 동일 채널 버전인지 확인
- [ ] 별도 Mac에서 앱 실행 후 "업데이트 확인"으로 Sparkle upgrade 검증
- [ ] GitHub CLI active 계정이 `nathan-glorang`으로 복원됐는지 확인
