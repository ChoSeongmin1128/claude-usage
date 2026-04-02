# Apple Developer 기반 배포/업데이트 전략

최종 갱신: 2026-04-02

## 1. 결론

- Apple Developer 계정이 이제 가능하므로, 이 앱은 `Developer ID + notarization + Sparkle` 경로를 채택합니다.
- 베타 배포는 필요 시 `TestFlight`, 정식 배포는 `직접 배포 + Sparkle 자동업데이트`의 이중 채널로 갑니다.
- `Mac App Store`도 이론상 가능하지만, 현재 앱 구조와 권한 모델을 보면 우선순위가 낮습니다.

이 판단의 이유는 단순합니다.

- 현재 앱은 App Store형 앱보다 직접 배포형 도구에 가깝습니다.
- [UpdateService.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Services/UpdateService.swift)는 이제 `AppUpdateEngine` 경계 뒤에서 `Sparkle` 과 `GitHub Release fallback` 을 함께 다룰 수 있습니다.
- 다만 현재 개발 빌드는 `SUFeedURL` / `SUPublicEDKey` 가 없어서 여전히 GitHub Release 엔진으로 fallback 됩니다. 즉, 패키지 통합은 끝났지만 실제 appcast 배포 채널은 아직 없습니다.

## 2. 현재 상태 진단

### 이미 있는 것

- Sparkle 2.8.1 Swift Package 통합
- `AppUpdateEngine` 기반 업데이트 엔진 선택 구조
- appcast/feed 미설정 빌드에서 GitHub Release fallback
- 메뉴/설정에서 현재 업데이트 엔진 모드 표시
- 새 버전 발견 시 다운로드 URL 열기

### 없는 것

- 실제 appcast XML 배포 채널
- Sparkle 공개키/개인키 운영
- 코드 서명된 배포 파이프라인
- notarization
- 베타/정식 채널 분리

### 현재 방식의 한계

- appcast/feed 가 없는 현재 개발 빌드는 여전히 GitHub API fallback 에 의존하므로 rate limit 과 장애 표면이 남아 있습니다.
- zip 다운로드 후 수동 교체는 fallback 경로로만 남아 있고, 사용자 경험이 여전히 거칩니다.
- 서명/노타리제이션이 없으면 최초 실행 설명이 계속 번거롭습니다.
- Sparkle 패키지는 붙었지만, 배포 채널이 없으므로 제품 입장에서는 아직 완전한 자동 업데이트가 아닙니다.
- 현재 코드는 [Info.plist](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Info.plist) 의 `SUFeedURL`, `SUPublicEDKey` build setting 경계를 읽습니다. 예시 값은 [Sparkle.release.example.xcconfig](/Users/seongmin/Personal/ClaudeUsage/Config/Sparkle.release.example.xcconfig) 에 추가했습니다.

## 3. Apple Developer 계정이 생기면 가능한 것

Apple 공식 문서 기준, Mac App Store 밖에서 배포하려면 `Developer ID certificate`와 `notarization`이 핵심입니다. Apple은 Developer ID로 서명하고 notarization 티켓을 포함한 앱을 Gatekeeper가 검증한다고 설명합니다. 또한 최신 워크플로우는 `notarytool` 기준입니다.

참고:

- [Developer ID - Apple Developer](https://developer.apple.com/support/developer-id/)
- [Signing your apps for Gatekeeper - Apple Developer](https://developer.apple.com/developer-id/)

즉, 이제 가능한 변화는 아래와 같습니다.

- 앱을 `Developer ID Application`으로 서명
- 배포 산출물(`DMG` 또는 `ZIP`) notarization
- 사용자에게 “그래도 열기” 설명을 거의 제거
- Sparkle 같은 프레임워크를 붙여 자동 업데이트 지원
- TestFlight를 통한 베타 배포 및 피드백 수집

## 4. 배포 경로 비교

### A. Developer ID + notarization + Sparkle

가장 추천합니다.

장점:

- 현재 앱 성격과 가장 잘 맞습니다.
- GitHub Releases 또는 별도 CDN을 그대로 활용할 수 있습니다.
- App Store 심사 제약 없이 빠르게 배포 가능합니다.
- Sparkle로 자동 다운로드/설치 UX를 제공할 수 있습니다.

단점:

- 서명, notarization, appcast 관리, Sparkle 키 관리까지 직접 책임져야 합니다.
- 릴리즈 파이프라인을 새로 만들어야 합니다.

### B. TestFlight + App Store Connect

베타 채널로는 좋습니다.

장점:

- 내부/외부 테스터 배포가 쉬워집니다.
- macOS 앱도 TestFlight로 배포할 수 있습니다.
- 피드백 수집과 빌드 관리가 좋아집니다.

단점:

- 정식 제품 업데이트 엔진을 직접 통제하는 방식은 아닙니다.
- 외부 테스터에는 심사 흐름이 끼어듭니다.
- 지금 앱의 권한/동작 방식이 App Store 성격과 완전히 맞지는 않습니다.

참고:

- [TestFlight Overview - Apple Developer](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)
- [TestFlight - Apple Developer](https://developer.apple.com/testflight/)

### C. Mac App Store

지금 당장은 추천하지 않습니다.

이유:

- 현재 앱은 브라우저 쿠키/세션, CLI credential 파일, 시스템 Keychain, 보조 명령 실행 등을 다룹니다.
- 현재 entitlements도 [ClaudeUsage.entitlements](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/ClaudeUsage.entitlements)에 `com.apple.security.app-sandbox`가 켜져 있으면서 `/` 전체 경로 read-write 예외가 들어가 있습니다.
- 이런 형태는 App Store 심사와 장기 운영 관점에서 매우 불리합니다.

즉, App Store를 목표로 하려면 기능/권한/저장소 설계부터 다시 바뀌어야 합니다.

## 5. 채택 전략

### 채택 채널 구조

- 베타: `TestFlight`
- 정식: `Developer ID signed + notarized direct distribution`
- 자동 업데이트: `Sparkle`

이 구성이 가장 현실적입니다.

- 베타에서는 TestFlight로 설치/피드백/크래시 흐름을 정리
- 정식 사용자는 웹사이트 또는 GitHub Releases에서 첫 설치
- 이후 업데이트는 Sparkle appcast로 자동 처리

## 6. Sparkle 채택 이유

Sparkle 공식 문서 기준, 일반 앱 업데이트에는 appcast, EdDSA 서명, Apple code signing을 함께 쓰는 구성이 권장됩니다. 또한 notarized `DMG` 또는 `ZIP` 배포가 일반적입니다.

참고:

- [Sparkle Documentation](https://sparkle-project.org/documentation/)
- [Publishing an update - Sparkle](https://sparkle-project.org/documentation/publishing/)
- [Customizing Sparkle](https://sparkle-project.org/documentation/customization/)
- [Sandboxing with Sparkle](https://sparkle-project.org/documentation/sandboxing/)

### Sparkle를 붙이면 바뀌는 점

- 현재 `UpdateService`의 GitHub API polling을 appcast 기반으로 대체 가능
- 앱이 새 버전을 직접 다운로드하고 설치 준비 가능
- 설정에서 자동 확인, 자동 다운로드, 수동 확인을 더 자연스럽게 제공 가능
- 지인 공유용 direct download 앱에서도 App Store 없이 업데이트 경험을 정상화할 수 있음

### Sparkle 도입 시 주의점

- Sparkle는 단순 라이브러리 추가로 끝나지 않습니다.
- appcast 호스팅이 필요합니다.
- EdDSA 키를 안전하게 관리해야 합니다.
- 현재 앱이 sandbox를 유지한다면 Sparkle의 sandbox용 XPC/entitlement 설정이 추가로 필요합니다.

Sparkle 문서상 sandbox 앱은 `Installer.xpc`와 관련 entitlement가 필요합니다. 현재 앱은 이미 sandbox가 켜져 있어서, Sparkle 통합 시 entitlements 재설계가 필요합니다.

## 7. 지금 앱 기준 구현 방침

### 선택 1. Sandbox 유지 + Sparkle sandbox 설정 추가

장점:

- 현재 entitlement 방향을 유지할 수 있습니다.

단점:

- Sparkle 통합이 더 복잡합니다.
- 현재 entitlement 자체가 이미 정리되지 않아 그대로 이어가면 기술부채가 커질 수 있습니다.

### 선택 2. Direct distribution용으로 sandbox 재검토

장점:

- 파일 접근, 브라우저 세션/CLI credential 처리에 더 자연스럽습니다.
- App Store를 당장 목표로 하지 않는다면 구현이 더 단순할 수 있습니다.

단점:

- 보안 모델과 권한 범위를 명확히 다시 설계해야 합니다.

현재 판단으로는 `정식 direct distribution + Sparkle`을 목표로 할 때 sandbox를 그대로 유지할지 재검토가 필요합니다. 다만 바로 제거하기보다, 인증/자격증명 구조를 먼저 정리한 뒤 결정하는 편이 맞습니다.

## 8. 릴리즈 파이프라인 권장안

### Phase A. 수동 서명/노타리제이션 정착

1. Apple Developer 팀 연결
2. `Developer ID Application` 인증서 준비
3. Release archive 생성
4. Hardened Runtime 확인
5. `DMG` 또는 `ZIP` 산출물 생성
6. `notarytool`로 notarization
7. `stapler` 적용
8. 사용자 Mac에서 Gatekeeper 설치 테스트

이 단계의 목표는 “업데이트 자동화”가 아니라 “처음 설치 경험 정상화”입니다.

### Phase B. TestFlight 베타 채널 구축

1. App Store Connect 앱 레코드 준비
2. 내부 테스터 배포
3. 외부 테스터 필요 시 TestFlight 흐름 정리
4. 베타 빌드 설명/피드백 메일/테스트 포인트 정리

이 단계의 목표는 QA와 피드백 수집입니다.

### Phase C. Sparkle 자동업데이트 도입

1. Sparkle 통합
2. `SUFeedURL` 설정
3. appcast 생성 자동화
4. EdDSA 키 생성/보관
5. 릴리즈 산출물 서명 및 appcast 배포
6. 업데이트 UI를 Sparkle 기준으로 재구성
7. `자동 확인`, `자동 다운로드`, `수동 확인` 옵션을 설정에 연결
8. unsigned/debug build에서는 Sparkle 비활성화 정책 추가

### Phase D. 기존 GitHub 업데이트 로직 제거

1. [UpdateService.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Services/UpdateService.swift) 축소 또는 제거
2. 수동 “다운로드 열기” 버튼 제거 또는 “직접 다운로드” 보조 기능으로 격하
3. GitHub API 기반 최신버전 비교 로직 제거

## 9. 구현 권장안

### 우선 구현

- `Developer ID + notarization`
- 이후 `Sparkle`
- 필요 시 `TestFlight beta`

### 당장 하지 말 것

- App Store 제출을 목표로 entitlement를 억지로 맞추는 작업
- 기존 GitHub 업데이트 로직 위에 임시 자동 설치 스크립트를 덧대는 방식

후자는 빨리 보이지만 구조만 더 망가집니다.

## 10. 코드 기준 수정 포인트

### 현재 업데이트 관련 코드

- [UpdateService.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Services/UpdateService.swift)
- [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift#L1842)
- [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift#L106)

### 앞으로 필요할 것

- `AppUpdateCoordinator`
- `ReleaseChannel` 모델 (`beta`, `stable`)
- Sparkle updater wrapper
- build/notarize/release 스크립트
- appcast 배포 자동화

## 11. 확정 의사결정

지금 이 앱에서 가장 실용적인 방향은 아래이며, 이 방향으로 진행합니다.

1. 정식 배포는 `Developer ID + notarization + direct download`
2. 자동 업데이트는 `Sparkle`
3. 베타는 필요 시 `TestFlight`
4. App Store는 보류

이 순서가 맞는 이유는, 현재 앱의 인증/파일 접근 구조가 App Store 친화적이지 않기 때문입니다. App Store를 목표로 먼저 설계하면 배포는 깔끔해 보일 수 있지만, 실제 제품 기능을 크게 꺾을 가능성이 높습니다.

## 12. Sparkle 구현 메모

### 현재 코드 기준 배선 상태

- [Info.plist](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Info.plist)
  - `SUFeedURL`
  - `SUPublicEDKey`
- [UpdateService.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Services/UpdateService.swift)
  - 값이 비어 있거나 unresolved placeholder(`$(...)`)면 미설정으로 간주
  - 이 경우 Sparkle 대신 GitHub fallback 엔진 사용
- 예시 설정 파일
  - [Sparkle.release.example.xcconfig](/Users/seongmin/Personal/ClaudeUsage/Config/Sparkle.release.example.xcconfig)
- 점검 스크립트
  - [prepare-sparkle-release.sh](/Users/seongmin/Personal/ClaudeUsage/Scripts/prepare-sparkle-release.sh)
  - [build-notarize-release.sh](/Users/seongmin/Personal/ClaudeUsage/Scripts/build-notarize-release.sh)

### 실제 릴리즈 때 해야 할 것

1. 예시 파일을 복사해 실제 release 전용 xcconfig 생성
2. `SUFeedURL`, `SUPublicEDKey` 채우기
3. `NOTARY_PROFILE`을 준비한 뒤 [build-notarize-release.sh](/Users/seongmin/Personal/ClaudeUsage/Scripts/build-notarize-release.sh) 실행
4. Release configuration에 해당 xcconfig 연결
5. 서명/노타리제이션 이후 appcast 배포
6. 설정 화면에서 `appcast 준비`, `공개키 준비`가 모두 `준비됨`인지 확인

- `Sparkle`은 macOS 직접 배포 앱에서 널리 쓰이는 자동업데이트 프레임워크입니다.
- 인디 앱과 direct distribution 앱에서 사실상 표준에 가깝고, [CodexBar]( /Users/seongmin/Personal/CodexBar/Package.swift )도 실제로 사용 중입니다.
- 필요한 구성요소
- 앱 내 Sparkle 프레임워크 통합
- `SUFeedURL`
- `SUPublicEDKey`
- appcast.xml 호스팅
- 릴리즈 zip 또는 dmg와 appcast 서명 자동화
- 현실적인 호스팅
- GitHub Releases에 notarized zip 업로드
- appcast.xml은 GitHub raw 또는 별도 정적 호스팅

## 13. 다음 작업 제안

- 빌드/배포 파이프라인 문서 초안 작성
- Sparkle 도입 전제 조건 점검
- 현재 sandbox/entitlements 재검토
- GitHub Releases 기반 배포를 notarized artifact 기준으로 재설계
