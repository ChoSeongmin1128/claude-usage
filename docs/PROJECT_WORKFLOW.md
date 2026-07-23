# ClaudeUsage 프로젝트 작업 방식

최종 갱신: 2026-07-23

## 현재 기준

- `main`은 배포 가능한 squash commit만 두는 기준 브랜치입니다.
- 기능/유지보수 작업은 최신 `main`에서 `dev`를 만들고 작업 단위별로 커밋해 원격 `dev`에 올립니다.
- 검증과 코드 리뷰가 끝나면 `dev` 전체를 `main`에 squash commit 하나로 반영합니다.
- `gh-pages` 는 Sparkle appcast와 GitHub Pages 정적 파일을 올리는 배포 산출물 브랜치입니다. 코드 작업이나 스테이징 검증 브랜치로 쓰지 않습니다.
- staging은 브랜치가 아니라 release channel입니다. 최신 `main` 커밋을 prerelease로 빌드해 `channels/staging/appcast.xml` 에 게시합니다.
- prod는 staging 검증이 끝난 버전만 stable release로 게시합니다.
- 2026-05-02 확인 기준 최신 prod/staging feed는 모두 `2.0.15` (`sparkle:version` `20015`) 입니다.

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

공개 예시는 `Config/Sparkle.release.example.xcconfig` 같은 placeholder 파일에만 둡니다. `SUPublicEDKey` 자체는 공개키지만, 실제 feed/profile 조합은 로컬 release override에서 관리하는 편이 안전합니다.

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
xcrun notarytool history --keychain-profile ClaudeUsageNotary --output-format json --no-progress
RELEASE_CHANNEL=staging ./Scripts/build-notarize-release.sh
./Scripts/publish-release.sh vX.Y.Z-staging --prerelease --channel staging --notes "릴리스 요약"
curl -fsSL https://choseongmin1128.github.io/claude-usage/channels/staging/appcast.xml | sed -n '1,40p'
gh release view vX.Y.Z-staging --json tagName,isPrerelease,url
```

사용자 전달본은 로컬 build 폴더를 복사하지 않고 게시된 GitHub Release DMG를 다시 받습니다.

```bash
gh release download vX.Y.Z-staging \
  --repo ChoSeongmin1128/claude-usage \
  --pattern ClaudeUsage.dmg \
  --dir ~/Downloads/ClaudeUsage-X.Y.Z-staging
```

다운로드한 DMG의 checksum을 release asset과 대조하고, mount한 앱의 `stapler`, `spctl`, 버전, staging `SUFeedURL`을 확인합니다. 사용자가 Downloads 앱 교체를 요청한 경우 검증된 DMG에서 꺼낸 앱만 `~/Downloads/ClaudeUsage.app`에 둡니다.

배포가 끝나면 `gh auth switch --hostname github.com --user nathan-glorang`로 평소 계정을 복원합니다.

## Prod 배포 절차

prod는 staging에서 같은 코드/동작 검증이 끝난 뒤에만 진행합니다. staging 산출물을 그대로 재사용하지 말고 prod feed URL이 들어간 release build를 다시 만듭니다.

```bash
xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -destination 'platform=macOS' test
git push origin main
RELEASE_CHANNEL=prod ./Scripts/build-notarize-release.sh
./Scripts/publish-release.sh vX.Y.Z --channel prod --notes "릴리스 요약"
curl -fsSL https://choseongmin1128.github.io/claude-usage/appcast.xml | sed -n '1,40p'
gh release view vX.Y.Z --json tagName,isPrerelease,url
```

prod release는 prerelease로 만들지 않습니다. prod appcast는 root `appcast.xml` 을 갱신합니다.

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
