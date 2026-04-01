# ClaudeUsage 구조/사용량 수집 검토 보고서

작성일: 2026-04-01

## 요약

현재 `ClaudeUsage`는 기능이 없는 앱은 아닙니다. 다만 구조가 이미 붕괴 단계입니다.

- UI, 메뉴바 상태, 설정 복원, 주기적 refresh, 인증 상태, Claude/Codex 표시 로직이 `AppDelegate` 하나에 과도하게 집중되어 있습니다.
- `Claude` 사용량 수집은 아이디어 자체보다 "전략 계층"이 부족합니다. 소스 선택, fallback, 상태 캐시, 상호작용 정책, profile metadata 관리가 한 덩어리로 섞여 있습니다.
- `Codex`를 추가하면서 추상화 계층 없이 기능을 옆으로 붙여 넣은 흔적이 많습니다.
- 결과적으로 지금 상태에서 기능을 더 얹으면 유지보수 비용이 급격히 증가합니다.

핵심 결론은 다음과 같습니다.

1. 구조는 `Claude-Usage-Tracker` 쪽 분해 방식을 가져오는 것이 가장 현실적입니다.
2. `Claude` 사용량 수집 전략은 `CodexBar`의 source planner/pipeline 개념을 가져오는 것이 맞습니다.
3. OAuth/organization/subscription metadata 캐시는 `claude-code`의 방식이 가장 성숙합니다.
4. 단순 파일 복붙이 아니라, "앱 구조", "provider 전략", "auth metadata"를 분리해서 이식해야 합니다.

## 1. 현재 `ClaudeUsage`의 문제 진단

### 1.1 거대 파일 집중

현재 핵심 파일 크기:

- `ClaudeUsage/App/AppDelegate.swift`: 2405 lines
- `ClaudeUsage/Views/PopoverView.swift`: 1256 lines
- `ClaudeUsage/Services/ClaudeAPIService.swift`: 1225 lines
- `ClaudeUsage/Models/AppSettings.swift`: 779 lines

이 수치는 단순히 "길다" 수준이 아닙니다. 역할 분해가 실패했다는 신호입니다.

### 1.2 `AppDelegate`가 사실상 애플리케이션 전체를 들고 있음

`ClaudeUsage/App/AppDelegate.swift`는 다음 역할을 동시에 수행합니다.

- 앱 시작/종료
- 메뉴바 status item 생성
- popover 제어
- settings window 제어
- Claude refresh
- Codex refresh
- timer 관리
- update check
- power state 관찰
- 설정 snapshot/restore
- UI state 동기화
- 아이콘 렌더링 조합

이 구조는 다음 문제가 있습니다.

- Claude/Codex별 상태 모델이 분리되지 않습니다.
- UI state와 네트워크 state가 강결합됩니다.
- 테스트 가능한 단위가 사실상 없습니다.
- 기능 추가 시 영향 범위를 예측하기 어렵습니다.

### 1.3 `ClaudeAPIService`가 너무 많은 책임을 가짐

`ClaudeUsage/Services/ClaudeAPIService.swift`는 현재 아래 역할을 모두 가집니다.

- session key 저장 상태 보유
- org ID 선택/캐시
- organization 목록 조회
- usage 조회
- overage 조회
- OAuth token 조회
- 시스템 keychain 탐색
- `security` 프로세스 직접 실행
- retry/backoff
- Cloudflare/429 분류
- auth path health telemetry

즉, transport/auth/cache/backoff/parsing/health가 분리되지 않았습니다.

서비스가 actor라는 점은 괜찮지만, actor 하나에 모든 책임이 들어가 있어 장점이 거의 상쇄됩니다.

### 1.4 설정 모델이 서비스 경계를 오염시킴

`ClaudeUsage/Models/AppSettings.swift`는 사실상 global mutable state입니다.

- Claude/Codex 설정이 한 타입에 모두 섞여 있음
- 메뉴바 렌더링 정책까지 저장 모델에 깊게 결합
- UI 상태와 실제 도메인 설정이 구분되지 않음
- profile/provider 단위 확장이 매우 불편함

이 구조에서는 provider가 늘어날수록 `didSet` 저장 키만 계속 복제됩니다.

## 2. `Claude-Usage-Tracker`에서 가져오기 좋은 구조

최신 `Claude-Usage-Tracker`는 현재 앱보다 훨씬 낫게 분해되어 있습니다.

참고 파일:

- `Claude Usage/Shared/Protocols/APIServiceProtocol.swift`
- `Claude Usage/MenuBar/UsageRefreshCoordinator.swift`
- `Claude Usage/Shared/Services/ProfileManager.swift`
- `Claude Usage/Shared/Services/ClaudeCodeSyncService.swift`
- `Claude Usage/Views/SettingsView.swift`

### 2.1 서비스 프로토콜 + coordinator 분리

`APIServiceProtocol`과 `UsageRefreshCoordinator` 구조는 현재 앱이 바로 가져오기 좋습니다.

좋은 점:

- refresh orchestration이 `AppDelegate`에서 분리됨
- usage/status/api usage 병렬 refresh 경로가 명확함
- delegate 경계가 있어 UI 업데이트 위치가 통제됨
- 테스트 더블 주입이 가능함

현재 앱은 최소한 아래로 분리해야 합니다.

- `ClaudeRefreshCoordinator`
- `CodexRefreshCoordinator`
- `MenuBarCoordinator`
- `PopoverCoordinator`

핵심은 "타이머와 refresh orchestration"을 `AppDelegate`에서 빼는 것입니다.

### 2.2 `ProfileManager` 중심 구조

`Claude-Usage-Tracker`는 완벽하지는 않아도, 적어도 profile을 1급 객체로 취급합니다.

좋은 점:

- active profile과 profiles 컬렉션이 분리됨
- profile switch 시 CLI credential 적용이 중앙화됨
- usage/history/notification/settings가 profile 경계 안에 존재함

현재 앱은 `Codex`와 `Claude`를 한 앱 안에 넣었지만, 실제로는 "multi-provider + multi-credential" 문제를 풀고 있습니다. 그런데 모델은 아직 single-app-global-state에 가깝습니다.

즉, 지금 필요한 건 단순한 multi-profile 기능 추가가 아니라:

- provider 독립성
- credential 독립성
- refresh 독립성
- menu representation 독립성

입니다.

### 2.3 스토리지 계층 분리

`Claude-Usage-Tracker`는 다음 계층을 분리합니다.

- `ProfileStore`
- `DataStore`
- `SharedDataStore`
- `UsageHistoryService`

현재 앱은 대부분 `AppSettings.shared` + `KeychainManager.shared` + 일부 runtime state에 기대고 있습니다.

이 구조는 아래 문제를 만듭니다.

- persisted state와 runtime state 경계 불명확
- settings migration이 어려움
- profile/provider 전환 시 데이터 스코프가 불명확
- usage history를 붙이기 어려움

현재 앱에도 최소한 아래 구조가 필요합니다.

- `SettingsStore`: UI/앱 설정
- `CredentialStore`: provider credential 저장
- `UsageSnapshotStore`: 마지막 usage snapshot 저장
- `HistoryStore`: reset/history 저장

### 2.4 Settings UI 분해

최신 `Claude-Usage-Tracker`의 `SettingsView`는 지나치게 화려한 면이 있지만, 구조 측면에서는 현재 앱보다 낫습니다.

현재 앱 문제:

- settings window 생성/복원/저장이 `AppDelegate`에 얽혀 있음
- 탭 상태, auth 상태, onSave/onCancel 후처리가 뒤섞임

가져올 점:

- section 기반 settings navigation
- profile 영역과 app 영역 분리
- settings 화면 자체가 자체 state owner가 되도록 구성

가져오지 말아야 할 점:

- 시각적 장식
- 지나치게 무거운 커스텀 window 코드

즉, 구조만 가져오고 외형은 절제하는 편이 낫습니다.

## 3. `CodexBar`에서 가져오기 좋은 구조

`CodexBar`는 현재 앱보다 한 단계 더 성숙한 구조를 갖고 있습니다. 이 저장소에서 가져와야 하는 것은 UI가 아니라 "provider 아키텍처"입니다.

핵심 파일:

- `CodexBar/Sources/CodexBarCore/Providers/ProviderDescriptor.swift`
- `CodexBar/Sources/CodexBarCore/Providers/ProviderFetchPlan.swift`
- `CodexBar/Sources/CodexBarCore/Providers/Claude/ClaudeProviderDescriptor.swift`
- `CodexBar/Sources/CodexBarCore/Providers/Claude/ClaudeSourcePlanner.swift`
- `CodexBar/Sources/CodexBarCore/Providers/Claude/ClaudeUsageFetcher.swift`
- `CodexBar/Sources/CodexBar/UsageStore+Refresh.swift`

### 3.1 Provider descriptor + fetch plan

현재 앱은 사실상 이미 provider app입니다. 그런데 provider abstraction이 없습니다.

`CodexBar`의 좋은 점:

- provider metadata 분리
- provider fetch plan 분리
- source mode 분리 (`auto`, `oauth`, `web`, `cli`, ...)
- strategy availability 판단 분리
- 실패 시 fallback 기준 분리

이 구조는 현재 앱에 매우 잘 맞습니다.

권장 구조:

- `ProviderID`: `claude`, `codex`
- `ProviderDescriptor`
- `ProviderFetchContext`
- `ProviderFetchStrategy`
- `ProviderFetchPipeline`
- `ProviderStore` 또는 `UsageStore`

현재 앱에서 `Claude`와 `Codex`를 같은 방식으로 다루려면 이 계층이 사실상 필수입니다.

### 3.2 Claude source planner

`CodexBar`의 `ClaudeSourcePlanner`는 매우 중요한 참고점입니다.

핵심 아이디어:

- 사용자가 명시적으로 source를 고르면 그 source만 사용
- auto일 때 runtime/app 상태에 따라 우선순위 계획 생성
- `hasOAuthCredentials`, `hasWebSession`, `hasCLI` 같은 availability를 먼저 평가
- 실제 fetch 이전에 plausible availability를 구분

현재 앱은 이 부분이 약합니다.

현재 앱의 상태:

- session key 경로
- OAuth 경로
- 일부 backoff/health snapshot

는 있지만, "선택된 source와 fallback 계획"이 타입으로 모델링되어 있지 않습니다.

결과:

- 로직 추론이 어렵고
- UI에 source 상태를 설명하기 어렵고
- 실패 원인을 사용자에게 일관되게 보여주기 어렵습니다

### 3.3 `UsageStore+Refresh`의 갱신 경계

`CodexBar`는 refresh 후 적용 단계가 비교적 명확합니다.

- fetch context 생성
- fetch pipeline 실행
- attempts 기록
- 성공 시 snapshot 적용
- 실패 시 gate를 통해 error 노출 여부 결정
- runtime hook 실행

현재 앱은 refresh 함수 내부에서:

- 로딩 상태 변경
- fetch
- 에러 분류
- UI 모델 업데이트
- 알림
- 메뉴바 갱신

이 한 번에 처리됩니다.

즉, 현재 앱은 "fetch state machine"이 없습니다.

이 부분은 거의 그대로 개념을 가져와도 됩니다.

### 3.4 Keychain prompt 정책/상호작용 컨텍스트

`CodexBar`가 현재 앱보다 확실히 앞서는 부분입니다.

- user-initiated vs background interaction 구분
- keychain prompt 허용 여부 분리
- startup bootstrap 예외 처리
- delegated refresh 허용/금지

현재 앱은 `security` 호출 timeout 정도는 있지만, "언제 시스템 prompt를 띄워도 되는가"에 대한 정책이 없습니다.

실제 사용자 경험 차이가 여기서 크게 납니다.

## 4. `Claude` 사용량 가져오는 방식 비교

이 부분은 단순히 어느 저장소가 최신이냐보다, 어떤 source 조합이 더 견고한지가 중요합니다.

### 4.1 현재 앱 `ClaudeUsage`

현재 앱은 두 경로를 모두 갖고 있습니다.

1. Web session key
   - `GET /api/organizations`
   - `GET /api/organizations/{org}/usage`
   - `GET /api/organizations/{org}/overage_spend_limit`
2. OAuth API
   - `GET https://api.anthropic.com/api/oauth/usage`

장점:

- 최신 `CodexBar`와 같은 방향으로 OAuth usage endpoint를 사용
- session key path와 OAuth path를 모두 보유
- 429/Cloudflare backoff가 어느 정도 구현됨
- organization cache와 auth health snapshot이 있음

문제:

- source 전략이 타입으로 분리되어 있지 않음
- OAuth metadata를 usage fetcher 내부에서 즉석으로 읽음
- token/profile/subscription/org metadata 캐시가 빈약함
- OAuth endpoint 실패 시 `Messages` 헤더 기반 fallback이 없음
- provider-level fetch attempts와 source label 기록이 없음

### 4.2 `Claude-Usage-Tracker`

최신 tracker는 OAuth usage endpoint를 직접 신뢰하지 않고, OAuth일 때 `POST /v1/messages` 최소 요청 후 rate-limit headers를 파싱합니다.

장점:

- endpoint availability 변화에 덜 민감할 수 있음
- rate-limit headers를 기반으로 session/weekly 상태를 직접 확보 가능
- `Messages` API가 살아 있는 동안 fallback로 유용함

한계:

- per-model window 세부값은 제한적
- usage body 기반 필드보다 정보량이 적음
- probe call 자체가 별도 API 호출 비용을 유발함
- 최신 `CodexBar`가 다시 `/api/oauth/usage`를 우선 쓰는 점을 보면, 이 방식이 최종형은 아님

즉, tracker의 방식은 "주 경로"보다 "fallback 경로"로 보는 것이 맞습니다.

### 4.3 `CodexBar`

최신 `CodexBar`는 Claude에서 다음 조합을 사용합니다.

- 1순위: OAuth API (`/api/oauth/usage`)
- 2순위: Web API (browser cookies 기반 `claude.ai/api`)
- 3순위: CLI/PTy probe
- 보조 경로: web extras로 account/extra usage 보강

이 구조가 현재 가장 균형이 좋습니다.

좋은 점:

- source planner가 명시적
- auto 모드와 explicit selection이 구분됨
- OAuth scope 검사 (`user:profile`)가 있음
- expired credential recovery가 따로 있음
- web extras를 본 usage source와 분리해서 덧씌움

현재 앱에 가장 필요한 것도 바로 이 구조입니다.

### 4.4 `claude-code` 실제 코드가 알려주는 더 좋은 방식

`claude-code`는 메뉴바 앱이 아니므로 직접 usage dashboard를 제공하지는 않습니다. 하지만 OAuth account/profile/rate-limit 처리는 이 저장소가 제일 성숙합니다.

핵심 파일:

- `src/services/oauth/client.ts`
- `src/services/claudeAiLimits.ts`
- `src/services/api/withRetry.ts`
- `src/services/rateLimitMessages.ts`

중요한 점:

1. OAuth refresh 후 profile fetch를 무조건 다시 때리지 않고, 필요한 필드가 이미 있으면 생략합니다.
2. `subscriptionType`, `rateLimitTier`, `hasExtraUsageEnabled`, `organizationUuid`를 전역 config에 캐시합니다.
3. 실사용 API 응답의 rate-limit headers를 해석해서 raw utilization을 유지합니다.
4. 429에서는 `Retry-After`뿐 아니라 unified reset timestamp도 활용합니다.
5. overage/weekly/session 상태 메시지를 중앙화합니다.

이 저장소에서 가져와야 할 것은 "UI"가 아니라:

- OAuth profile metadata 캐시 전략
- rate-limit header 해석 구조
- reset 시각 기반 backoff
- usage/limit 메시지 중앙화

입니다.

## 5. Claude 사용량 수집 재설계 권장안

현재 앱에서 가장 권장하는 방향은 아래와 같습니다.

### 5.1 Source 우선순위

기본 auto 모드:

1. OAuth API (`/api/oauth/usage`)
2. Web session API (`claude.ai/api/organizations/.../usage`)
3. OAuth `Messages` 최소 호출 + rate-limit headers fallback

CLI PTY probe는 현재 앱에서는 우선순위 밖으로 두는 편이 낫습니다.

이유:

- 메뉴바 앱이 굳이 PTY scrape까지 해야 할 정도는 아님
- 유지보수 비용이 큼
- 현재 목표는 "신뢰도 높은 usage fetch"이지 "CLI UI scrape 재현"이 아님

다만 debug/probe 도구로는 별도 유지 가치가 있습니다.

### 5.2 OAuth metadata 별도 계층화

지금처럼 `ClaudeAPIService` 내부에서 OAuth access token만 읽는 구조는 불완전합니다.

분리 권장:

- `ClaudeOAuthCredentialStore`
- `ClaudeOAuthProfileStore`
- `ClaudeOAuthUsageFetcher`
- `ClaudeWebUsageFetcher`

`ClaudeOAuthProfileStore`는 다음 필드를 캐시해야 합니다.

- access token expiry
- organization UUID
- subscription type
- rate limit tier
- has extra usage enabled
- billing type

이 캐시는 `claude-code`의 `fetchProfileInfo()` 설계와 유사하게 두는 것이 맞습니다.

### 5.3 Web session 경로는 "org-aware" source로 유지

Web session 경로의 장점은 organization을 직접 해석할 수 있다는 점입니다.

활용 방식:

- settings에서 org 선택
- web 경로로 org별 usage preview
- extra usage / overage endpoint 접근

즉, OAuth path가 기본이어도 web path는 버리면 안 됩니다.

### 5.4 Header fallback 추가

현재 앱은 OAuth usage endpoint 실패 시 그냥 실패하거나 session path로만 돌아섭니다.

추가 권장:

- `POST /v1/messages` minimal request fallback
- `anthropic-ratelimit-unified-5h-utilization`
- `anthropic-ratelimit-unified-5h-reset`
- `anthropic-ratelimit-unified-7d-utilization`
- `anthropic-ratelimit-unified-7d-reset`

이 fallback은 tracker에서 이미 실증되어 있고, `claude-code`도 header 기반 rate-limit 상태를 내부적으로 적극 활용합니다.

### 5.5 Backoff를 reset-aware하게 수정

현재 앱은 `Retry-After`와 자체 strike 기반 쿨다운은 있지만, `claude-code`처럼 unified reset header 중심으로 기다리지는 않습니다.

개선 권장:

- 429 응답에서 `anthropic-ratelimit-unified-reset` 읽기
- 있으면 reset 시각까지 대기
- 없으면 `Retry-After`
- 그것도 없으면 exponential backoff

이 순서가 더 합리적입니다.

## 6. 현재 앱에 실제로 가져와야 할 구조

### 6.1 바로 가져올 것

`Claude-Usage-Tracker`에서:

- coordinator 패턴
- API service protocol
- profile manager/store 분리
- usage history store/service
- settings section 분리

`CodexBar`에서:

- provider descriptor
- provider fetch context/result/attempt
- source planner
- fetch pipeline
- keychain prompt policy

`claude-code`에서:

- OAuth profile metadata 캐시
- rate-limit reset-aware backoff
- usage warning/error message 중앙화

### 6.2 가져오지 말 것

- `Claude-Usage-Tracker`의 과한 visual/window 커스텀
- `CodexBar`의 전체 multi-provider 범용성
- `CodexBar`의 CLI/PTy probe 복잡도
- `claude-code`의 거대한 전역 config 체계

현재 앱은 소규모 메뉴바 앱이므로, 필요한 패턴만 가져와야 합니다.

## 7. 권장 리팩터링 목표 구조

권장 디렉토리 구조:

```text
ClaudeUsage/
  App/
    AppDelegate.swift
    AppCoordinator.swift
  Domain/
    Providers/
      ProviderID.swift
      ProviderDescriptor.swift
      ProviderFetchContext.swift
      ProviderFetchResult.swift
      ProviderFetchPipeline.swift
    Claude/
      ClaudeUsageSource.swift
      ClaudeSourcePlanner.swift
      ClaudeUsageSnapshot.swift
    Codex/
      CodexUsageSnapshot.swift
  Services/
    Refresh/
      ClaudeRefreshCoordinator.swift
      CodexRefreshCoordinator.swift
    Claude/
      ClaudeOAuthCredentialStore.swift
      ClaudeOAuthProfileStore.swift
      ClaudeOAuthUsageFetcher.swift
      ClaudeWebUsageFetcher.swift
      ClaudeHeaderFallbackFetcher.swift
    Codex/
      CodexAuthStore.swift
      CodexUsageFetcher.swift
    Storage/
      SettingsStore.swift
      CredentialStore.swift
      UsageSnapshotStore.swift
      UsageHistoryStore.swift
  Features/
    MenuBar/
    Popover/
    Settings/
  UI/
    Components/
```

핵심은 다음 두 가지입니다.

- provider별 fetch 전략을 도메인으로 올릴 것
- AppKit/SwiftUI orchestration을 coordinator로 내릴 것

## 8. 단계별 개선 제안

### Phase 1. 구조 분해

- `AppDelegate`에서 refresh/timer/settings/popover/menu 조정 로직 분리
- `ClaudeAPIService`를 auth/fetch/cache/backoff/parser로 분리
- `AppSettings`를 provider 설정과 app 설정으로 분리

### Phase 2. Claude fetch 전략 재작성

- `ClaudeUsageSource` enum 도입
- `ClaudeSourcePlanner` 도입
- OAuth usage fetcher / web usage fetcher / header fallback fetcher 분리
- fetch attempt/source label/error 기록 추가

### Phase 3. Provider abstraction

- `ProviderDescriptor`
- `ProviderFetchPipeline`
- `ProviderStore`

이 단계까지 가면 `Codex`도 같은 골격 위에 정리할 수 있습니다.

### Phase 4. Profile/history/telemetry

- profile 단위 설정/credential/usage snapshot 저장
- usage history 저장
- warning/error 문구 중앙화
- reset-aware backoff 및 metadata cache 정착

## 9. 최종 판단

현재 앱은 "조금 부실한 수준"이 아니라, 구조상 이미 위험한 상태입니다.

좋은 소식은 코드 전체를 버릴 필요는 없다는 점입니다.

- 현재 앱의 Claude OAuth usage 직접 호출 방향은 유지 가치가 있습니다.
- 현재 앱의 session-key + OAuth dual path도 유지 가치가 있습니다.
- 그러나 이 둘을 담는 구조가 너무 약합니다.

따라서 가장 현실적인 전략은 다음입니다.

1. `Claude-Usage-Tracker`의 앱 구조를 가져와서 현재 앱의 giant object들을 해체
2. `CodexBar`의 provider/source planner 구조를 가져와 fetch 전략을 재조립
3. `claude-code`의 OAuth profile/rate-limit 처리 개념을 가져와 metadata/backoff를 보강

한 문장으로 요약하면:

> 현재 앱은 fetch 엔드포인트 선택보다 아키텍처가 더 문제이며, 구조는 tracker에서, 전략은 CodexBar에서, metadata 처리 철학은 claude-code에서 가져오는 것이 맞습니다.

## 10. 주요 근거 코드 위치

### 현재 앱

- `ClaudeUsage/App/AppDelegate.swift`
  - 앱 전체 orchestration 집중
- `ClaudeUsage/Services/ClaudeAPIService.swift`
  - `fetchUsage()`
  - `fetchUsageWithSessionKey()`
  - `fetchUsageViaOAuth()`
  - `readSystemOAuthAccessToken()`
- `ClaudeUsage/Models/AppSettings.swift`
  - 글로벌 설정 집합 및 snapshot/restore

### Claude-Usage-Tracker

- `Claude Usage/Shared/Protocols/APIServiceProtocol.swift`
  - service protocol 경계
- `Claude Usage/MenuBar/UsageRefreshCoordinator.swift`
  - refresh orchestration
- `Claude Usage/Shared/Services/ClaudeAPIService.swift`
  - `fetchUsageData()`
  - `parseUsageFromRateLimitHeaders()`
- `Claude Usage/Shared/Services/ClaudeCodeSyncService.swift`
  - CLI credential file/keychain fallback
- `Claude Usage/Shared/Services/ProfileManager.swift`
  - profile activation/switch 책임 집중

### CodexBar

- `CodexBar/Sources/CodexBarCore/Providers/Claude/ClaudeUsageFetcher.swift`
  - `StepExecutor.loadLatestUsage()`
  - `executeAuto()`
  - `loadViaOAuth()`
  - `loadViaWebAPI()`
- `CodexBar/Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthUsageFetcher.swift`
  - `/api/oauth/usage` 사용
- `CodexBar/Sources/CodexBarCore/Providers/Claude/ClaudeWeb/ClaudeWebAPIFetcher.swift`
  - browser cookie 기반 `claude.ai/api` 사용
- `CodexBar/Sources/CodexBarCore/Providers/Claude/ClaudeSourcePlanner.swift`
  - source planning
- `CodexBar/Sources/CodexBarCore/Providers/ProviderFetchPlan.swift`
  - strategy pipeline
- `CodexBar/Sources/CodexBar/UsageStore+Refresh.swift`
  - refresh 결과 적용 경계

### claude-code

- `src/services/oauth/client.ts`
  - OAuth refresh 이후 profile metadata 캐시
  - `fetchProfileInfo()`
  - `getOrganizationUUID()`
- `src/services/claudeAiLimits.ts`
  - unified rate-limit header 해석
- `src/services/api/withRetry.ts`
  - reset-aware retry/backoff
- `src/services/rateLimitMessages.ts`
  - 경고/제한 메시지 중앙화
