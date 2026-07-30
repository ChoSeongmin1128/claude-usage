# Antigravity 사용량 소스와 설정 UX

최종 갱신: 2026-07-30

이 문서는 ClaudeUsage의 Antigravity provider가 어떤 근거로 로컬 앱, AGY CLI, Google OAuth 원격 quota를 다루는지 정리합니다. 구현을 바꿀 때는 이 문서와 테스트를 같이 갱신해야 합니다.

## 1. 공식 제품 기준

확인한 공식 문서:

- [Introducing Google Antigravity 2.0](https://antigravity.google/blog/introducing-google-antigravity-2-0?app=antigravity)
- [Google Antigravity CLI](https://antigravity.google/blog/introducing-google-antigravity-cli?app=antigravity)
- [Antigravity CLI Overview](https://antigravity.google/docs/cli-overview)
- [Using AGY CLI](https://antigravity.google/docs/cli-using)
- [Antigravity Changelog](https://antigravity.google/changelog?app=antigravity)

2026-05-19 공개 기준으로 Antigravity 2.0은 기존 IDE와 분리된 standalone 앱입니다. AGY CLI는 `agy` 명령을 쓰는 terminal-first surface이고, Antigravity 2.0과 같은 agent harness 및 핵심 설정을 공유합니다. CLI 설정 파일은 공식 문서 기준 `~/.gemini/antigravity-cli/settings.json` 입니다.

따라서 ClaudeUsage의 UX 기준은 다음입니다.

- Antigravity 2.0 앱 사용량과 AGY CLI 사용량을 별도 provider로 쪼개지 않습니다.
- CLI는 별도 quota 원장이 아니라 같은 Antigravity 계정 quota의 다른 surface로 봅니다.
- AGY CLI 로컬 상태 파일도, `agy` TUI의 `/usage` 화면도 usage source로 파싱하지 않습니다. TUI는 UI이지 API가 아니므로 quota 수치의 근거로 쓰지 않습니다. ClaudeUsage가 시작한 AGY도 구조화된 localhost RPC만 읽습니다.
- CLI 후보는 `ANTIGRAVITY_CLI_PATH`, `~/.local/bin/agy`, Homebrew 경로, 현재 프로세스의 절대 `PATH` 순으로 감지합니다. 로그인 셸이나 shell wrapper를 실행해 경로를 추측하지 않습니다.
- 후보는 regular Mach-O 파일, 현재 사용자 또는 root 소유, group/world 비쓰기 가능, 단일 hard link여야 하며 Google Developer ID 팀 `EQHXZ8M8AV`의 `cli` designated requirement를 충족해야 합니다.
- 검증된 CLI만 필요 시 자동 실행합니다. 실행 직전에는 같은 파일 identity와 정적 서명을 다시 확인하고, 실행 중 프로세스도 동적 code requirement로 확인합니다.
- Windows는 현재 제품 요구사항에서 제외합니다.

## 2. CodexBar 기준에서 가져온 판단

CodexBar 최신 구현은 local app → AGY CLI → IDE → OAuth 순서의 자동 probe, 선택 계정 guard, 소유한 AGY 프로세스만 정리하는 lifecycle을 둡니다.

ClaudeUsage는 CodexBar와 호환을 목표로 하지 않습니다. 대신 아래 판단만 제품 방향으로 가져옵니다.

- Antigravity OAuth 토큰은 Keychain 전제보다 파일 기반 로컬 계정 저장이 사용성 측면에서 낫습니다.
- Keychain prompt를 refresh 경로에 섞으면 메뉴바 앱의 백그라운드 갱신 UX가 나빠집니다.
- 사용자는 데이터 소스를 고르는 대신 조회 계정만 고릅니다. 로컬 ambient 계정도 명시적인 선택지입니다.
- 선택한 Google 계정과 local/CLI 응답 identity가 다르면 그 수치를 거부하고 다음 source로 진행합니다.
- 로컬 앱 API가 quota window를 주지 않는 경우가 있으므로 원격 OAuth path가 필요합니다.
- Google Cloud Code Assist 계열 원격 endpoint는 공개 안정 API가 아니므로 parser/request 코드는 테스트로 방어해야 합니다.
- IDE extension 전용 probe는 이번 구현 범위에 포함하지 않습니다. 현재 ClaudeUsage가 검증하는 source는 local app, 외부 AGY, managed AGY, OAuth 네 가지입니다.

## 3. 자동 조회 정책

사용자가 고르는 값은 조회 계정 하나입니다.

- `로컬 Antigravity/AGY 계정`: local app → 외부 AGY → 검증된 AGY 자동 실행 순서로 조회합니다.
- 연결한 Google 계정: local app → 외부 AGY → 검증된 AGY 자동 실행 → 선택 계정 OAuth 순서로 조회합니다. local 결과의 identity가 선택 계정과 다르면 표시하지 않고 다음 source로 진행합니다.

검증된 AGY가 없거나 서명 검증에 실패하면 managed source를 계획에 넣지
않습니다. 검증된 AGY는 앞선 실행 중 source가 quota를 주지 못했을 때
자동으로 시작하며, `managedSession.idleTimeoutSeconds`(기본 180초) 뒤에
ClaudeUsage가 시작한 process tree만 정리합니다. 사용자가 시작한 프로세스는
종료하지 않습니다.

`AntigravityConnectionSettings` schema v2는 `managedSession`만 보존합니다.
schema v1의 `sourcePolicy`와 `allowManagedCLI`, 더 오래된
`antigravityUsageDataSource`는 migration에서 제거하고 idle timeout만
보존합니다.

quota 수치는 구조화된 localhost RPC와 Google OAuth 응답에서만 옵니다. `agy`
TUI 문자열을 파싱해 수치를 만들지 않습니다.

## 4. 로컬 앱 조회

책임 분리:

- `AntigravityStatusProbe`: 프로세스 탐지, 캐시, 2.0 language server 명령 판별
- `AntigravityRuntimeDiscovery`: endpoint 후보 구성과 실행 image 신뢰 검증
- `AntigravityLocalRPCTransport` / `AntigravityLocalRPCClient`: local HTTP/HTTPS 요청, retry, deadline
- `AntigravityLocalRPCModels`: 구조화 RPC 응답 DTO
- `AntigravityQuotaSummaryDecoder`: RPC 응답을 quota snapshot으로 decode

조회 흐름:

1. `/bin/ps -ax -o pid=,command=` 로 Antigravity language server를 찾습니다.
2. Antigravity 2.0의 `language_server`와 기존 `language_server_macos` 계열을 모두 허용합니다.
3. standalone Antigravity 2.0 프로세스를 legacy IDE 프로세스보다 우선합니다.
4. `--https_server_port`, `--extension_server_port`, `--csrf_token`, `--extension_server_csrf_token` 을 읽습니다.
5. `0` 또는 범위를 벗어난 포트는 버립니다. Antigravity 2.0이 `--https_server_port 0` 을 남기는 경우가 있어서 필수 방어입니다.
6. `lsof` 로 실제 LISTEN 포트를 추가 수집하고, flag hint와 합쳐 probe합니다.
7. `GetUnleashData` 로 연결 가능한 endpoint를 고른 뒤 `GetUserStatus` 를 우선 호출합니다.
8. `GetUserStatus` 실패 시 `GetCommandModelConfigs` 로 quota-only fallback을 시도합니다.

로컬 API는 self-signed HTTPS를 쓸 수 있으므로 local session은 ephemeral session과 trust override를 씁니다. 이 경로는 Antigravity 앱 프로세스의 CSRF token이 필요하며, 실패하면 cache를 무효화하고 다음 refresh에서 재탐지합니다.

## 5. Google OAuth 원격 조회

책임 분리:

- `AntigravityOAuthLoginRunner`: 브라우저 + loopback OAuth 로그인
- `AntigravityOAuthSupport`: credentials DTO, client discovery, legacy Keychain migration
- `AntigravityOAuthFileStorage`: 파일/디렉터리 권한 고정
- `AntigravityOAuthAccountStore`: 다중 Google 계정 저장과 active account 동기화
- `AntigravityGoogleOAuthQuotaClient`: token refresh, project resolve, quota endpoint 호출과 계정 귀속 검증
- `AntigravityQuotaSummaryDecoder`: 원격 응답을 quota snapshot으로 decode

원격 endpoint:

- `POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`
- `POST https://cloudcode-pa.googleapis.com/v1internal:onboardUser`
- `POST https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels`
- `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`

기본 원격 후보는 실행 중인 Antigravity 프로세스가 노출한 endpoint를 먼저 존중하고, 없으면 `cloudcode-pa.googleapis.com`, `daily-cloudcode-pa.googleapis.com` 순서로 시도합니다. 첫 endpoint가 계정 정보만 내려주고 quota fraction을 주지 않으면 최종 성공으로 삼지 않고 다음 endpoint를 확인한 뒤, 모든 후보가 같은 상태일 때만 identity-only 응답으로 처리합니다.

원격 조회는 Google OAuth access token을 사용합니다. access token이 없거나 만료 임박이면 refresh token으로 갱신합니다. project ID가 없으면 `loadCodeAssist` 응답, `onboardUser`, 재조회 순서로 project ID를 보완하고, 찾은 값은 credentials에 저장합니다. OAuth client는 명시 환경변수를 우선하고, 없으면 Antigravity 2.0 번들의 client 정보를 탐색합니다. 번들의 `language_server`에는 client id만 있고 실제 secret이 아닌 `GOCSPX...https` 문자열이 붙어 있을 수 있으므로, 번들 secret fallback은 길이와 경계를 검증한 후보만 사용합니다.

`fetchAvailableModels` 가 403이거나, 200 응답이지만 usable usage fraction을 주지 않으면 `retrieveUserQuota` 를 fallback으로 시도합니다. 둘 다 403이면 인증 자체가 깨진 것으로 보지 않고 identity-only 상태를 허용합니다. 401은 재로그인이 필요한 인증 실패로 봅니다. `retrieveUserQuota` 가 비어 있거나 유효한 모델 bucket을 주지 않으면 정상 수치 미제공으로 삼키지 않고 parse failure로 처리합니다. 이 fallback endpoint는 shape 변화가 생겼을 때 조용히 identity-only로 퇴행하면 문제를 늦게 발견하기 때문입니다.

모델 ID는 있지만 `remainingFraction` 이 없는 quota는 usage window로 만들지 않습니다. Antigravity 응답 shape가 바뀌어 사용량 값이 빠진 경우 0%/100% 같은 가짜 수치를 표시하지 않고, 계정/plan만 확인된 `quota 수치 미지원` 상태로 남깁니다.

OAuth 로그인 callback은 loopback server로만 받습니다. callback parser는 `GET`, `Host: 127.0.0.1:<port>`, `/oauth2callback` path, OAuth `state` 를 모두 확인합니다.

OAuth login은 loopback redirect와 PKCE(`S256`)를 사용합니다. 설치된 Antigravity.app에서 찾은 client는 공개 client 흐름을 먼저 시도한 뒤 Google이 client credential 오류를 반환하면 같은 client ID의 검증된 secret 후보를 순서대로 재시도합니다. 이 처리는 사용자가 별도 Google Cloud 프로젝트나 OAuth secret을 준비하지 않아도 로그인할 수 있게 하기 위한 방어입니다.

OAuth client 정보는 아래 순서로 찾습니다.

1. `ANTIGRAVITY_OAUTH_CLIENT_ID`, 선택적으로 `ANTIGRAVITY_OAUTH_CLIENT_SECRET`
2. `/Applications/Antigravity.app/Contents/Resources/app/out/main.js`
3. `/Applications/Antigravity.app/Contents/Resources/bin/language_server`
4. 사용자 `~/Applications/Antigravity.app` 의 같은 경로

Antigravity 2.0 language server에는 같은 client ID에 여러 secret 후보가 들어 있을 수 있으므로 token refresh에서 공개 client 요청과 같은 client ID의 secret 후보를 순서대로 재시도합니다.

## 6. 저장소와 Keychain 정책

Antigravity OAuth 저장 위치:

- prod active credential: `~/Library/Application Support/ClaudeUsage/Antigravity/oauth_creds.json`
- prod account list: `~/Library/Application Support/ClaudeUsage/Antigravity/oauth_accounts.json`
- staging root: `~/Library/Application Support/ClaudeUsage-stg/Antigravity`
- 디렉터리 권한: `0700`
- credential 파일 권한: `0600`

정책:

- Antigravity status 확인과 refresh 경로는 Keychain을 읽지 않습니다.
- 신규 Antigravity OAuth token은 Keychain에 저장하지 않습니다.
- 기존 사용자 호환을 위해 과거에 잘못 들어간 `antigravity-oauth-credentials` Keychain 항목만 앱 시작 시 1회 migration 대상으로 봅니다.
- migration은 `LAContext.interactionNotAllowed` 와 no-UI Security query로만 시도합니다. macOS password prompt가 필요하면 건너뜁니다.
- migration에 성공한 경우에만 파일 저장소로 옮긴 뒤 legacy Keychain 항목을 삭제합니다.
- 파일 decode 실패나 prompt-free read 실패는 사용자의 Keychain 항목을 삭제하지 않습니다.

이 정책은 “토큰이 secret이 아니어서”가 아니라, 메뉴바 앱의 자동 refresh에서 Keychain prompt가 뜨는 순간 UX와 안정성이 더 크게 깨지기 때문입니다. Antigravity에 대해서는 사용자가 명시적으로 ClaudeUsage OAuth를 연결하고, 앱은 그 결과를 제한 권한 파일로 관리합니다.

## 7. 설정 UX 기준

설정 화면은 아래 상태를 분리해서 보여줘야 합니다.

- 조회 계정: 로컬 ambient 계정 또는 연결된 Google 계정
- 로컬 앱 상태: 실행 중, 연결 가능, token/port 누락, 첫 성공 조회 여부
- CLI 상태: 검증된 실행 파일 경로, 미감지, Google 서명 거부, 복구 실패
- OAuth 상태: 연결 여부, active Google account, 계정 추가/선택/해제
- 표시 설정: standard/compact 다중 lane 선택, 메뉴바 단일 lane 선택

표시 원칙:

- 로컬 앱이 실행 중이어도 quota window가 없으면 0%처럼 보이면 안 됩니다.
- quota 모델은 감지됐지만 usage fraction이 없으면 100%처럼 보이면 안 됩니다.
- quota가 없고 identity만 있으면 메뉴바 숫자 대신 `!` 상태 마커를 표시하고, 팝오버/설정에서는 `계정 확인됨 · 수치 미지원` 계열 문구로 보여줍니다.
- 후보 경로의 `agy`가 Google 서명 검증에 실패하면 자동 실행을 막고 `감지됐지만 Google 서명 검증 실패`로 보여줍니다.
- CLI가 없어도 로컬 앱 조회와 Google OAuth 원격 조회는 사용할 수 있습니다.
- Google 계정을 선택한 경우 Antigravity 앱 로그인만 OAuth 준비 완료로 취급하지 않습니다. ClaudeUsage에 연결한 해당 OAuth 계정이 있어야 합니다.
- 로컬 계정을 선택한 경우 ClaudeUsage OAuth가 없어도 local runtime만 기준으로 판단합니다.
- standard와 compact는 lane마다 표시 여부와 순서를 선택할 수 있습니다. compact의 `가장 제약 높은 순`은 단일 lane 필터가 아니라 보이는 lane 전체의 정렬 정책입니다.
- built-in lane은 payload 전에도 편집할 수 있고, 현재 미관측 lane은 `지금 데이터 없음`으로 남깁니다. 새 unknown lane과 저장된 미관측 unknown lane도 stable ID를 유지합니다.
- 메뉴 막대는 공간 제약 때문에 기존 단일 lane 선택을 유지합니다.
- generic `popoverItemsV2`/`compactPopoverItemsV2`에는 Antigravity 항목을 저장하지 않습니다. 표시 설정의 단일 권위는 typed `AntigravityDisplaySettings`입니다.

표시 계층 책임:

- `CatalogDisplayAdapter`: Claude/Codex 정적 catalog를 공통 editor model로 변환
- `AntigravityDisplayAdapter`: built-in/observed/stored lane을 병합하고 공통 editor model로 변환
- `CatalogPopoverPresentationAdapter`, `AntigravityPopoverPresentationAdapter`: provider별 상태와 복구 action을 공통 runtime summary로 변환
- `ProviderDisplayEditorShell`, `DisplayItemList`, `DisplayItemRow`, `StandardUsageRow`, `CompactUsageRow`, `ProgressBarView`: provider 의미를 모르는 공통 UI primitive. Claude/Codex와 Antigravity 일반 팝오버는 `StandardUsageRow`를 함께 사용하고, Antigravity의 group 의미만 provider presentation에 남깁니다.
- `AntigravitySettingsStore`: Antigravity connection/display typed 설정의 유일한 저장 권위

display schema v2는 v1 `automaticMostConstrained`를 모든 known lane 표시 +
제약 높은 순 정렬로, `fixed(id)`를 해당 lane만 표시 + manual 순서로 원자적으로
이전합니다. write/read-back 검증 전에는 migration marker를 올리지 않고 실패 시
원본 UserDefaults snapshot을 복구합니다. schema v2 display key는 구버전으로
역변환해 dual-write하지 않으므로 2.4.4 이전 앱으로 downgrade하면 Antigravity
표시 설정을 읽지 못할 수 있습니다. Claude/Codex generic 표시 설정은 영향을
받지 않습니다.

새 built-in lane을 추가할 때는 `AntigravityQuotaLaneID`의 stable ID와 decoder
mapping을 먼저 추가하고, `AntigravityDisplaySettings.builtInLaneIDs` 및
`AntigravityDisplayAdapter.knownDescriptor`를 함께 갱신합니다. renderer는
공통 editor/usage row를 그대로 사용하므로 새 합성 catalog 항목이나 generic
UserDefaults 키를 추가하지 않습니다. 서버에서 먼저 등장한 unknown lane은 이
등록 전에도 raw stable ID로 보존됩니다.

## 8. 테스트 기준

Antigravity 쪽 변경은 최소 아래 범위의 테스트를 유지해야 합니다.

- `AntigravityStatusProbeTests`: 2.0 `language_server`, legacy binary, process priority, invalid port filtering
- `AntigravityQuotaSummaryDecoderTests`: 구조화 RPC quota 응답 decode 계약
- `AntigravityGoogleOAuthQuotaClientTests`: Google OAuth quota 조회와 계정 귀속 검증
- `AntigravityQuotaPresentationMapperTests`: lane grouping, 미지원/불가 값, multi-lane 정렬, menu bar single lane, freshness
- `AntigravityQuotaPresentationRenderingTests`: standard/compact 실제 렌더 폭, 다중 lane, 합성 0% 방지
- `AntigravityRefreshCoordinatorTests`, `AntigravityRuntimeControllerTests`: 계정/세션 경계, stale 응답 차단, display mutation 직렬화
- `AntigravityAccountRepositoryTests`, `AntigravityMigrationCoordinatorTests`: vault write/read-back, 잔여 데이터 제거
- `AntigravityDisplaySettingsV2MigrationTests`, `AntigravitySettingsMigrationCoordinatorTests`: display schema v1→v2, 구 UserDefaults 이전, rollback/marker 순서, idle timeout 보존, generic Antigravity 키 제거
- `AntigravityDisplayAdapterTests`, `ProviderDisplayArchitectureTests`: known/unknown/unavailable lane, all-hidden, 1~6 compact row, Claude/Codex preference persistence, adapter status contract
- `AntigravityDiscoverySecurityTests`, `AntigravityManagedCLI*Tests`, `AntigravityManagedProcessTreeTests`: 실행 image 신뢰, managed lifecycle, idle teardown
- `AntigravityOAuthCredentialsStoreTests`: file-only status/load, legacy Keychain no-UI migration/delete
- `AntigravityOAuthLoginRunnerTests`: loopback OAuth callback host/method/state 검증과 취소 정리
- `AntigravityOAuthAccountStoreTests`: multi-account active credential 동기화
- `AntigravityOAuthSettingsViewModelTests`: login cancel, account add/select/disconnect UX 상태
- `ProviderEnvironmentDetectorTests`, `RuntimeProviderSettingsPresentationTests`, `PopoverViewModelTests`: 자동 조회 readiness 해석과 lane 경계

원격 endpoint가 private/internal 성격이므로 “실패하지 않는다”보다 “응답 shape 변화가 어디에서 깨졌는지 빠르게 드러난다”가 테스트의 목적입니다.

## 9. 운영 리스크

- Antigravity 2.0/CLI는 출시 직후라 binary name, flag, endpoint response shape가 바뀔 수 있습니다.
- Google Cloud Code Assist endpoint는 공개 안정 API가 아니므로 403/parse failure 증가 시 upstream 변경을 먼저 의심해야 합니다.
- OAuth client discovery는 환경변수, Antigravity.app bundle 순서로 의존합니다. Antigravity bundle 구조가 바뀌면 환경변수 override가 우선 복구 수단입니다.
- local language server port와 CSRF token은 재시작 때 바뀝니다. stale cache가 의심되면 `AntigravityStatusProbe.invalidateCache()` 경로와 retry를 먼저 확인합니다.
- AGY CLI 설정 파일은 공식 문서상 JSON 파일입니다. 설정 내용을 임의로 수정하지 말고, 존재 여부와 경로 상태만 UX에 노출합니다.

## 실제 AGY 회귀 검증

- AGY는 명령행에 quota RPC 포트를 노출하지 않으면서 동일 PID에서 복수의
  loopback listener를 열 수 있습니다. exact PID, 실행 파일, 사용자, 포트
  소유권을 검증한 뒤 모든 IPv4 loopback listener를 후보로 유지하고, 실제
  quota RPC 응답을 파싱한 endpoint만 사용합니다.
- `AntigravityLiveAGYIntegrationTests`는 opt-in 테스트입니다. 설치되고 로그인된
  공식 AGY를 production launcher로 실행해 원본 grouped quota를 받은 뒤,
  Gemini와 Claude·GPT의 5시간/주간 quota가 모두 있는지 확인하고
  local app → borrowed CLI → managed CLI 자동 조회 coordinator까지 검증합니다.
- 통합 `Scripts/release.sh`는 전체 XCTest 직후 이 live 테스트를 직접 실행합니다.
  XCTest의 skip 결과만으로는 AGY 배포 게이트를 통과한 것으로 보지 않습니다.
