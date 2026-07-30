# ClaudeUsage 프로젝트 작업 방식

최종 갱신: 2026-07-27

## 현재 기준

- `main`은 배포 가능한 squash commit만 두는 기준 브랜치입니다.
- 기능/유지보수 작업은 최신 `main`에서 `dev`를 만들고 작업 단위별로 커밋해 원격 `dev`에 올립니다.
- 검증과 코드 리뷰가 끝나면 `dev` 전체를 `main`에 squash commit 하나로 반영합니다.
- `gh-pages` 는 Sparkle appcast와 GitHub Pages 정적 파일을 올리는 배포 산출물 브랜치입니다. 코드 작업이나 스테이징 검증 브랜치로 쓰지 않습니다.
- staging은 브랜치가 아니라 release channel입니다. 최신 `main` 커밋을 prerelease로 빌드해 `channels/staging/appcast.xml` 에 게시합니다.
- prod는 staging 검증이 끝난 버전만 stable release로 게시합니다.
- 2026-07-27 확인 기준 최신 prod/staging feed는 모두 `2.3.3` (`sparkle:version` `20330`) 입니다.

## 브랜치와 채널

| 구분 | 역할 | 현재 상태 |
|---|---|---|
| `main` | squash된 배포 후보와 릴리스 기준 | 사용 중 |
| `dev` | 최신 `main` 기반 작업 단위 커밋/검증 | 사용 중 |
| `stg` | 코드 브랜치가 아니라 staging channel로 운용 | 현재 브랜치 없음 |
| `gh-pages` | appcast 정적 호스팅 | 스크립트가 갱신 |

채널 URL:

- prod: `https://choseongmin1128.github.io/claude-usage/appcast.xml`
- staging: `https://choseongmin1128.github.io/claude-usage/channels/staging/appcast.xml`

태그 규칙:

- prod: `vX.Y.Z`
- staging: `vX.Y.Z-staging`

`2.4.0` 이후 build number는
`major * 10000 + minor * 100 + patch`로 계산합니다. 예:
`2.4.0 → 20400`, `2.4.1 → 20401`. 과거 `2.3.x`의 `20310/20320/20330`은
published metadata에 남는 역사적 값이며 새 후보 계산에 재사용하지 않습니다.

## GitHub 계정과 원격

이 저장소의 배포 작업은 `ChoSeongmin1128/claude-usage` 기준으로 실행합니다.

릴리스 전에 아래를 확인합니다.

```bash
gh auth status
gh auth switch --hostname github.com --user ChoSeongmin1128
gh repo view --json nameWithOwner -q .nameWithOwner
git remote -v
```

정상 기대값:

- `gh repo view` 출력: `ChoSeongmin1128/claude-usage`
- `origin`: `git@github-seongmin:ChoSeongmin1128/claude-usage.git`

여러 GitHub 계정을 쓰는 환경에서는 `nathan-glorang` 같은 다른 계정이 active인지 반드시 확인합니다. GitHub Release, tag push, `gh-pages` 갱신은 active 계정과 SSH alias가 서로 어긋나면 실패하거나 엉뚱한 권한 문제로 보입니다.

배포가 끝난 뒤 평소 작업 계정으로 되돌려야 한다면 아래처럼 전환합니다.

```bash
gh auth switch --hostname github.com --user nathan-glorang
```

`github-seongmin` SSH host alias 설정은 개인 머신 설정이므로 저장소에 넣지 않습니다. 필요하면 `~/.ssh/config` 에서만 관리합니다.

## 로컬/개인 파일 관리

저장소에 커밋하지 않는 항목:

- `Config/Sparkle.release.local.xcconfig`
- `.env`, `.env.*`
- `*.local`, `*.local.*`, `*.secret`, `*.secrets`, `secrets/`
- Apple notarization API key: `AuthKey_*.p8`, `*.p8`
- 인증서와 프로비저닝 파일: `*.p12`, `*.mobileprovision`
- 로컬 빌드 산출물: `build/`, `DerivedData/`, `*.xcarchive`
- 배포 산출물: `ClaudeUsage.zip`, `ClaudeUsage.dmg`, `*.dmg`, `*.pkg`
- 개인 머신 경로, SSH host alias 세부값, Apple ID, app-specific password

Sparkle 개인키, 실제 feed/profile과 공증 자격은 local override/Keychain에서
관리합니다. `SUPublicEDKey`는 다운로드 서명의 공개 trust root이므로
`Config/Release.xcconfig`에 추적합니다. `Scripts/setup-sparkle-keys.sh
--force`는 local 설정만 다시 작성하며 기존 Keychain signing key를 회전하지
않습니다. 실제 키 회전은 기존 설치 앱의 update trust chain을 포함한 별도
incident 절차로 수행하고, 새 key 생성 뒤 local 설정과 tracked trust root를
함께 갱신해 source diff와 구버전 upgrade 호환성을 검토·commit한 뒤에만 새
릴리스를 만듭니다.

주의: Xcode project의 code signing identity와 development team은 빌드 동작에 직접 영향을 줍니다. 완전한 개인 정보 분리를 원하면 별도 작업으로 signing 값을 local xcconfig로 이관한 뒤 release/test 빌드를 다시 검증해야 합니다.

## 개발 및 Staging 배포 절차

`dev`는 릴리스마다 최신 `main`에서 시작합니다. 서로 다른 변경은 커밋을 나누고 각 커밋을 원격 `dev`에 올립니다.

```bash
git switch main
git pull --ff-only origin main

# 직전 dev의 최종 tree가 main에 squash 반영됐는지 먼저 확인
git diff --exit-code main dev
git switch dev
git reset --hard main

# 작업 단위별
git add <files>
git commit -m "..."
git push -u origin dev
```

`dev`를 최신 `main`으로 다시 맞추는 `reset --hard`는 직전 작업의 최종 tree가
`main`과 동일해 squash 반영이 끝났음을 확인한 뒤에만 실행합니다. 진행 중인
`dev`를 `git switch -C`로 무조건 재생성하지 않습니다. diff가 있으면 먼저
`main..dev` 커밋과 squash 반영 상태를 조사합니다.

전체 XCTest, Release build, 실제 UI/계정 QA, 코드 리뷰가 끝난 뒤에만 squash합니다.

```bash
git status --short
git switch main
git pull --ff-only origin main
git merge --squash dev
git commit -m "릴리스 변경 요약"
xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -destination 'platform=macOS' test
git push origin main
```

게시 산출물은 반드시 위 최종 `main` commit에서 새로 빌드합니다. `dev`나 이전 commit에서 만든 ZIP/DMG를 재사용하지 않습니다.

```bash
./Scripts/release.sh stg X.Y.Z
```

driver는 현재 code/prod/staging version과 build, 이전 동일 채널 tag,
입력으로 생성될 `vX.Y.Z-staging`을 먼저 표시합니다. clean main,
notary/test, 이전 원격 앱 준비, notarized build, exact-tag 게시 확인,
새 원격 artifact 검증, 검증된 appcast의 Pages/feed 전파, public feed 포함
최종 재검증을 순서대로 강제합니다. appcast의 Sparkle Ed25519
signature/ZIP length/public key와 public feed의 byte-for-byte 동일성까지
확인합니다.

새 publish 전에 이전 staging Release의 원격 DMG·ZIP·appcast를 GitHub
digest와 대조하고 mount/extract한 앱의 `stapler`, `spctl`, version/build,
staging `SUFeedURL`을 확인합니다. 그 DMG에서 꺼낸 이전 앱만
`~/Downloads/ClaudeUsage-stg.app`에 두어 실제 Sparkle upgrade 기준으로
사용합니다. 새 후보 artifact는 게시 후 별도로 검증하며 Downloads 앱을 새
후보로 덮지 않습니다. 단, `2.4.4`부터 staging app/bundle identifier가
분리되며 최초 공개 버전에는 같은 identity의 이전 앱이 없습니다. 이 한 번만 구
staging upgrade QA를 생략하고, 다음 staging부터 동일 identity upgrade를
검증합니다.

XCTest DerivedData/xcresult, archive 임시 설정, appcast staging,
archive DerivedData와 release build는 각 사용 직후 삭제합니다.
성공·실패·중단과 관계없이 남은 mount/download/worktree/실행 임시 루트를
정리하고 GitHub CLI 계정을 `nathan-glorang`으로 복원합니다.

배포가 중간에 끊기면 같은 명령을 재실행합니다. 현재 `main`과 정확히 같은
tag만 있고 Release가 없으면 tag를 재사용합니다. 세 Release asset이
완전하고 public feed만 이전 버전이면 build와 Downloads 교체 없이 Pages만
복구합니다. 이미 모두 게시된 후보는 원격 검증만 다시 수행합니다.
tag commit 불일치, partial/추가 asset, metadata/feed 분기는 기존 원격을
수정하지 않고 다음 숫자 버전을 요구합니다.

## Prod 배포 절차

prod는 staging에서 같은 코드/동작 검증이 끝난 뒤에만 진행합니다. staging 산출물을 그대로 재사용하지 말고 prod feed URL이 들어간 release build를 다시 만듭니다.

```bash
./Scripts/release.sh prod X.Y.Z
```

driver는 동일 버전 `vX.Y.Z-staging`이 현재 `main`과 같은 commit을 가리키고
draft가 아닌 prerelease인지 확인합니다. 실제 staging QA 완료 여부는 release
기록만으로 추정하지 않으며 prod 실행 전에 별도로 확인해야 합니다. prod
release는 prerelease로 만들지 않으며 prod appcast는 root `appcast.xml`을
갱신합니다.

## 검증 기준

- `xcodebuild ... test` 통과
- `build/release/ClaudeUsage.zip` 과 `build/release/ClaudeUsage.dmg` 생성
- `spctl -a -t open --context context:primary-signature -vv build/release/ClaudeUsage.dmg` 통과
- GitHub Release에 `ClaudeUsage.zip`, `ClaudeUsage.dmg`, `appcast.xml` 업로드
- Pages appcast의 `sparkle:shortVersionString` 과 `sparkle:version` 이 의도한 버전
- staging/prod 앱에서 업데이트 확인이 각 채널 feed를 봄
- release app 안의 `SUFeedURL` 이 의도한 채널 URL인지 확인

```bash
/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' \
  build/release/ClaudeUsage.xcarchive/Products/Applications/ClaudeUsage.app/Contents/Info.plist
```

GitHub Pages는 cache 때문에 feed 반영이 몇 분 늦을 수 있습니다. 의심되면 `git show origin/gh-pages:appcast.xml` 또는 `git show origin/gh-pages:channels/staging/appcast.xml` 로 브랜치 내용과 Pages 응답을 분리해서 확인합니다.
