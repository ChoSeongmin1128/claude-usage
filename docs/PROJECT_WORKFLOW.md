# ClaudeUsage 프로젝트 작업 방식

최종 갱신: 2026-04-30

## 현재 기준

- 코드 브랜치는 `main` 하나를 기준으로 운용합니다.
- 현재 원격에는 코드용 `dev` 또는 `stg` 브랜치가 없습니다.
- `gh-pages` 는 Sparkle appcast와 GitHub Pages 정적 파일을 올리는 배포 산출물 브랜치입니다. 코드 작업이나 스테이징 검증 브랜치로 쓰지 않습니다.
- staging은 브랜치가 아니라 release channel입니다. 최신 `main` 커밋을 prerelease로 빌드해 `channels/staging/appcast.xml` 에 게시합니다.
- prod는 staging 검증이 끝난 버전만 stable release로 게시합니다.

## 브랜치와 채널

| 구분 | 역할 | 현재 상태 |
|---|---|---|
| `main` | 실제 개발과 릴리스 기준 코드 브랜치 | 사용 중 |
| `dev` | 별도 장기 개발 브랜치 | 현재 없음 |
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

## Staging 배포 절차

전제: working tree가 clean이고, 배포할 코드가 `main`에 커밋되어 있어야 합니다.

```bash
xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -destination 'platform=macOS' test
git push origin main
RELEASE_CHANNEL=staging ./Scripts/build-notarize-release.sh
./Scripts/publish-release.sh vX.Y.Z-staging --prerelease --channel staging --notes "릴리스 요약"
curl -fsSL https://choseongmin1128.github.io/claude-usage/channels/staging/appcast.xml | sed -n '1,40p'
gh release view vX.Y.Z-staging --json tagName,isPrerelease,url
```

필요하면 사용자 전달용 DMG를 다운로드 폴더에 복사합니다.

```bash
cp build/release/ClaudeUsage.dmg ~/Downloads/ClaudeUsage-X.Y.Z-staging.dmg
```

## Prod 배포 절차

prod는 staging에서 같은 코드/동작 검증이 끝난 뒤에만 진행합니다.

```bash
xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -destination 'platform=macOS' test
git push origin main
./Scripts/build-notarize-release.sh
./Scripts/publish-release.sh vX.Y.Z --channel prod --notes "릴리스 요약"
curl -fsSL https://choseongmin1128.github.io/claude-usage/appcast.xml | sed -n '1,40p'
gh release view vX.Y.Z --json tagName,isPrerelease,isLatest,url
```

prod release는 prerelease로 만들지 않습니다. prod appcast는 root `appcast.xml` 을 갱신합니다.

## 검증 기준

- `xcodebuild ... test` 통과
- `build/release/ClaudeUsage.zip` 과 `build/release/ClaudeUsage.dmg` 생성
- `spctl -a -t open --context context:primary-signature -vv build/release/ClaudeUsage.dmg` 통과
- GitHub Release에 `ClaudeUsage.zip`, `ClaudeUsage.dmg`, `appcast.xml` 업로드
- Pages appcast의 `sparkle:shortVersionString` 과 `sparkle:version` 이 의도한 버전
- staging/prod 앱에서 업데이트 확인이 각 채널 feed를 봄

GitHub Pages는 cache 때문에 feed 반영이 몇 분 늦을 수 있습니다. 의심되면 `git show origin/gh-pages:appcast.xml` 또는 `git show origin/gh-pages:channels/staging/appcast.xml` 로 브랜치 내용과 Pages 응답을 분리해서 확인합니다.
