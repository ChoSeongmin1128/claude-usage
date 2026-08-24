# Apple Developer 기반 배포/업데이트 전략

최종 갱신: 2026-08-14

## 1. 현재 결론

- 정식 배포는 `Developer ID + notarization + direct download` 기준으로 유지합니다.
- 앱 내 업데이트는 `Sparkle`을 사용합니다.
- GitHub Release는 DMG/ZIP 산출물 저장소이고, GitHub Pages의 `gh-pages` 브랜치는 Sparkle appcast 호스팅 용도입니다.
- 베타/검증은 별도 코드 브랜치가 아니라 staging release channel로 처리합니다.
- `Mac App Store`는 보류합니다. 현재 앱은 브라우저 쿠키, CLI credential, Keychain, 로컬 파일 접근을 다루므로 App Store 친화적인 구조가 아닙니다.

## 2. 구현된 범위

현재 저장소에는 아래 배포 경로가 들어 있습니다.

- Sparkle 2.8.1 패키지 통합
- [UpdateService.swift](ClaudeUsage/Services/UpdateService.swift)의 `Sparkle` / `GitHub Release fallback` 엔진 선택 구조
- [setup-sparkle-keys.sh](Scripts/setup-sparkle-keys.sh)의 키 생성 및 `SUFeedURL` 초기화
- [build-notarize-release.sh](Scripts/build-notarize-release.sh)의 archive -> notarize -> staple -> ZIP/DMG 생성
- [release.sh](Scripts/release.sh)의 채널·버전 입력, 사전 검증, 공증 build,
  immutable Release, 원격 검증, Pages 전파 통합
- [publish-release.sh](Scripts/publish-release.sh)의 tag / GitHub Release / appcast asset 생성
- [verify-release-artifact.sh](Scripts/verify-release-artifact.sh)의 원격
  DMG·ZIP·appcast, 서명·공증·Gatekeeper·Sparkle 서명 검증
- [publish-pages-appcast.sh](Scripts/publish-pages-appcast.sh)의 `gh-pages` 게시
- [docs/RELEASE.md](docs/RELEASE.md)의 실제 배포 절차
- [docs/PROJECT_WORKFLOW.md](docs/PROJECT_WORKFLOW.md)의 브랜치, 채널, 계정, 로컬 파일 관리 기준

## 3. 채널 구조

현재 운영 기준:

- `dev`: 최신 `main` 기반 작업 단위 커밋과 검증
- `main`: 검증된 `dev` tree를 squash한 배포 기준 브랜치
- `gh-pages`: Sparkle appcast를 호스팅하는 정적 브랜치
- `staging`: 코드 브랜치가 아니라 prerelease + staging appcast channel
- `prod`: staging 검증 후 게시하는 stable release + root appcast channel

채널 URL:

- prod: `https://choseongmin1128.github.io/claude-usage/appcast.xml`
- staging: `https://choseongmin1128.github.io/claude-usage/channels/staging/appcast.xml`

2026-08-14 직접 확인 기준:

- prod feed는 `v2.4.10`의 `2.4.10` (`sparkle:version` `20410`)을 가리킵니다.
- staging feed는 `v2.4.10-staging`의 `2.4.10`
  (`sparkle:version` `20410`)을 가리킵니다.
- `dev`는 작업 브랜치, `main`은 squash된 배포 기준이며 별도 `stg` 코드
  브랜치는 없습니다.

## 4. 업데이트 동작

[UpdateService.swift](ClaudeUsage/Services/UpdateService.swift)는 아래처럼 동작합니다.

- `SUFeedURL` + `SUPublicEDKey`가 유효하면 Sparkle 엔진 사용
- 값이 비어 있거나 placeholder면 GitHub Release fallback 사용
- Sparkle 오류는 그대로 노출하지 않고 `최신 상태`, `실제 feed 장애`, `DMG/Translocation 실행` 등을 구분해 해석

즉, 설정 화면의 `Sparkle 준비됨`은 “패키지가 링크돼 있다”가 아니라 “유효한 feed/public key로 앱 내부 확인이 가능하다”는 뜻입니다.

## 5. 운영 원칙

- staging은 `./Scripts/release.sh stg X.Y.Z`로 실행하며 driver가
  `vX.Y.Z-staging` prerelease와 staging feed를 고정합니다.
- prod는 staging 검증 완료 후 `./Scripts/release.sh prod X.Y.Z`로 실행하며
  driver가 `vX.Y.Z` stable release와 prod feed를 고정합니다.
- staging과 prod는 앱에 들어가는 `SUFeedURL` 이 다르므로 같은 커밋이어도 산출물을 각각 다시 빌드합니다.
- `gh-pages`는 직접 편집하지 않습니다. driver가 immutable Release의 원격
  세 asset을 완전히 검증한 뒤 verifier가 export한 정확한 appcast만
  [publish-pages-appcast.sh](Scripts/publish-pages-appcast.sh)로 게시합니다.
- driver는 GitHub CLI active 계정을 `ChoSeongmin1128`로 맞춰 게시하고 종료
  시 `nathan-glorang`으로 복원합니다.
- `Config/Sparkle.release.local.xcconfig`, Apple notarization key, SSH alias 설정, 로컬 DMG/ZIP 산출물은 저장소에 올리지 않습니다.

## 6. App Store를 보류하는 이유

보류 판단은 그대로 유지합니다.

- 현재 앱은 쿠키/세션/CLI credential/Keychain/로컬 파일을 폭넓게 다룹니다.
- [ClaudeUsage.entitlements](ClaudeUsage/ClaudeUsage.entitlements)의 방향도 App Store용으로 정돈된 상태가 아닙니다.
- App Store 제약을 먼저 맞추면 제품 기능을 먼저 꺾을 가능성이 큽니다.

우선순위는 아래 순서입니다.

1. direct distribution 품질 안정화
2. Sparkle 채널 운영 안정화
3. 별도 Mac의 실제 Sparkle upgrade·메뉴바·CPU 회귀 검증 자동화 보강
4. TestFlight/App Store는 sandbox·entitlement·제품 요구사항을 함께 재설계하는
   별도 제품 전략에서만 검토

## 7. 참고 문서

- 작업 방식: [docs/PROJECT_WORKFLOW.md](docs/PROJECT_WORKFLOW.md)
- 배포 절차: [docs/RELEASE.md](docs/RELEASE.md)
- 프로젝트 개요: [README.md](README.md)
