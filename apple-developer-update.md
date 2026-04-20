# Apple Developer 기반 배포/업데이트 전략

최종 갱신: 2026-04-20

## 1. 현재 결론

- 정식 배포는 `Developer ID + notarization + direct download`
- 앱 내 업데이트는 `Sparkle`
- 베타는 필요 시 `TestFlight`
- `Mac App Store`는 보류

이 판단은 그대로 유지합니다. 현재 앱은 브라우저 쿠키, CLI credential, Keychain, 로컬 파일 접근을 다루므로 App Store 친화적인 구조가 아닙니다.

## 2. 지금 실제로 구현된 범위

“Sparkle 도입 예정” 단계는 이미 지났습니다. 현재 저장소에는 아래가 들어 있습니다.

- Sparkle 2.8.1 패키지 통합
- [UpdateService.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Services/UpdateService.swift) 의 `Sparkle` / `GitHub Release fallback` 엔진 선택 구조
- [setup-sparkle-keys.sh](/Users/seongmin/Personal/ClaudeUsage/Scripts/setup-sparkle-keys.sh) 의 키 생성 및 `SUFeedURL` 초기화
- [build-notarize-release.sh](/Users/seongmin/Personal/ClaudeUsage/Scripts/build-notarize-release.sh) 의 archive -> notarize -> staple -> ZIP/DMG 재생성
- [publish-release.sh](/Users/seongmin/Personal/ClaudeUsage/Scripts/publish-release.sh) 의 tag / GitHub Release / appcast 생성
- [publish-pages-appcast.sh](/Users/seongmin/Personal/ClaudeUsage/Scripts/publish-pages-appcast.sh) 의 `gh-pages` 게시
- [docs/RELEASE.md](/Users/seongmin/Personal/ClaudeUsage/docs/RELEASE.md) 의 실제 배포 절차 문서

즉, 지금의 병목은 “Sparkle을 넣을지 말지”가 아니라 “현재 원격 운영 상태를 채널 전략에 맞게 마무리했는지”입니다.

## 3. 채널 구조

현재 기준 channel 설계는 아래가 맞습니다.

- `prod`: `https://OWNER.github.io/REPO/appcast.xml`
- `staging`: `https://OWNER.github.io/REPO/channels/staging/appcast.xml`

그리고 브랜치 역할은 별개입니다.

- `main`: stable/prod 코드
- `dev`: 개발 코드
- `stg`: 필요하면 별도 운용하는 코드용 스테이징 브랜치
- `gh-pages`: Sparkle appcast를 호스팅하는 정적 브랜치

중요한 점:

- `gh-pages` 는 코드 스테이징 브랜치가 아닙니다.
- 2026-04-20 기준 원격에는 `main`, `dev`, `codex-v2-integration`, `gh-pages` 만 있고 `stg` 는 없습니다.

## 4. 현재 운영 상태

로컬 코드/스크립트는 channel 분리를 이해하지만, 원격 운영 상태는 아직 정리 중입니다.

2026-04-20 직접 확인 기준:

- 현재 설치된 `/Applications/ClaudeUsage.app` 는 `2.0.1 (20001)` 입니다.
- 해당 앱은 production feed인 `https://choseongmin1128.github.io/claude-usage/appcast.xml` 을 봅니다.
- 그런데 현재 `gh-pages` root 에는 `appcast.xml` 이 없고, `/channels/staging/appcast.xml` 만 게시돼 있습니다.
- 따라서 production feed 는 현재 `404` 입니다.

즉, 지금 사용자에게 보이는 “업데이트 확인 실패”는 Sparkle 자체의 근본 문제가 아니라, `prod feed URL` 과 실제 게시 상태가 맞지 않기 때문에 생기는 운영 문제입니다.

## 5. 현재 코드의 업데이트 동작

[UpdateService.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Services/UpdateService.swift) 는 아래처럼 동작합니다.

- `SUFeedURL` + `SUPublicEDKey` 가 유효하면 Sparkle 엔진 사용
- 값이 비어 있거나 placeholder 면 GitHub Release fallback 사용
- Sparkle 에러는 그대로 노출하지 않고 `최신 상태`, `실제 feed 장애`, `DMG/Translocation 실행` 등을 구분해 해석

즉, 설정 화면의 `Sparkle 준비됨`은 “패키지가 링크돼 있다”가 아니라 “유효한 feed/public key로 앱 내부 확인이 가능하다”는 뜻입니다.

## 6. 아직 남은 운영 작업

가장 우선순위가 높은 일은 아래입니다.

1. `gh-pages` root 에 production `appcast.xml` 을 최초 게시
2. stable 릴리스와 staging prerelease의 역할을 다시 맞춤
3. `2.0.0 -> 2.0.1` 같은 실제 승급 시나리오를 prod/staging 각각 다시 검증

현재는 staging path만 살아 있기 때문에, stable/prod 설치본이 정상 동작한다고 보기 어렵습니다.

## 7. App Store를 보류하는 이유

지금도 보류 판단은 그대로 유지합니다.

- 현재 앱은 쿠키/세션/CLI credential/Keychain/로컬 파일을 폭넓게 다룹니다.
- [ClaudeUsage.entitlements](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/ClaudeUsage.entitlements) 의 방향도 App Store용으로 정돈된 상태가 아닙니다.
- App Store 제약을 먼저 맞추려 들면 제품 기능을 먼저 꺾게 됩니다.

따라서 우선순위는 계속 아래 순서가 맞습니다.

1. direct distribution 품질 안정화
2. Sparkle 채널 운영 안정화
3. 필요 시 TestFlight
4. App Store는 별도 제품 전략으로 재검토

## 8. 참고 문서

- 배포 절차: [docs/RELEASE.md](/Users/seongmin/Personal/ClaudeUsage/docs/RELEASE.md)
- 프로젝트 개요: [README.md](/Users/seongmin/Personal/ClaudeUsage/README.md)
