# Antigravity/AGY 사용량 조회 전면 개편 계획

- 상태: 역사적 구현 계획 (현재 동작의 source of truth 아님)
- 작성일: 2026-07-26
- 최종 갱신: 2026-07-29
- 기준 브랜치: `dev`
- 계획 기준 commit: `1fc02fafe6ab29f565d61cecd47db7361f4e340b` (작업 시작 당시 `main`/`dev` 공통 기준)

이 문서는 전면 개편 당시의 결정과 실행 순서를 보존하는 역사적 계획입니다.
2026-07-29 이후 현재 자동 조회 정책, AGY 신뢰 경계와 설정 UX의 source of
truth는 `docs/antigravity-usage-sources.md`와 실제 코드입니다. 특히 아래의
`sourcePolicy`/managed CLI opt-in 설계는 schema v2에서 제거됐습니다.

## 1. 목표와 완료 정의

### 1.1 목표

- 최신 AGY가 반환하는 `그룹 × 시간 구간` quota를 손실 없이 표현합니다.
- TUI 문자열이 아니라 구조화된 localhost RPC를 기본 데이터 경로로 사용합니다.
- 실행 중인 Antigravity 앱, 외부 AGY, ClaudeUsage가 시작한 AGY, Google OAuth를 서로 구분하고 실제 계정과 source provenance를 검증합니다.
- account selection, token refresh, usage refresh를 하나의 취소 가능한 transaction으로 통합합니다.
- OAuth credential의 중복 저장을 없애고 앱이 소유한 저장소와 vault에만 보관합니다.
- 기존 사용자는 업데이트만으로 계정과 의미 있는 환경 설정을 유지합니다.
- migration 완료 후 구 credential 파일, legacy Keychain 항목, 구 model 설정과 제거된 Gemini 설정이 남지 않습니다.
- 표준 popover, compact popover, 메뉴바, 설정, 알림을 동일한 quota lane 의미로 맞춥니다.

### 1.2 완료 정의

다음 조건을 모두 만족해야 완료입니다.

1. 현재 로컬 AGY 1.1.7에서 관찰된 네 lane이 정확히 표시되고, 요금제·조직·향후 버전에 따른 lane 누락과 추가도 정상 상태로 처리됩니다.
2. 기존 `Model Quota`/`Models & Quota` TUI parser와 PTY 기반 quota 수집 코드가 제품 경로에서 제거됩니다.
3. 선택 OAuth account가 조회 대상인 `자동`/`Google 계정`에서는 다른 local/CLI account의 수치가 화면, 메뉴바, 알림 어디에도 적용되지 않습니다. 사용자가 명시한 `로컬 세션`은 ambient local account를 별도 provenance로 표시합니다.
4. 계정 A 조회 중 B로 전환해도 늦은 A 응답이나 token refresh가 B 상태를 되돌리지 못합니다.
5. 업그레이드 후 credential secret은 app-owned Keychain vault에만 있고, 파일에는 계정 metadata만 남습니다.
6. migration이 성공한 사용자에게 `oauth_creds.json`, `oauth_accounts.json`, `oauth_metadata.json`, 두 legacy service의 Antigravity Keychain item이 남지 않습니다.
7. 모든 Google 계정을 연결 해제하면 app-owned vault item, metadata file, migration journal, 빈 Antigravity 디렉터리가 남지 않습니다. 재실행해도 계정이 되살아나지 않습니다.
8. 표준 popover는 전체 quota 구조를, compact와 메뉴바는 가장 제약이 큰 metric 하나를 기본으로 보여줍니다.
9. 수동 새로고침은 last-good 값을 유지하고, 계정 또는 source 경계 변경만 이전 값을 즉시 지웁니다.
10. 전체 XCTest, Release unsigned build, signed upgrade QA, VoiceOver·keyboard·light/dark UI QA와 최종 코드 리뷰를 통과합니다.

## 2. 조사 결과

### 2.1 Git과 레퍼런스 상태

- 작업 시작 전에 `origin`을 `fetch --prune`했습니다.
- `main`, `origin/main`, `dev`, `origin/dev`는 모두 `1fc02fafe6ab29f565d61cecd47db7361f4e340b`였고 worktree는 clean이었습니다. 별도 merge나 reset은 필요하지 않았습니다.
- `/Users/seongmin/Personal/reference` 아래 13개 reference repository를 각각 `fetch --prune`한 뒤 remote default branch로 강제 정렬했습니다. reference 폴더에는 로컬 작업을 보존하지 않는다는 운영 기준을 적용했습니다.
- 직접 참고한 최신 head는 다음과 같습니다.

| Reference | Branch | Head | 사용한 근거 |
|---|---|---:|---|
| CodexBar | `main` | `cc8da27c` | structured quota decoder, process discovery, managed AGY lifecycle, selected-account guard |
| orca | `main` | `e1f0e768` | Antigravity 값을 별도 source로 조회하지 않고 Gemini snapshot으로 투영하는 경계 확인 |
| ccusage | `main` | `409b4a5` | Antigravity의 정확한 historical token accounting은 지원 source가 아님을 확인 |
| claude-code-source | `main` | `4ea31c1` | CLI·인증 source 탐색 참고 |

Reference 코드는 그대로 복사하지 않습니다. process lifecycle과 decoder의 검증 포인트는 참고하되 ClaudeUsage의 책임 경계와 UX에 맞게 더 작은 구성 요소로 재설계합니다.

### 2.2 공식 AGY 계약

2026-07-26 기준 공식 문서와 실제 실행 결과는 다음과 같습니다.

- 공식 [`/usage` 문서](https://antigravity.google/docs/cli/commands/usage)는 `/usage` 또는 `/quota`가 backend를 갱신한 뒤 interactive TUI를 연다고 설명합니다. machine-readable JSON subcommand는 제공하지 않습니다.
- 공식 [`/credits` 문서](https://antigravity.google/docs/cli/commands/credits)는 credit balance와 소비 내역을 quota와 별도 panel로 정의합니다. credits를 quota percentage와 합치면 안 됩니다.
- 공식 [troubleshooting 문서](https://antigravity.google/docs/cli/troubleshooting)는 `AGY_CLI_DISABLE_AUTO_UPDATE=true`로 auto-update를 끌 수 있다고 명시합니다.
- 조사 시작 시 로컬 `agy`는 1.1.6이었지만 임시 실행 과정에서 자체 업데이트되어 1.1.7이 됐습니다. 현재 로컬 설치본과 공식 문서·repository main은 1.1.7 기준이지만 조사 당시 GitHub Releases 화면은 1.1.6으로 뒤처져 있었습니다. 이를 `최신 정식 release tag`라고 단정하지 않습니다. ClaudeUsage가 관리하는 AGY process에는 반드시 위 환경 변수를 주입해야 합니다.
- 실제 1.1.7 `/usage` TUI 제목은 `Models & Quota`이며, 현행 parser가 기다리는 `Model Quota`와 다릅니다.
- 이번 조사에서 실행한 opt-in integration test는 약 20.8초 후 `parseError`로 실패했습니다. 이 결과는 아직 repository fixture로 보존되지 않았으므로 구현 1단계에서 재실행 로그와 sanitised fixture를 고정해야 합니다. 다만 현행 parser의 literal과 현재 TUI title이 불일치한다는 코드상 결함만으로도 문자열 보수 방식은 승인하지 않습니다.
- 이번 조사에서 AGY 1.1.7 language server의 `RetrieveUserQuotaSummary` 응답은 `response.groups` 아래 quota bucket을 반환했습니다. 아직 repository에 증거 fixture가 없으므로 아래는 현재 계정에서 관찰한 형태이며 전체 요금제의 불변 계약이 아닙니다.

| Group | Bucket ID | Window |
|---|---|---|
| Gemini Models | `gemini-5h` | `5h` |
| Gemini Models | `gemini-weekly` | `weekly` |
| Claude and GPT models | `3p-5h` | `5h` |
| Claude and GPT models | `3p-weekly` | `weekly` |

관찰한 bucket에는 `remainingFraction`, `resetTime`, `window`가 있었습니다. `window`를 cadence의 우선 근거로 사용하되 undocumented field로 취급합니다. `remainingFraction`은 UI 직전까지 소수 정밀도를 보존해야 합니다. 계정 이메일, token, 실제 비율 값은 fixture와 로그에서 제거합니다.

### 2.3 구조화 RPC의 안정성 경계

`RetrieveUserQuotaSummary`는 실제 AGY가 사용하는 구조화 endpoint지만 공개된 안정 API 계약은 아닙니다. 따라서 다음 방어선이 필요합니다.

- live에서 확인한 `response` wrapper 외에 response root와 `summary` wrapper도 방어적으로 허용합니다. 후자의 두 형태는 CodexBar reference decoder가 지원하는 호환 형태이지 이번 live 응답에서 관찰한 형태는 아닙니다.
- live에서 확인한 direct `remainingFraction` 외에 oneof nested 값을 방어적으로 처리합니다. nested 형태 역시 reference 호환 방어선이며 live 실측 계약으로 기록하지 않습니다.
- cadence는 `window`를 우선하고, 구 payload에 한해 bucket ID/display name heuristic을 fallback으로 사용합니다.
- unknown group, unknown cadence, disabled bucket, reset 누락을 버리지 않습니다.
- schema가 바뀌면 가짜 `0%`를 만들지 않고 typed incompatibility로 실패합니다.
- decoder fixture는 sanitised raw payload에서 만들어 upstream 변화가 test diff로 드러나게 합니다.

### 2.4 현행 코드의 구조적 결함

현행 구현은 최신 quota 의미와 맞지 않습니다.

#### Domain

- `AntigravityUsageWindow`는 model ID, model family, primary/secondary/tertiary를 전제로 합니다.
- 최신 데이터는 model 세 개가 아니라 두 scope와 두 cadence의 조합입니다.
- group/cadence를 model 문자열에 억지로 넣으면 reset 표시, compact filtering, 메뉴바 선택, 알림 tracker가 계속 예외 처리에 의존합니다.

#### CLI 수집

- `AntigravityCLIUsageService`가 binary 탐색, PTY lifecycle, prompt 처리, TUI navigation, text parsing을 한 타입에서 수행합니다.
- `Model Quota` literal과 모델명 행을 기다리므로 1.1.7에서 실패합니다.
- timeout/cancellation이 child process tree 전체에 전달되지 않고, 외부 process와 app-owned process의 종료 권한도 분리되지 않았습니다.
- AGY 실행 자체가 auto-update를 일으킬 수 있는데 이를 막지 않습니다.

#### Local API

- `AntigravityAPIService`가 process 검색, `lsof`, port discovery, TLS trust, CSRF, retry, cache를 모두 소유합니다.
- 최신 `RetrieveUserQuotaSummary`가 없고 구 `GetUserStatus`/`GetCommandModelConfigs`를 model quota로 변환합니다.
- `AntigravityStatusProbe`와 `ProviderEnvironmentDetector`도 별도 process/cache 상태를 가져 동일 환경을 서로 다르게 판정할 수 있습니다.

#### Refresh와 account provenance

- runtime은 persisted source setting과 무관하게 `.auto`를 하드코딩합니다.
- 마지막 성공 source를 우선해 한 번 CLI가 성공하면 background에서 CLI 실행이 반복될 수 있습니다.
- refresh task cancellation, monotonic generation, single-flight, response account 검증이 없습니다.
- remote source가 token refresh 후 storage를 직접 `makeActive: true`로 갱신합니다. A 조회 중 B로 바꾸면 늦은 A refresh가 active account를 다시 A로 돌릴 수 있습니다.

#### Credential 저장과 migration

- `oauth_accounts.json`에 모든 credential이 있고 `oauth_creds.json`에 active credential이 다시 저장됩니다.
- 두 파일을 비트랜잭션으로 순차 수정하므로 crash나 동시 요청에서 서로 어긋날 수 있습니다.
- 실제 사용자 환경에도 두 파일이 모두 존재했습니다. 내용은 읽거나 출력하지 않고 mode와 존재만 확인했습니다.
- legacy Keychain migration은 durable version 없이 앱 실행마다 재시도할 수 있고, legacy delete 실패를 `try?`로 숨겨 stale credential이 재유입될 수 있습니다.
- 손상된 account file을 빈 상태로 취급할 수 있어 migration이 유효 credential을 덮어쓸 위험이 있습니다.

#### UI와 설정

- 모든 Antigravity model row가 `.primary`라 compact에도 전부 노출됩니다.
- model visibility는 standard/compact가 실제로 분리되지 않고, `antigravityModels`는 숨김 설정과 무관하게 강제로 되살아납니다.
- weekly lane도 `isWeekly = false`로 투영될 수 있습니다.
- compact header와 standard status rail의 account lookup은 Claude account 모델을 사용해 Antigravity provenance가 누락됩니다.
- 메뉴바의 generic `fiveHour/weekly` 슬롯을 Antigravity에서는 primary/secondary model로 재사용해 label과 reset 의미가 뒤섞입니다.
- 값이 없을 때 `0`으로 대체해 unknown을 실제 0%처럼 표시할 수 있습니다.
- 설정의 일반 새로고침도 configuration-change 경로를 타서 last-good payload를 지우고 화면이 깜빡입니다.
- 알림은 세 model slot에 고정되어 현재 관찰된 네 lane과 향후 동적 lane을 정확히 추적할 수 없습니다.

### 2.5 현재 사용자 데이터와 잔여 설정

조사 시 다음 ClaudeUsage-owned 데이터가 존재했습니다. secret 값은 열람하거나 출력하지 않았습니다.

- `~/Library/Application Support/ClaudeUsage/Antigravity/oauth_accounts.json`
- `~/Library/Application Support/ClaudeUsage/Antigravity/oauth_creds.json`
- `antigravityUsageDataSource=auto`
- `antigravityHiddenModelIDs`
- popover의 `antigravityModels` 항목
- model 선택과 menu bar slot 관련 Antigravity UserDefaults
- 이미 제거된 Gemini provider의 도달 불가능한 UserDefaults 12개

즉 migration은 가상 호환 문제가 아니라 현재 설치본의 중복 secret과 잔여 설정을 실제로 정리해야 합니다.

### 2.6 Codex/OpenAI 아이콘 appearance 감사

사용자 제보에 따라 AGY 개편과 함께 쓰이는 공통 provider icon 경로도 확인했습니다.

- source의 `ProviderCodexIcon.imageset`에는 light용 검정 `codex.png`/`@2x`와 Dark Aqua용 흰색 `codex-dark.png`/`@2x`가 모두 있습니다.
- 현재 `/Applications/ClaudeUsage.app`의 `Assets.car`에도 `ProviderCodexIcon` light/dark 1x/2x rendition 네 개가 포함되어 있습니다.
- 설치 app asset을 Aqua와 Dark Aqua appearance로 직접 렌더링한 결과 서로 다른 검정/흰색 이미지가 선택됐습니다. 따라서 asset 누락은 아닙니다.
- popover와 settings sidebar의 appearance-aware named `NSImage` 및 cached copy는 direct rendering에서 variant를 유지했습니다.
- 메뉴바는 status button의 `effectiveAppearance` 변화를 관찰해 다시 그리지만 icon factory에 그 appearance를 전달하지 않은 채 named asset을 bitmap으로 평탄화합니다. 메뉴바와 앱 appearance가 다른 환경의 variant는 보장되지 않습니다.
- canonical asset script는 light PNG만 생성하고 dark PNG와 `Contents.json` luminosity mapping을 생성·검증하지 않습니다. script 재실행 시 dark variant가 stale 또는 누락될 수 있습니다.
- settings sidebar는 브랜드 icon을 쓰지만 Codex 본문 header는 `bubble.left.and.bubble.right` SF Symbol을 사용합니다.
- light/dark asset, menu bar flattening, settings header에 대한 regression test가 없습니다.

[LobeHub OpenAI icon reference](https://lobehub.com/ko/icons/openai)와 공식 [Lobe Icons repository](https://github.com/lobehub/lobe-icons)는 static PNG/WebP를 `light/openai`와 `dark/openai`로 분리해 제공합니다. 결론은 `두 asset이 존재한다`까지는 현재 충족하지만, `모든 surface가 재실행 없이 올바른 variant로 갱신된다`는 보장은 아직 부족하다는 것입니다.

## 3. 확정 설계 원칙

1. **TUI는 UI이지 API가 아닙니다.** quota 숫자 수집에 사용하지 않습니다.
2. **quota 의미는 domain에서 먼저 고정합니다.** view나 parser가 primary/secondary를 임의로 만들지 않습니다.
3. **source와 account를 숫자와 함께 운반합니다.** identity를 검증할 수 없는 결과는 선택 계정 아래에 적용하지 않습니다.
4. **client는 persistence를 하지 않습니다.** token write와 active selection은 account repository와 refresh coordinator만 수행합니다.
5. **borrowed process는 종료하지 않습니다.** ClaudeUsage가 생성한 process만 lifecycle manager가 종료할 수 있습니다.
6. **automatic managed launch는 검증된 AGY로 제한합니다.** 2026-07-29
   변경으로 실행 중 source가 quota를 주지 못하면 Google 서명을 검증한 AGY를
   자동 실행합니다. ClaudeUsage가 시작한 process tree만 idle timeout 뒤
   정리합니다.
7. **migration은 copy → verify → cutover → cleanup 순서입니다.** 검증 전 legacy를 삭제하지 않고, cutover 후에는 legacy를 다시 import하지 않습니다.
8. **unknown은 0이 아닙니다.** 누락·비활성·schema mismatch를 숫자로 위장하지 않습니다.
9. **compact는 전체 표가 아닙니다.** 핵심 제약 한 개를 전달하고 전체는 standard view에서 봅니다.
10. **구 설정을 억지로 매핑하지 않습니다.** 의미가 사라진 model 선택은 새 안전 기본값으로 초기화하고 그 사실을 한 번 안내합니다.

## 4. 새 domain contract

### 4.1 Usage snapshot

```swift
struct AntigravityQuotaSnapshot: Sendable, Equatable {
    let identity: ProviderAccountIdentity?
    let plan: String?
    let lanes: [AntigravityQuotaLane]
    let decodeIssues: [AntigravityQuotaDecodeIssue]
    let provenance: AntigravityQuotaProvenance
    let fetchedAt: Date
}

struct AntigravityQuotaLane: Sendable, Equatable, Identifiable {
    let id: AntigravityQuotaLaneID
    let upstreamGroupID: String?
    let upstreamBucketID: String
    let scope: AntigravityQuotaScope
    let cadence: AntigravityQuotaCadence
    let remainingFraction: Double?
    let resetAt: Date?
    let resetDescription: String?
    let availability: AntigravityQuotaAvailability
}
```

원칙:

- known stable ID는 `gemini.fiveHour`, `gemini.weekly`, `thirdParty.fiveHour`, `thirdParty.weekly`입니다.
- unknown lane은 array index가 아니라 upstream group/bucket identity에서 안정 ID를 만듭니다.
- `scope`는 `.gemini`, `.thirdPartyModels`, `.unknown(id:label:)`을 가집니다.
- `cadence`는 `.fiveHour`, `.weekly`, `.unknown(rawValue:)`을 가집니다.
- `availability`는 `.available`, `.disabled`, `.unknown`을 분리합니다.
- source의 `remainingFraction`을 domain에 그대로 저장하고 `usedPercent` 변환과 반올림은 presentation mapper 한 곳에서만 합니다.
- response에 식별 가능한 bucket이 있지만 일부 field를 읽지 못한 경우 유효 lane은 보존하고 `decodeIssues`에 bucket과 원인을 남깁니다. 현재 계정에서 관찰된 네 lane을 모든 계정의 필수 목록으로 합성하지 않습니다.
- primary/secondary/tertiary와 `AntigravityModelFamily`는 새 계약에서 제거합니다.

### 4.2 Provenance

```swift
struct AntigravityQuotaProvenance: Sendable, Equatable {
    let transport: Transport
    let endpointOwner: EndpointOwner
    let accountIdentity: ProviderAccountIdentity?
    let capability: Capability
    let processIdentity: ProcessIdentity?
}
```

- `transport`: local app RPC, borrowed AGY RPC, managed AGY RPC, Google OAuth.
- `endpointOwner`: external/borrowed와 ClaudeUsage/owned를 구분합니다.
- `capability`: grouped quota summary인지 제한된 legacy source인지 표시합니다.
- 계정 이메일은 UI에서 마스킹 가능하지만 내부 비교는 stable account ID를 우선합니다.
- provenance는 diagnostics에만 붙는 부가 문자열이 아니라 snapshot 적용 여부를 결정하는 필수 값입니다.

### 4.3 Credits와 historical usage

- `/credits`는 별도 `AntigravityCreditSnapshot` 영역으로 분리합니다.
- 이번 quota 개편에서 live structured credits source가 검증되지 않으면 UI를 만들지 않습니다.
- model quota나 token history를 credit balance로 추정하지 않습니다.
- ccusage가 제공하지 않는 Antigravity historical token accounting을 quota와 혼합하지 않습니다.

## 5. 책임 분리 아키텍처

| Component | 단일 책임 | 하지 않는 일 |
|---|---|---|
| `AntigravityRuntimeDiscovery` | app/AGY binary와 process, port ownership, 실행·인증 가능 상태 발견 | HTTP 요청, quota decoding, UI 상태 결정 |
| `AntigravityLocalRPCTransport` | 검증된 loopback endpoint에 request, TLS/CSRF/header/deadline 처리 | process 탐색, source 우선순위, persistence |
| `AntigravityQuotaSummaryDecoder` | raw JSON을 group/cadence lane으로 decode | network, account 선택, UI 반올림 |
| `AntigravityIdentityDecoder` | user status에서 account identity/plan 추출 | quota 의미 추정 |
| `AntigravityManagedCLISession` | owned AGY 시작, readiness, lease, cancellation, idle teardown, process-tree cleanup | quota parsing, borrowed process 종료 |
| `AntigravityUsageSource` 구현체 | 한 source에서 snapshot과 optional refreshed credential 반환 | credential 저장, active account 변경 |
| `AntigravityRefreshCoordinator` | source policy, single-flight, generation, account match, CAS token save, last-good state | SwiftUI rendering, process 세부 구현 |
| `AntigravityAccountRepository` | active account와 revision, journal 기반 metadata/vault recoverable mutation | HTTP refresh, source 선택 |
| `AntigravityMigrationCoordinator` | legacy import, 검증, cutover, cleanup/retry | 정상 runtime refresh |
| `AntigravityConnectionSettings` | versioned source policy와 managed CLI 허용 여부 저장 | active account, quota 표시 설정 |
| `AntigravityQuotaPresentationMapper` | standard/compact/menu bar/notification projection | RPC, persistence |
| `AntigravitySettingsViewModel` | typed state와 사용자 action transaction | AppDelegate 직접 호출, raw OAuth 저장 |

`AppDelegate`는 schedule trigger와 최종 app state 연결만 담당합니다. source별 분기, token write, process probing을 보유하지 않습니다.

## 6. Runtime discovery와 structured RPC

### 6.1 Discovery

- Antigravity 앱 language server, 외부 AGY, managed AGY를 서로 다른 candidate로 반환합니다.
- 동일 UID, exact executable realpath, PID start time, listening port ownership을 확인합니다.
- `/bin/ps`의 command line은 candidate hint와 port/CSRF hint에만 사용합니다. process identity는 libproc의 BSD info와 executable path를 전후로 다시 읽어 PID reuse와 실행 이미지 교체를 거부합니다.
- `lsof -F0pfnPT`는 NUL field로 파싱하고 exact `127.0.0.1` LISTEN endpoint만 승격합니다. wildcard, non-loopback, requested port 미소유, hint 없는 복수 port는 거부합니다.
- 모든 `lsof` port를 무차별 probe하지 않습니다.
- PID만 저장하지 않고 PID reuse를 막을 start epoch와 executable identity를 함께 기록합니다.
- cache와 in-flight discovery는 한 actor가 소유합니다. `StatusProbe`와 `ProviderEnvironmentDetector`의 중복 AGY cache는 제거합니다.
- positive cache도 process와 port ownership을 다시 검증한 뒤에만 사용하고, security revalidation 실패에는 stale-while-revalidate를 적용하지 않습니다. concurrent waiter는 한 discovery를 공유하며 한 waiter 취소가 다른 waiter의 작업을 취소하지 않습니다.
- cancellation과 timeout에서 종료할 수 있는 대상은 ClaudeUsage가 직접 시작한 `ps`/`lsof` helper뿐입니다. 발견한 Antigravity 앱이나 borrowed AGY에는 signal을 보내지 않습니다.
- 상태는 `installed`, `running`, `authenticationRequired`, `queryable`을 각각 표현합니다. 설치됨을 조회 가능으로 간주하지 않습니다.

### 6.2 Local RPC

호출 순서:

1. `RetrieveUserQuotaSummary`
2. 최대 1초의 account identity best-effort 조회
3. 제한된 legacy capability 확인

보안 조건:

- RPC method는 `RetrieveUserQuotaSummary`, `GetUserStatus`, `GetCommandModelConfigs` 세 개만 허용하며 arbitrary path/body를 받지 않습니다. quota body는 `{"forceRefresh":true}`로 고정합니다.
- exact `https://127.0.0.1:<verified-port>`이고 discovery가 특정 PID, UID, start time, executable의 소유로 확인한 endpoint만 신뢰합니다.
- self-signed certificate 예외는 해당 검증된 loopback connection에만 적용합니다. connect 전, TLS challenge, response 후에 process와 host/port ownership을 다시 확인하고 한 transaction 안에서 leaf certificate SHA-256을 pin합니다.
- Antigravity 앱 endpoint에 필요한 CSRF와 AGY CLI endpoint의 tokenless policy를 분리합니다.
- 한 fetch는 cookie/cache/credential/proxy를 비활성화한 ephemeral session 하나만 사용하고 quota와 identity 요청 뒤 즉시 폐기합니다. redirect는 거부하고 response는 2 MiB로 제한합니다.
- request/response body, token, cookie, CSRF 값, 이메일 원문을 로그에 남기지 않습니다.
- 전체 deadline과 단계별 deadline을 분리하고 cancellation을 즉시 전달합니다.

legacy endpoint가 model별 quota만 반환하면 이를 group × cadence lane으로 추정하지 않습니다. structured summary를 지원하지 않는 버전은 `limitedCapability`로 분류해 업데이트 또는 다른 source CTA를 보여줍니다.

legacy capability 확인은 quota method의 404/405/501, Connect `unimplemented`, 또는 error envelope 검사가 끝난 정상 JSON의 groups 부재/식별 가능한 lane 부재에만 허용합니다. 인증 실패, 429, 5xx, TLS·ownership 실패, cancellation·deadline, malformed JSON에서는 legacy로 fallback하지 않습니다.

Google OAuth source도 공개 안정 API가 아니라 `cloudcode-pa.googleapis.com` 계열 비공개 endpoint에 의존합니다. local quota summary와 동일한 의미라고 가정하지 않습니다. sanitised live fixture로 group/cadence 의미가 확인된 payload만 lane으로 decode하고, model quota만 반환하는 경우에는 `limitedCapability`로 표시해 현재 알려진 네 lane을 추론 생성하지 않습니다.

### 6.3 Managed AGY policy

- 기본 `automatic`은 ClaudeUsage의 제품·보안 정책으로 AGY를 새로 실행하지 않습니다. 이는 공식 AGY 동작 계약이 아닙니다.
- 실행 중인 동일 계정 local app/AGY가 없으면 선택된 Google OAuth로 fallback합니다.
- 사용자가 고급 설정에서 `필요할 때 AGY CLI 시작`을 명시적으로 켠 경우에만 managed AGY를 시작합니다.
- owned process environment에 `AGY_CLI_DISABLE_AUTO_UPDATE=true`를 강제합니다.
- project trust, login, browser auth prompt를 자동 승인하지 않습니다.
- 한 process를 concurrent 요청이 공유하는 actor lease로 관리하고 기본 idle timeout은 180초로 시작합니다. 180초는 CodexBar reference에서 가져온 조정 가능한 초기값이며 공식 AGY 기준이 아닙니다.
- in-flight request가 있으면 idle teardown하지 않습니다.
- cancellation/timeout/app termination에서 아래 bounded guarantee 안의 child process tree를 정리합니다.
- borrowed process는 절대로 signal/terminate하지 않습니다.
- crash 뒤 남은 owned process record는 PID, UID, start time, executable과 XNU kernel process identity를 재검증한 후에만 정리합니다.

### 6.4 Managed process cleanup의 bounded guarantee

Managed AGY cleanup은 `모든 미래 descendant를 무조건 찾아 종료한다`는 보장이 아닙니다. 현재 구현이 제공하는 보장 범위는 다음과 같습니다.

- launch transaction은 v2 ledger의 durable launch intent를 임시 파일 `fsync` → same-directory `renameat` → directory `fsync` → read-back 순서로 검증한 뒤에만 `POSIX_SPAWN_START_SUSPENDED`를 호출합니다. suspended child의 PGID, UID, executable, `parentUniqueID`를 확인하고 intent를 process record로 원자 승격한 뒤 cancellation/deadline을 다시 검사해야만 `SIGCONT`로 user code를 시작합니다. intent 또는 promotion commit 결과가 불확실하면 spawn하거나 resume하지 않습니다.
- owner crash가 intent 저장 뒤 spawn 전에 발생하면 exact owner 부재와 candidate 0개를 증명한 뒤 intent를 제거합니다. suspended spawn 뒤 promotion 전에 발생하면 exact lineage·UID·path·PGID가 일치하는 candidate가 정확히 1개일 때만 record로 승격해 recovery합니다. promotion 뒤에는 resume 여부와 무관하게 durable record가 종료 권한이며, PID/recency/basename 추정으로 candidate를 고르지 않습니다.
- resume 직후, readiness 대기 중 주기적으로, readiness 직후, 실행 중 기본 1초마다, 마지막 lease 경계에서 process tree를 관찰합니다. 관찰된 descendant는 최대 64개까지 durable record에 병합합니다. 이 한도를 넘거나 scan이 불완전하면 상태를 sticky `incomplete`로 내리고 이후 성공 scan 하나만으로 다시 `complete`로 승격하지 않습니다.
- 정상 shutdown에서는 unreaped root가 원래 process group ID의 재사용을 막는 동안 group과 root PID 양쪽에 `TERM → grace period → KILL`을 전달합니다. root가 실행 후 다른 PGID로 이동해도 unreaped child PID는 재사용되지 않으므로 root에 직접 signal하고, 원래 group에도 별도 signal해 남은 group child를 정리합니다. 동시에 immutable `parentUniqueID`로 관찰한 `setsid`/reparent descendant를 record에 먼저 합친 뒤 각 exact execution에 `TERM/KILL`을 보냅니다.
- crash recovery에서는 process-group ID를 signal authority로 사용하지 않습니다. 현재 boot의 durable root와 observed descendant를 exact identity로 다시 확인하고, kernel ancestry로 재발견한 descendant를 record에 먼저 합친 뒤에만 각 execution에 `TERM/KILL`을 보냅니다. `kern.bootsessionuuid`만 durable signal 권한의 boot boundary이며, `kern.boottime`은 preboot sanity check일 뿐 fallback identity가 아닙니다. 다른 boot의 ledger는 process inspection이나 signal 없이 제거합니다.
- process enumeration, ancestry, identity 재검증, record 저장 또는 exact signal 중 하나라도 unavailable/ambiguous이면 fail-closed로 종료하고 record를 유지합니다. `KERN_PROC_PID` 정보는 불가능한 후보를 제외하거나 opaque process의 모호성을 판단하는 데만 쓰며 identity나 signal 권한을 부여하지 않습니다.
- 남은 구조적 한계는 resume 이후 첫 complete snapshot 전에 descendant가 double-fork와 `setsid`를 끝내고 intermediate ancestry까지 모두 사라지는 경우입니다. 이때 남은 process를 root의 descendant라고 증명할 수 없으므로 PID, 이름, executable, PPID 또는 process-group heuristic으로 추측하지 않습니다.
- `proc_signal_with_audittoken`과 `POSIX_SPAWN_START_SUSPENDED`는 현재 macOS public SDK 선언을 사용합니다. private ABI 경계는 SDK header에 공개되지 않은 `PROC_PIDUNIQIDENTIFIERINFO` flavor `17`의 56-byte 구조와 arg 의미입니다. arg `0`은 live identity와 exact signal 권한 재검증에, arg `1`은 unreaped zombie를 포함한 tree/intent inventory에만 사용하며 반환 크기가 정확히 56 bytes가 아니면 실패합니다.
- launch transaction은 기본 8초, 명시적 startup recovery의 lock 획득은 기본 2초, cleanup/lease-boundary observation의 lock 획득은 기본 1초로 제한합니다. cleanup lock을 얻지 못해도 handle이 보유한 unreaped root와 원래 group에는 cancellation과 독립된 detached task에서 직접 signal하되, ledger를 보존하고 결과를 `incomplete`로 내려 registry에서 `.quarantined` 처리합니다. 따라서 해당 execution은 borrowed discovery/RPC로 재사용되지 않습니다.
- launch coordinator와 ledger store는 symlink와 다른 UID를 거부합니다. 같은 UID의 기존 상태 디렉터리는 열린 descriptor의 type·owner를 확인한 뒤 `0700`으로 harden하고, coordinator는 현재 path가 같은 inode인지 재검증합니다. ledger 임시 파일 정리는 exact `.managed-agy-sessions.<lowercase UUID>.tmp` namespace만 대상으로 하고, regular file·현재 UID·`0600`·single link·크기를 검증합니다. active `flock` writer는 건너뛰고 abandoned inode만 재검증 후 unlink와 directory `fsync`를 수행합니다.

따라서 이 설계의 안전성 목표는 `놓칠 수 없는 무제한 process tree kill`이 아니라 `증명한 owned execution만 종료하고, 증명하지 못하면 상태를 보존해 재시도`하는 것입니다.

## 7. Source policy와 refresh transaction

### 7.1 사용자에게 보이는 source policy

| 설정 | 동작 |
|---|---|
| 자동 | 선택 Google account가 있으면 그 account와 일치하는 local source → 해당 OAuth 순서로 사용. 선택 account가 없으면 ambient local source만 사용. AGY 자동 실행 없음 |
| 로컬 세션 | 실행 중인 Antigravity/AGY account를 조회 대상으로 사용. 선택 OAuth account와 일치시키거나 active OAuth를 바꾸지 않음. managed AGY는 별도 opt-in이 켜진 경우만 허용 |
| Google 계정 | 선택한 OAuth 계정만 사용 |

`local app RPC`, `borrowed CLI`, `managed CLI` 같은 transport 용어는 고급 진단에만 노출합니다. 일반 UI에는 `Antigravity 앱`, `AGY CLI`, `Google 계정`으로 표시합니다.

### 7.2 Account match policy

- refresh context는 조회 대상을 `.selectedOAuth(accountID)` 또는 `.ambientLocal`로 명시합니다. source policy와 target account를 하나의 enum으로 뭉개지 않습니다.
- `자동`에서 선택 OAuth account가 있으면 identity가 다른 local/CLI 결과를 거부하고 해당 OAuth source로 넘어갑니다.
- `자동`에서 선택 account가 있는데 identity를 확인하지 못한 local/CLI 결과도 적용하지 않습니다.
- `자동`에 선택 account가 없거나 사용자가 `로컬 세션`을 명시했을 때만 ambient local identity를 허용하며, 숫자와 함께 해당 계정을 명시합니다.
- local identity와 OAuth identity 비교는 stable Google subject/account ID를 우선하고, 없을 때만 normalized email을 사용합니다. 둘 다 없으면 일치로 추정하지 않습니다.
- local mismatch 뒤 일치 OAuth가 성공하면 숫자는 OAuth 결과를 사용하고 mismatch는 고급 진단에 기록합니다.
- 일치 source가 하나도 없을 때만 사용자에게 `선택한 계정과 실행 중인 AGY 계정이 다릅니다` 상태를 보여줍니다.
- local 결과를 받았다는 이유로 OAuth active account를 자동 변경하지 않습니다.

### 7.3 Transaction

refresh 시작 시 다음 context를 고정합니다.

```text
generation
trigger
accountTarget
accountRepositoryRevision
sourcePolicy
allowManagedCLI
```

transaction 순서:

1. 이전 transaction을 취소하고 generation을 증가시킵니다.
2. trigger가 account/source boundary 변경이면 이전 snapshot을 제거합니다. 일반 refresh면 last-good을 유지한 채 `refreshing`으로 바꿉니다.
3. policy에 맞는 source를 fidelity와 account match 기준으로 평가합니다. `lastSuccessfulSource`는 hint일 뿐 우선권이 아닙니다.
4. source는 snapshot과 refreshed credential을 반환할 수 있지만 저장하지 않습니다.
5. response identity를 request의 `accountTarget`과 검증합니다.
6. refreshed token은 expected account ID와 repository revision을 사용하는 compare-and-swap으로 저장합니다. active account는 변경하지 않습니다.
7. generation과 `accountTarget`이 여전히 같을 때만 snapshot을 적용합니다.
8. 취소되거나 늦은 transaction은 usage와 credential 모두 쓰지 못합니다.

UI state는 boolean 조합 대신 다음 typed state를 사용합니다.

```swift
enum AntigravityPresentationState {
    case disabled
    case setupRequired(AntigravitySetupReason)
    case refreshing(previous: AntigravityQuotaSnapshot?)
    case ready(AntigravityQuotaSnapshot)
    case partial(AntigravityQuotaSnapshot, issues: [AntigravityQuotaDecodeIssue])
    case stale(AntigravityQuotaSnapshot, failure: AntigravityFailure)
    case accountMismatch(expected: ProviderAccountIdentity, received: ProviderAccountIdentity?)
    case identityOnly(ProviderAccountIdentity)
    case failed(AntigravityFailure)
}
```

`partial`은 payload 안에 존재하지만 일부를 decode하지 못한 bucket에만 사용합니다. 유효한 lane은 계속 표시하고 status rail에 `일부 한도를 읽지 못함`을 보여줍니다. 특정 요금제 응답에 과거 관찰된 bucket ID가 없다는 이유만으로 placeholder나 오류를 만들지 않습니다. 식별된 lane의 fraction만 없으면 해당 행을 `사용량 알 수 없음`으로 유지합니다.

## 8. Credential 저장소와 사용자 migration

### 8.1 새 canonical storage

중복 token 파일을 또 다른 단일 평문 token 파일로 합치는 데 그치지 않습니다.

- `accounts.json`: `schemaVersion`, `revision`, `activeAccountID`, opaque v2 account ID, external identity, migration alias, account lifecycle state, credential reference만 저장합니다.
- app-owned Security.framework vault: account별 OAuth credential secret을 저장합니다.
- v2 account ID와 credential reference는 새 opaque UUID입니다. collision 가능한 legacy email-derived ID는 migration alias로만 보존합니다.
- vault service는 bundle identifier namespace를 사용하고 account key는 `oauth.antigravity.v2.<opaque-reference>`처럼 provider/schema prefix가 있는 immutable credential reference를 사용합니다.
- accessibility는 `AfterFirstUnlockThisDeviceOnly`, synchronizable은 false입니다.
- `/usr/bin/security` subprocess를 사용하지 않고 `SecItemCopyMatching/Add/Update/Delete`를 직접 호출합니다.
- 기존 Claude app-owned vault의 검증된 primitive를 provider-neutral `OAuthCredentialVault`로 추출하되 Claude 동작을 바꾸지 않는 characterization test를 먼저 둡니다. exact item load/save/delete 외에 attribute-only namespace enumeration과 namespace-bounded orphan cleanup을 지원합니다.
- metadata와 secret은 역할이 다르며 같은 token을 중복 저장하지 않습니다.
- OAuth source와 UI는 vault를 직접 호출하지 않고 `AntigravityAccountRepository` actor만 사용합니다.
- filesystem atomic replace와 Keychain mutation을 원자 transaction처럼 취급하지 않습니다. 모든 mutation은 secret을 담지 않는 write-ahead operation journal과 immutable credential reference로 복구 가능하게 만듭니다.
- production credential resolution에서 `ANTIGRAVITY_OAUTH_CREDENTIALS_JSON` 우회 경로를 제거합니다. 테스트 credential은 dependency-injected repository/source stub으로 전달합니다.

이 선택은 prod update에서 prompt-free app-owned Keychain access를 전제로 합니다. signed upgrade QA에서 앱 실행, account switch 10회, background refresh에 Keychain prompt가 0회인지 승인 조건으로 둡니다. legacy item 접근에 인증이 필요하면 앱 시작 시 자동으로 묻지 않습니다.

### 8.2 Migration source

읽기 대상:

- `oauth_accounts.json`
- `oauth_creds.json`
- `oauth_metadata.json`
- bundle identifier service와 `ClaudeUsage` service 아래의 legacy ClaudeUsage-owned Antigravity Keychain item 전체

절대로 건드리지 않는 대상:

- `~/.gemini/antigravity-cli`
- Antigravity 앱의 `state.vscdb`
- AGY 자체 로그인/설정/업데이트 데이터
- 다른 앱이 소유한 Google credential

### 8.3 Migration state machine

```text
notStarted
  → preflight(sourceInventory)
  → blockedBeforeCutover(blocker, sourceInventory)
  → awaitingImportAuthorization(items)
  → writingCanonical(operationID, plannedReferences)
  → canonicalVerified
  → cleanupPending([CleanupTarget])
  → complete(version)
```

`blockedBeforeCutover`와 `awaitingImportAuthorization`은 legacy를 보존하는 pre-cutover 상태입니다. `cleanupPending`은 새 repository가 검증된 뒤의 post-cutover 상태에만 사용합니다. migration completion version은 삭제 가능한 `accounts.json`이나 임시 journal이 아니라 별도 durable app migration marker에 기록합니다. journal에는 source fingerprint, planned reference, target별 완료 여부만 저장하고 secret 원문은 저장하지 않습니다. 전체 제거 journal은 revision만 믿지 않고 당시 opaque account ID, immutable credential reference, active ID와 lifecycle을 PII 없는 canonical-state fingerprint로 결합합니다. 자동 재개는 이 지문이 정확히 일치할 때만 canonical 삭제를 계속하며, 새 명시적 제거 action만 현재 상태로 intent를 다시 고정합니다.

안전한 순서:

1. migration actor가 account mutation과 AGY refresh를 잠급니다.
2. operation journal, v2 metadata, v2 vault namespace를 먼저 점검해 중단된 mutation을 복구합니다.
3. 유효한 v2 metadata가 이미 있으면 legacy를 import하거나 덮어쓰지 않습니다. metadata가 참조하는 vault item이 없으면 `blockedBeforeCutover(.canonicalRepairRequired)`로 중단합니다.
4. v2가 없을 때만 두 legacy JSON과 두 legacy Keychain service를 read-only로 inventory합니다. Keychain 결과는 service/account별 `notFound`, `readable(payload)`, `interactionRequired`, `invalid`, `failure(status)`로 보존합니다.
5. 손상된 file을 빈 계정으로 취급하지 않습니다. 다른 source로 완전 복구할 수 없으면 `blockedBeforeCutover`에서 복구 또는 명시적 무시를 기다립니다.
6. exact refresh-token fingerprint가 같은 credential만 자동 병합합니다. 같은 email/legacy ID이지만 fingerprint가 다르면 token lineage conflict로 중단하고 재로그인 또는 사용자 선택을 요구합니다. token과 fingerprint는 로그에 남기지 않습니다.
7. 각 account와 credential에 새 opaque UUID를 만들고 legacy ID는 alias로만 보존합니다. 검증된 Google subject가 있으면 별도 external identity로 저장합니다.
8. 기존 active alias가 정확히 하나의 account로 해석되면 보존합니다. 계정이 하나뿐이면 그 계정을 active로 선택합니다. 여러 계정인데 유효 active가 없으면 임의 선택하지 않고 `blockedBeforeCutover(.accountSelectionRequired)`로 둡니다.
9. JSON에 유효 credential이 없고 legacy Keychain만 `interactionRequired`이면 `awaitingImportAuthorization`과 inline `계정 이전` action을 제공합니다. 사용자 action에서는 하나의 `LAContext`로 legacy read → 새 vault write/read-back → metadata commit → legacy delete를 수행합니다.
10. 이미 canonical credential이 있으면 interactive legacy item은 import하지 않고 delete-only cleanup target으로 다룹니다.
11. secret write 전에 operation ID, expected metadata revision, old/new credential reference를 journal에 기록합니다.
12. 새 immutable vault item을 쓰고 no-UI read-back으로 secret envelope version과 exact write fingerprint 동등성을 검증합니다. account email의 존재만으로 성공 판정하지 않습니다.
13. metadata temp file을 mode `0600`으로 쓰고 expected revision을 확인한 뒤 atomic replace합니다. 다시 읽어 schema, account 수, active ID, lifecycle state, credential reference를 검증합니다. 디렉터리는 `0700`을 강제합니다.
14. metadata commit 뒤 old vault reference를 삭제하고, 실패한 삭제는 target별 cleanup journal에 남깁니다. journal을 complete로 바꾼 뒤 제거합니다.
15. metadata commit 전에 실패하거나 앱이 종료되면 journal의 planned/staged reference를 namespace enumeration으로 찾아 제거하고 부재를 검증합니다. 제거 실패는 숨기지 않고 재시도합니다.
16. credential migration 활성화, 새 repository 주입, remote/probe의 legacy reader 제거는 같은 product cutover commit에서 수행합니다. 그 전 단계의 migration 코드는 테스트되지만 앱 시작 경로에서는 비활성입니다.
17. 제품 코드에서 legacy JSON과 environment credential을 읽는 경로가 0개임을 확인한 뒤에만 `oauth_creds.json`, `oauth_accounts.json`, `oauth_metadata.json`을 삭제합니다.
18. 두 legacy Keychain service를 각각 no-UI로 삭제하고 부재를 검증합니다. cleanup은 source를 고정 v2 quarantine identity로 원자 이동한 뒤 journal의 raw-payload SHA-256과 다시 비교해 같은 값만 삭제합니다. 값이 바뀌었거나 원본 identity가 재생성되면 새 값을 삭제하지 않고 복원 또는 quarantine 보존 상태로 재시도합니다. 인증이 필요한 cleanup은 `cleanupPending`으로 남기고 inline `이전 데이터 정리` action에서만 인증을 요청합니다. no-UI delete query가 예고 없이 prompt를 띄우지 않는지 검증합니다.
19. cleanup 실패는 target별 결과와 함께 다음 실행에서 재시도합니다.
20. 모든 cleanup target 부재가 확인된 뒤에만 durable migration marker를 complete로 기록하고 임시 journal을 제거합니다.

사용자가 migration 도중 앱을 종료해도 다음 실행에서 현재 phase를 읽고 이어서 처리합니다. canonical write 후 crash한 경우 legacy를 재import하지 않고 cleanup부터 재개합니다.

### 8.4 Account removal

- 일반 credential refresh도 operation journal에 expected revision과 old/new immutable reference를 먼저 기록하고, 새 vault write/read-back → metadata CAS → old reference cleanup 순으로 수행합니다. filesystem과 Keychain을 원자적이라고 가정하지 않습니다.
- 단일 account 제거는 먼저 metadata state를 `pendingDeletion`으로 바꿔 조회와 active selection에서 제외하고, vault item을 삭제한 뒤 metadata tombstone을 제거합니다.
- active account를 제거하면 남은 계정이 하나일 때만 자동 선택합니다. 여러 계정이면 선택 없음 상태로 둡니다.
- `모든 Google 계정 연결 해제`는 metadata reference, migration/account-operation journal reference, `oauth.antigravity.v2.*` namespace enumeration의 합집합을 삭제 대상으로 삼습니다. Claude vault namespace와 겹치지 않아야 합니다.
- 이어서 metadata file, legacy JSON/metadata, 두 legacy Keychain service를 제거합니다.
- 다른 owned file이 없으면 `ClaudeUsage/Antigravity` 디렉터리도 제거합니다.
- 삭제 일부가 실패하면 usable account로 되돌리지 않고 `pendingDeletion` 또는 cleanup pending으로 명시합니다.
- 완료 뒤 재실행해도 legacy source에서 계정이 부활하지 않는 test를 둡니다.

### 8.5 UserDefaults migration

전용 `AntigravitySettingsMigrationCoordinator`와 version key를 추가합니다. migration은 `AppSettings`의 published property 초기화 전에 실행합니다.

새 저장 책임은 둘로 나눕니다.

- `AntigravityConnectionSettings`: `schemaVersion`, `sourcePolicy`, `allowManagedCLI`, 조정 가능한 managed-session idle policy
- `AntigravityDisplaySettings`: standard/compact/menu bar/notification presentation intent

active account는 account repository metadata에만 저장하며 connection settings에 중복 저장하지 않습니다. 두 새 설정을 write/read-back할 consumer가 포함된 product cutover commit에서 migration을 처음 활성화합니다.

삭제 대상:

- `antigravityUsageDataSource` 구 enum 값
- `antigravityHiddenModelIDs`
- `antigravityMenuBarPrimaryModelID`
- `antigravityMenuBarSecondaryModelID`
- model-slot 의미를 가진 percentage/reset/icon metric 설정
- 구 `antigravityPrimary`, `antigravitySecondary`, `antigravityTertiary`, `antigravityModels` popover item ID
- 도달 불가능한 `antigravityPopoverPinned`, `antigravityPopoverCompact`, `antigravitySettingsLastTab`
- 제거된 Gemini provider의 다음 12개 잔여 key:
  - `gemini.alertEnabled`
  - `gemini.circularDisplayMode`
  - `gemini.iconMetric`
  - `gemini.menuBarStyle`
  - `gemini.percentageDisplay`
  - `gemini.resetTimeDisplay`
  - `gemini.showBatteryPercent`
  - `gemini.showIcon`
  - `gemini.timeFormat`
  - `geminiPopoverCompact`
  - `geminiPopoverPinned`
  - `geminiSettingsLastTab`

보존 대상:

- provider enabled와 provider order
- menu bar provider visibility
- global compact mode
- icon 표시, menu bar style, time format, alert enabled처럼 의미가 동일한 presentation intent
- refresh interval
- 유효한 account selection

변환 정책:

- old `.googleOAuth`는 `AntigravityConnectionSettings.sourcePolicy = .googleAccount`로 옮깁니다.
- old `.localIDE`/`.agyCLI`는 `.localSession`으로 합치되 `allowManagedCLI`는 기본 false입니다.
- old `.auto`는 `.automatic`으로 옮깁니다.
- 새 connection settings를 write/read-back한 뒤에만 `antigravityUsageDataSource`를 삭제합니다. runtime hardcoded `.auto` 제거와 새 settings 소비도 같은 cutover에 포함합니다.
- model ID 선택은 group × cadence와 의미상 대응하지 않으므로 추정하지 않습니다.
- standard는 전체 known lane, compact/menu bar는 `가장 제약이 큰 한도`를 새 기본값으로 사용합니다.
- popover dictionary에서 Antigravity 항목만 새 `antigravityUsageLimits` section으로 바꾸고 다른 provider 항목은 보존합니다.
- 구 값을 삭제하기 전에 현행 `showIcon || percentage != none || reset != none || style != none` 규칙으로 `oldMenuBarVisible`을 계산해 새 독립 visibility에 저장합니다. percentage만 켰던 사용자도 메뉴바에서 사라지지 않아야 합니다.
- old percentage가 `.none`이 아니면 새 selected-lane percentage 표시 intent를, old reset이 `.none`이 아니면 selected-lane reset 표시 intent를 보존합니다. old dual/5h/weekly의 특정 slot 의미는 smart lane으로 초기화합니다.
- `.concentricRings`는 `.circular`, `.dualBattery`와 `.sideBySideBattery`는 `.batteryBar`로 변환합니다. dual style과 old `iconMetric`의 slot 선택이 초기화됐다는 사실은 한 번 안내합니다.
- `circularDisplayMode`, `showIcon`, `timeFormat`, alert intent처럼 단일 lane에서도 의미가 같은 값은 보존합니다.
- Antigravity 구 ID를 downgrade용으로 dual-write하지 않습니다.
- migration version은 connection/display settings write/read-back과 old key 부재를 검증한 뒤에만 올립니다.

의미를 보존할 수 없어 초기화된 표시 설정은 업데이트 후 설정 화면에서 한 번만 짧게 안내합니다. credential migration이 자동으로 끝난 경우 modal을 띄우지 않습니다.

완료 후 Antigravity 전용 credential/migration storage에 허용되는 상태는 현재 schema의 `accounts.json`, 그 metadata가 참조하는 app-owned vault item, durable migration version뿐입니다. 현재 `AntigravityConnectionSettings`, `AntigravityDisplaySettings`와 shared provider catalog의 enabled/order/menu visibility/refresh interval은 정상 설정 상태이므로 cleanup 대상이 아닙니다. 구 JSON, 구 Keychain item, operation/migration journal, 구 UserDefaults key, metadata에서 참조하지 않는 Antigravity vault item은 모두 잔여물로 간주해 부재를 검증합니다.

## 9. UX/UI 개편

`frontend-design` 검토 결과 별도 테마를 추가하지 않습니다. 기존 macOS native palette, system typography, provider icon을 유지하고 **두 quota scope 안에 5시간/주간 rail을 짝으로 배치하는 구조**를 Antigravity의 시각적 특징으로 삼습니다. 색 카드와 badge를 늘리는 dashboard형 디자인은 정보 밀도만 높이므로 배제합니다.

### 9.1 표준 popover

```text
[Antigravity]                              ↻  축소  고정
user@… · AGY CLI · 방금 갱신

Gemini
  5시간      ━━━━━━━━━━━━━  18% 사용     3시간 12분 후
  주간       ━━━━━━━━━━━━━  42% 사용     월요일 09:00

Claude · GPT
  5시간      ━━━━━━━━━━━━━  12% 사용     4시간 48분 후
  주간       ━━━━━━━━━━━━━  68% 사용     일요일 09:00
```

- scope title은 장식 badge가 아니라 semantic heading입니다.
- lane 순서는 known cadence `5시간 → 주간`, unknown은 그 뒤입니다.
- account, source, freshness는 quota row가 아니라 provider status rail에 둡니다.
- progress는 앱 전체 기준에 맞춰 `사용률`을 표시하되 tooltip과 AX value에서 남은 비율도 명시합니다.
- fraction과 reset 유효성은 독립적으로 처리합니다. fraction이 유효하면 reset이 없어도 progress와 퍼센트를 표시하고 reset 자리만 `갱신 시각 알 수 없음`으로 둡니다.
- fraction unavailable, disabled, unknown은 progress 0으로 그리지 않고 문구로 표시합니다.
- unknown group도 버리지 않되 처음 네 known lane과 시각적으로 구분합니다.
- semantic color는 `available(100%) = critical`, `disabled/unavailable/unknown = neutral`로 분리합니다. 현행 generic color 함수처럼 100%를 회색으로 돌리지 않습니다.

### 9.2 Compact popover

기본은 전체 lane 중 가장 많이 사용된 유효 lane 한 개입니다.

```text
Claude·GPT · 주간                  ━━━━━ 68%
```

- 현재 관찰된 네 lane이나 향후 추가 lane을 그대로 반복하지 않습니다.
- 초 단위 갱신 카운트다운은 표시하지 않습니다.
- generic `CompactUsageRow`를 재사용하지 않고 Antigravity compact projection/component를 둡니다. body label에 provider 이름이나 reset `--`를 다시 붙이지 않습니다.
- 현재 112pt label 영역과 최소 popover 폭에서 `Claude·GPT · 주간`이 의미를 잃지 않고 보이도록 width/truncation snapshot을 승인 기준으로 둡니다. 화면에서 축약돼도 AX label은 완전한 이름을 유지합니다.
- 사용자가 고급 표시 설정에서 특정 stable lane을 고정할 수 있습니다.
- 고정 lane이 사라지면 가짜 0 대신 자동 policy로 fallback하고 설정에 안내합니다.
- compact header는 정상 상태에서도 마스킹된 조회 account와 source를 항상 표시합니다. mismatch/auth/cleanup 상태는 metric 대신 visible status와 action을 보여주며 tooltip에만 숨기지 않습니다.

### 9.3 메뉴바

- 기본은 provider icon과 가장 제약이 큰 lane 한 metric입니다.
- 단독 provider에서는 `C/G·주 68%`처럼 의미를 보존하고, 여러 provider가 함께 있으면 아이콘과 `68%`로 축약합니다.
- `MenuBarProviderSnapshot`은 `regularText`와 `condensedText`를 분리합니다.
- tooltip에는 account, 실제 source, freshness와 전체 lane을 그룹화해 표시합니다.
- status item button의 accessibility label/value에는 선택 lane, 사용률, account, source, freshness를 명시합니다. tooltip은 보조 정보이며 hover-only 접근을 승인하지 않습니다.
- 색상은 선택된 risk metric 기준이지만 퍼센트와 label 없이 색만 사용하지 않습니다.
- 기존 primary/secondary model picker는 `자동—가장 제약이 큰 한도` 또는 stable lane 하나를 고르는 UI로 교체합니다.

### 9.4 설정

중복 runtime overview와 connection card를 하나로 합칩니다.

```text
Antigravity

[사용 중]
현재 조회: local-user@example.com · AGY CLI
한도 상태: 방금 · N개 확인

연결된 Google 계정 [oauth-user@example.com ▾]  [계정 추가]  [•••]
[지금 새로고침]

사용량 한도 미리보기
  Gemini        5시간 18%   주간 42%
  Claude · GPT  5시간 12%   주간 68%

메뉴바 표시
팝오버 표시
알림
고급 연결 및 진단 ▸
```

- account 선택, 추가, 제거를 한 view model transaction으로 처리합니다.
- `현재 조회 account/source`와 `연결된 Google account`를 별도 행으로 둡니다. ambient local account를 active OAuth처럼 보이게 하지 않습니다.
- OAuth 계정 0개 + ambient local만 있음, OAuth 여러 개 + 선택 없음, local/OAuth identity 불일치를 각각 독립 상태로 지원합니다.
- 정상 상태의 파괴적 account action과 수동 legacy 진단은 `•••` 메뉴에 둡니다. 실제 cleanup pending이면 inline notice에 `이전 데이터 정리` primary action을 직접 노출합니다.
- notice는 `.progress`, `.success`, `.warning`, `.failure` typed enum으로 tone과 action을 분리합니다.
- `model quota`, `표시 모델`, `quota 조회됨`을 각각 `사용량 한도`, `표시 한도`, `한도 확인됨`으로 정리합니다.
- `자동/로컬 세션/Google 계정`과 managed CLI opt-in은 `고급 연결 및 진단`에 둡니다.
- 일반 새로고침은 last-good preview를 유지하고 inline spinner/freshness만 바꿉니다.
- account/source 변경은 이전 숫자를 즉시 제거하고 skeleton이 아닌 명확한 `새 계정 확인 중` 상태를 표시합니다.

### 9.5 알림

- `antigravityPrimary/Secondary/Tertiary` tracker를 삭제합니다.
- stable lane ID와 threshold state transition을 추적합니다.
- 동일 refresh에서 여러 lane이 threshold를 넘으면 notification 한 개로 묶고 각 lane을 본문에 나열합니다.
- unknown/disabled lane은 threshold 계산에서 제외합니다.
- account가 바뀌면 이전 account threshold state를 새 account에 상속하지 않습니다.

### 9.6 오류와 빈 상태

다음 상태를 typed failure와 하나의 명확한 action으로 구분합니다.

- AGY/Antigravity 미설치
- 설치됐지만 실행 중 아님
- 로그인 필요
- project trust 또는 browser auth 필요
- 선택 account와 local account 불일치
- OAuth 만료/취소
- structured quota 미지원 버전
- RPC schema 변경
- 일부 lane만 누락
- cleanup pending

내부 구현어인 PTY, protobuf, Connect RPC, CSRF는 일반 오류 문구에 노출하지 않습니다. 고급 진단에는 source, capability, endpoint owner, 마지막 실패 단계만 secret 없이 제공합니다.

일부 bucket decode 실패는 provider 전체 실패로 바꾸지 않습니다. 유효 lane을 유지하고 partial notice를 보여줍니다. 반대로 현재 관찰된 네 bucket 중 하나가 payload에 아예 없다는 이유만으로 `조회되지 않음` placeholder를 합성하지 않습니다. 설정의 `한도 N개 확인` 문구는 실제 유효 lane 수를 사용합니다.

### 9.7 접근성

- group heading과 lane을 VoiceOver 구조로 노출합니다.
- 예: `Gemini, 주간 한도, 42퍼센트 사용, 58퍼센트 남음, 월요일 오전 9시에 갱신`.
- 색상 외에 퍼센트와 상태 문구를 항상 둡니다.
- compact row는 화면에서 짧게 보여도 AX label에는 완전한 scope/cadence를 사용합니다.
- 메뉴바 status item과 compact header의 provenance도 VoiceOver에서 직접 읽을 수 있어야 하며 tooltip에 의존하지 않습니다.
- keyboard focus order, Reduce Motion, light/dark mode, 긴 이메일, 100% 사용, reset 없음, unknown group을 검증합니다.

### 9.8 Provider icon light/dark 책임

Codex에 dark 파일을 하나 더 추가하는 수정은 필요하지 않습니다. 모든 provider icon이 같은 appearance contract와 재현 가능한 asset pipeline을 사용하게 합니다.

- popover/settings의 `ProviderBrandIconResolver`는 appearance-aware named image를 그대로 유지하고 단일 appearance bitmap으로 조기 평탄화하지 않습니다.
- 메뉴바는 `NSApp.effectiveAppearance` 같은 전역 추정이 아니라 실제 `NSStatusBarButton.effectiveAppearance`를 `updateMenuBar → snapshot → icon factory`까지 필수 값으로 전달합니다.
- menu bar asset resolve, alpha crop, fitted bitmap, badge composition 전체를 전달받은 `appearance.performAsCurrentDrawingAppearance` 안에서 수행합니다. 평탄화 결과를 cache하면 `provider + appearance + scale + size`를 key로 사용합니다.
- popover, compact selector, settings, menu bar, badge composition이 동일 resolver를 사용합니다.
- settings의 provider 본문 header도 sidebar와 같은 provider-generic brand icon component를 사용합니다.
- `render-provider-brand-assets.sh`는 같은 source SVG와 padding rule에서 light/dark PNG를 모두 생성하고 `Contents.json` luminosity mapping을 생성 또는 검증합니다.
- icon은 runtime CDN에서 받지 않고 bundle asset으로 고정합니다.
- asset을 LobeHub 원본으로 갱신할 경우 `latest` URL을 build에 사용하지 않습니다. 검토한 package version과 checksum을 고정하고 MIT license/attribution을 repository에 남깁니다.
- light에서는 검정 icon, dark에서는 흰색 icon이 충분한 대비로 보이고 appearance 전환 직후 relaunch 없이 바뀌어야 합니다.

## 10. 구현 순서와 커밋 단위

각 단계는 build 가능한 coherent commit으로 `dev`에 올립니다. 단, 새 저장소나 migration을 추가했다는 이유만으로 중간 commit에서 사용자 데이터를 바꾸지 않습니다. 단계 1~5와 7의 새 AGY 구성 요소는 테스트 가능하지만 기존 AGY product path에 영향을 주지 않는 dormant 상태로 추가하고, 저장소·runtime·UI consumer·migration activation은 단계 8의 단일 cutover commit에서 함께 전환합니다. 단계 6의 provider icon 수정은 사용자 데이터나 AGY runtime과 독립된 cross-provider UI fix이므로 자체 검증 후 즉시 기존 product path에 적용할 수 있습니다. 임시 compatibility adapter는 read-only이며 dual-write하지 않습니다.

### 단계 1. Characterization과 새 contract

- sanitised AGY 1.1.7 quota fixture 추가
- 현행 OAuth account/migration 동작 characterization test 추가
- 새 snapshot/lane/provenance domain과 decoder 추가
- `window` 우선, fallback heuristic, unknown preservation test

예상 commit: `test(antigravity): 최신 quota 계약을 고정`

### 단계 2. Provider-neutral vault와 account repository

- 기존 Claude app-owned vault를 provider-neutral primitive로 추출
- Claude 회귀 test 통과
- Antigravity metadata store + vault repository actor 추가
- namespace enumeration, immutable credential reference, operation journal, revision/CAS 추가
- repository는 아직 기존 runtime에 주입하지 않음

예상 commit: `refactor(auth): OAuth credential vault 책임을 공통화`

### 단계 3. Durable migration 구현과 고장 주입 test

- credential/connection/display migration coordinator와 durable phase state 추가
- legacy 두 JSON과 두 Keychain service reconciliation, vault write/read-back, cleanup retry 구현
- interactive import, no-UI cleanup, conflict/blocker, orphan enumeration 구현
- 실제 사용자 shape를 redacted fixture로 고정
- 앱 시작 및 정상 runtime에서는 아직 migration을 호출하지 않음

예상 commit: `feat(antigravity): v2 migration coordinator를 준비`

### 단계 4. Discovery와 structured local RPC

- 중복 process/cache를 `AntigravityRuntimeDiscovery`로 통합
- process-port ownership과 restricted TLS trust 구현
- quota summary/identity decoder와 deadline/cancellation 구현
- legacy source를 limited capability로 분리

예상 commit: `feat(antigravity): structured local quota 조회 추가`

### 단계 5. Managed AGY lifecycle

- borrowed/owned lease 모델 구현
- opt-in managed launch, auto-update disable, prompt classification 구현
- single-flight, idle timeout, process tree cleanup, crash recovery 구현
- 기존 product TUI 경로는 cutover 전까지 유지하되 새 session manager는 TUI를 quota parser로 사용하지 않음

예상 commit: `feat(antigravity): AGY session lifecycle 분리`

현재 상태: **완료**. 새 session/lifecycle 구성 요소는 단계 8 cutover 전까지 기존 product path에 영향을 주지 않는 dormant 상태로 유지합니다.

- 구현된 범위: durable intent-before-spawn, suspended promotion-before-resume, shared launch lease와 waiter별 cancellation/deadline, readiness RPC probe와 PTY prompt 감시, bounded cross-process launch/recovery/cleanup lock, owned/borrowed/quarantined registry, idle/shutdown cleanup, exact boot·process identity crash recovery, process-tree observation과 공용 production composition.
- Stage 5 전용 12개 test file의 112개 test method와 기존 Stage 4 suite의 managed ownership 경계 회귀 2개를 고정 selector로 실행해 `114/114`가 통과했습니다. cancellation/promotion, 독립 process file-lock contention, active/abandoned temp scavenger, root PGID 이동, 실제 `setsid` descendant, exact zombie ancestry, wrong pidversion signal 거부를 포함합니다.
- 전체 XCTest는 `788`개 중 `787`개가 통과했고, 명시적 환경 변수로만 켜는 로컬 AGY TUI integration test `1`개가 건너뛰어졌습니다. 실패와 expected failure는 없습니다.
- universal Release unsigned build(`CODE_SIGNING_ALLOWED=NO`, `CODE_SIGNING_REQUIRED=NO`)가 성공했고, strict code review와 문서/source 대조에서 남은 재현 가능한 P1/P2 결함 또는 사실 불일치는 없습니다.

### 단계 6. Provider icon appearance 회귀 방지

- Codex light/dark asset과 installed `Assets.car` rendition test 고정
- status button appearance를 menu bar factory까지 명시적으로 전달
- light/dark를 같은 SVG/padding에서 만드는 asset script와 catalog 검증 추가
- settings 본문 header를 provider brand component로 통일
- 메뉴바·popover·settings의 live theme switch test 추가

예상 commit: `fix(ui): provider icon appearance 전환을 보장`

### 단계 7. Refresh와 lane UI 구성 요소 준비

- source protocol과 coordinator 도입
- account match, generation, cancellation, CAS token save 구현
- presentation mapper, quota group/compact view, provider-generic identity rail 추가
- connection/display settings consumer와 settings view model 추가
- 새 구성 요소는 unit/snapshot test에서 사용하되 기존 AppDelegate/UI에 아직 연결하지 않음

예상 commit: `feat(antigravity): v2 refresh와 lane presentation을 준비`

### 단계 8. Atomic product cutover

- credential migration을 활성화하고 새 account repository를 remote/probe/coordinator에 주입
- connection/display settings migration을 새 consumer와 동시에 활성화
- source policy와 account target을 새 refresh coordinator에 연결
- remote client direct persistence, environment credential, AppDelegate hardcoded `.auto` 제거
- standard/compact/menu bar/settings/notification을 stable lane으로 한 번에 전환
- last-good refresh와 account-boundary reset 분리
- legacy JSON·구 UserDefaults를 읽는 product path와 TUI quota product path를 같은 commit에서 제거
- old reader가 0개임을 확인한 뒤에만 migration cleanup 실행
- cutover 전/후 upgrade integration test를 commit gate로 실행

예상 commit: `feat(antigravity): v2 quota runtime과 UX로 전환`

### 단계 9. Legacy 구현 제거와 문서 갱신

- old model domain, TUI parser/fixtures, primary/secondary settings/tracker 삭제
- 구 UserDefaults와 legacy storage 부재 검증
- `docs/antigravity-usage-sources.md`, 인증 문서, release QA 갱신
- dead code와 unreachable copy 최종 검색

예상 commit: `chore(antigravity): legacy 사용량 경로와 잔여 설정 제거`

### 단계 10. 전체 검증과 리뷰

- 전체 XCTest와 Release unsigned build
- signed app upgrade migration QA
- 실제 account/source 전환, process lifecycle, UI QA
- strict code review: 실제 문제만 severity와 file:line 근거로 기록
- 발견된 문제를 수정한 뒤 영향 범위 test와 전체 test 재실행

검증 완료 전 `main` squash, 버전 변경, staging 배포는 하지 않습니다.

## 11. 테스트 매트릭스

### 11.1 Decoder/domain

- root/`response`/`summary` envelope
- `remainingFraction` direct/nested oneof
- `window`가 bucket label과 충돌할 때 `window` 우선
- old payload에서 ID/display fallback
- decimal precision
- reset 누락/invalid timestamp
- disabled/missing fraction
- unknown group/cadence 보존
- duplicate bucket stable-ID collision 처리
- 빈 group과 완전한 schema mismatch

### 11.2 Discovery/RPC

- 같은 UID와 exact binary만 candidate
- unrelated process/port 거부
- app endpoint에만 필요한 CSRF
- CLI endpoint tokenless request
- loopback 이외 TLS trust 거부
- quota summary 우선, identity best-effort
- 단계별/전체 deadline
- cancellation 중 connection과 task 종료
- concurrent discovery single-flight

### 11.3 Managed process

- borrowed process를 종료하지 않음
- owned process만 종료
- concurrent request가 process 하나 공유
- `AGY_CLI_DISABLE_AUTO_UPDATE=true` 전달
- login/trust/browser prompt 자동 승인 없음
- early exit, timeout, task cancel, child process tree cleanup
- in-flight 중 idle teardown 없음
- 180초 idle 종료
- PID reuse와 stale process record
- 앱 재실행 crash recovery
- automatic policy가 AGY를 암묵적으로 실행하지 않음

### 11.4 Orchestration/provenance

- 선택 A와 local B 불일치 시 거부 후 OAuth A fallback
- selected account가 있을 때 identityless local 거부
- selected account가 없을 때 ambient local identity 표시
- explicit local-session policy가 active OAuth와 다른 ambient local identity를 허용하되 active OAuth를 바꾸지 않음
- A refresh 중 B 전환 시 A usage/token write 모두 폐기
- A token refresh가 active account를 변경하지 않음
- 자기 token revision update 때문에 정상 usage가 폐기되지 않음
- trigger 한 번당 transaction 한 번
- 일반 refresh last-good 유지
- account/source 변경 이전 payload 즉시 제거
- source fallback 뒤 실제 provenance 유지

### 11.5 Repository/migration

- legacy file 없음/accounts만/active만/둘 다 있음
- account list와 active file 중복·충돌
- account file 하나 손상
- email 없는 계정
- exact 중복 refresh token 자동 병합
- 같은 email/legacy ID지만 다른 token lineage는 pre-cutover blocker
- legacy ID collision이 opaque v2 ID/vault ref를 덮어쓰지 않음
- multiple account인데 active 없음
- 두 legacy Keychain service의 개별 notFound/readable/interactionRequired/invalid/failure
- 유일 credential이 interactive Keychain일 때 한 `LAContext` import
- canonical 존재 시 interactive legacy item delete-only
- immutable vault write/read/delete 각 실패
- metadata temp write/atomic CAS/read-back 각 실패
- journal 기록, vault write, metadata commit, old-ref delete 각 단계 crash recovery
- metadata와 journal에 없는 namespace orphan enumeration/cleanup
- Claude/Antigravity vault namespace 격리
- pendingDeletion account가 조회/선택되지 않음
- canonical write 후 crash와 cleanup target별 재개
- cleanup 검증 직전 source 교체, quarantine 직후 원본 재생성, restore 실패 보존
- 전체 제거 journal과 같은 revision으로 재생성된 다른 canonical account 보존
- legacy JSON cleanup 실패와 재실행
- Keychain no-UI miss/success/auth required/cancel/delete failure
- v2가 있으면 stale legacy를 import하지 않음
- `ANTIGRAVITY_OAUTH_CREDENTIALS_JSON` production resolution 부재
- connection settings write/read-back 후에만 old source key 삭제
- migration idempotence
- directory `0700`, metadata `0600`
- token/client secret/fingerprint가 로그에 없음
- 완료 후 canonical metadata + app-owned vault만 존재
- 완료 marker 뒤 orphan cleanup 실패가 post-cutover `cleanupPending`으로 재시도됨
- delete-all 후 file/vault/directory 부재 및 계정 미부활

### 11.6 Settings/UI

- 구 Antigravity/Gemini key 제거와 타 provider 설정 보존
- popover dictionary에서 Antigravity 항목만 변환
- standard에서 현재 관찰된 네 lane 순서와 reset format, lane 누락·추가 상태
- compact 기본 한 metric, fixed lane, fixed lane 소실 fallback
- menu bar regular/condensed text와 전체 tooltip
- unknown/disabled가 0%로 표시되지 않음
- account/source/freshness standard·compact 표시
- mismatch에서 잘못된 숫자 미노출
- refresh 중 flicker 없음
- threshold 여러 개를 notification 하나로 집계
- reset 없음 + fraction 있음은 progress 유지
- available 100%는 critical, unavailable/disabled는 neutral
- OAuth 0개 + ambient local, OAuth 여러 개 + 선택 없음의 account/source 행 구분
- cleanup pending inline action
- compact 최소 폭에서 label 의미와 AX full label 유지
- Aqua/Dark Aqua `ProviderCodexIcon` rendition과 반대 명도 검증
- status button appearance가 menu bar rasterization에 전달됨
- asset script 재실행 후 light/dark alpha bounds·padding·catalog mapping 일치
- settings sidebar와 provider 본문 header가 같은 brand asset 사용
- 긴/짧은 locale, light/dark, keyboard, VoiceOver, Reduce Motion

### 11.7 실제 앱 QA

1. 기존 prod app에 legacy account와 model 설정이 있는 상태에서 새 signed app으로 업데이트합니다.
2. 첫 실행에 불필요한 modal과 Keychain prompt가 없는지 확인합니다.
3. account 수, active account, provider enabled 상태가 유지되는지 확인합니다.
4. legacy JSON과 구 settings가 정리됐는지 값은 출력하지 않고 존재 여부만 확인합니다.
5. Antigravity app 계정, 외부 AGY 계정, OAuth 선택 계정을 조합해 match/mismatch를 검증합니다.
6. account A↔B를 10회 전환하며 이전 수치, token active race, Keychain prompt가 없는지 확인합니다.
7. automatic refresh가 AGY를 시작하거나 update하지 않는지 확인합니다.
8. managed launch opt-in에서 auto-update가 비활성이고 idle 종료되는지 확인합니다.
9. standard/compact/menu bar/settings/notification을 실제 화면으로 검수합니다.
10. 모든 계정 연결 해제 후 app-owned data가 남지 않고 AGY 자체 데이터는 보존되는지 확인합니다.

## 12. 문서와 관찰 가능성

구현 완료 시 다음 문서를 함께 갱신합니다.

- `docs/antigravity-usage-sources.md`: source 우선순위, structured RPC, capability와 provenance
- `docs/authentication-and-sources.md`: metadata/vault 저장 경계, account match, token refresh CAS
- `docs/PROJECT_WORKFLOW.md`: AGY 실연동 opt-in test와 migration release QA
- release note: 자동 migration, UI 변경, managed CLI 기본 off, old settings reset 안내

진단 정보는 다음만 포함합니다.

- source category
- capability
- account identity의 마스킹된 label 또는 stable non-secret ID
- process owned/borrowed
- fetch age
- typed failure stage/code
- migration phase와 cleanup pending 종류

raw payload, token, credential fingerprint, cookie, CSRF, 전체 이메일은 log와 support export에 포함하지 않습니다.

## 13. Rollback과 릴리스 경계

- migration 전 legacy를 삭제하지 않으므로 canonical verification 전 실패는 기존 prod 상태를 보존합니다.
- canonical cutover 뒤에는 old runtime으로 자동 fallback하지 않습니다. dual-write가 race와 stale credential 부활을 다시 만들기 때문입니다.
- cleanup pending은 새 runtime을 유지한 채 cleanup만 재시도합니다.
- corrupt legacy는 보존하고 복구/무시를 사용자에게 명시적으로 선택하게 합니다. 데이터 손실을 `잔여물 정리`로 포장하지 않습니다.
- 사용자 데이터 migration, runtime cutover, UI semantic change는 동일 app release에서 완결합니다.
- staging에 올리기 전 이전 prod → 새 staging signed upgrade 경로를 별도로 검증합니다.
- staging tag/release는 기존 운영 규칙대로 immutable이며, blocker가 나오면 다음 patch candidate를 만듭니다.

## 14. 구현 중 금지 사항

- `Model Quota`를 `Models & Quota`로 바꾸는 것만으로 완료 처리
- TUI ANSI 문자열을 새 group/cadence parser로 다시 작성
- model ID를 `gemini.weekly` 같은 lane ID로 이름만 변경
- local 결과의 account를 확인하지 않고 선택 OAuth 계정 아래 표시
- remote source가 token이나 active account를 직접 저장
- `oauth_accounts.json`과 active credential mirror를 계속 dual-write
- migration delete 실패를 `try?`로 숨김
- unknown을 0으로 대체
- automatic refresh가 AGY를 몰래 실행하거나 update
- borrowed process 종료
- 구 settings를 downgrade 명목으로 영구 dual-write
- credits, token history, quota를 하나의 percentage로 합침

이 금지 조건 중 하나라도 남으면 전면 개편 완료로 간주하지 않습니다.

## 15. 조사 출처

- [Antigravity CLI `/usage`](https://antigravity.google/docs/cli/commands/usage)
- [Antigravity CLI `/credits`](https://antigravity.google/docs/cli/commands/credits)
- [Antigravity CLI troubleshooting](https://antigravity.google/docs/cli/troubleshooting)
- [Google Antigravity CLI repository](https://github.com/google-antigravity/antigravity-cli)
- [LobeHub OpenAI icon reference](https://lobehub.com/ko/icons/openai)
- [Lobe Icons repository and light/dark static asset guidance](https://github.com/lobehub/lobe-icons)
- [Apple XNU `proc_uniqidentifierinfo` 56-byte layout and flavor 17](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_info_private.h)
- [Apple XNU flavor 17 arg semantics and exact signal kernel validation](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/proc_info.c)
- [Apple XNU immutable parent unique identity across reparent](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_proc.c)
- [Apple libproc `proc_signal_with_audittoken` wrapper](https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.c)
- [Apple XNU `POSIX_SPAWN_START_SUSPENDED` exec handling](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_exec.c#L2068-L2079)
- 이번 조사에서 관찰한 local AGY 1.1.7 `RetrieveUserQuotaSummary` 구조. 구현 1단계에서 재수집해 repository의 sanitised fixture로 고정
- `/Users/seongmin/Personal/reference/CodexBar` `cc8da27c`
- `/Users/seongmin/Personal/reference/orca` `e1f0e768`
- `/Users/seongmin/Personal/reference/ccusage` `409b4a5`
- ClaudeUsage 현행 source, XCTest, 현재 UserDefaults key와 app-owned file metadata
