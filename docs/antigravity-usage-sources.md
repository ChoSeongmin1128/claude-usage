# Antigravity 사용량 소스와 설정 UX

이 문서는 ClaudeUsage의 Antigravity provider가 어떤 근거로 로컬 앱과 AGY CLI의 계정 및 quota를 다루는지 정리합니다. 구현을 바꿀 때는 이 문서와 테스트를 같이 갱신해야 합니다.

source·account·process lifecycle 계약은 이 문서를 따릅니다. 실제 게시 버전과
검증 상태는 `HANDOFF.md`, 미배포 작업은 `WORK_PLAN.md`를 확인합니다.

## 1. 공식 제품 기준

확인한 공식 문서:

- [Introducing Google Antigravity 2.0](https://antigravity.google/blog/introducing-google-antigravity-2-0?app=antigravity)
- [Google Antigravity CLI](https://antigravity.google/blog/introducing-google-antigravity-cli?app=antigravity)
- [Antigravity CLI Overview](https://antigravity.google/docs/cli-overview)
- [Using AGY CLI](https://antigravity.google/docs/cli-using)
- [Antigravity Changelog](https://antigravity.google/changelog?app=antigravity)

Antigravity 2.0은 기존 IDE와 분리된 standalone 앱입니다. AGY CLI는 `agy` 명령을 쓰는 terminal-first surface이고, Antigravity 2.0과 같은 agent harness 및 핵심 설정을 공유합니다. CLI 설정 파일은 공식 문서 기준 `~/.gemini/antigravity-cli/settings.json` 입니다.

따라서 ClaudeUsage의 UX 기준은 다음입니다.

- Antigravity 2.0 앱 사용량과 AGY CLI 사용량을 별도 provider로 쪼개지 않습니다.
- CLI는 별도 quota 원장이 아니라 같은 Antigravity 계정 quota의 다른 surface로 봅니다.
- AGY CLI 로컬 상태 파일도, `agy` TUI의 `/usage` 화면도 usage source로 파싱하지 않습니다. TUI는 UI이지 API가 아니므로 quota 수치의 근거로 쓰지 않습니다. ClaudeUsage가 시작한 AGY도 구조화된 localhost RPC만 읽습니다.
- CLI 후보는 `ANTIGRAVITY_CLI_PATH`, `~/.local/bin/agy`, Homebrew 경로, 현재 프로세스의 절대 `PATH` 순으로 감지합니다. 로그인 셸이나 shell wrapper를 실행해 경로를 추측하지 않습니다.
- 후보는 regular Mach-O 파일, 현재 사용자 또는 root 소유, group/world 비쓰기 가능, 단일 hard link여야 하며 Google Developer ID 팀 `EQHXZ8M8AV`의 `cli` designated requirement를 충족해야 합니다.
- 검증된 CLI만 필요 시 자동 실행합니다. 실행 직전에는 같은 파일 identity와 정적 서명을 다시 확인하고, 실행 중 프로세스도 동적 code requirement로 확인합니다.
- Windows는 현재 제품 요구사항에서 제외합니다.

## 2. 설계 기준

- 사용자는 조회할 제품을 선택합니다. 로그인 계정은 해당 제품의 인증된 응답에서 확인합니다.
- 조회 전후의 identity가 같아야 수치를 표시합니다. 선택한 제품이 실패해도 다른 제품으로 넘어가지 않습니다.
- 프로세스·서명·포트 소유권과 계정 경계는 각각 검증합니다.
- 백그라운드 조회는 브라우저 로그인이나 Keychain 인증을 요청하지 않습니다.
- Google OAuth 연결·원격 조회는 제공하지 않습니다. 숫자 quota가 없는 연결을 수치 조회의 대안으로 안내하지 않습니다.
- Antigravity IDE는 지원 범위에 포함하지 않습니다.

## 3. 조회 대상과 현재 로그인 계정

사용자가 선택하는 값은 `AGY CLI` 또는 `Antigravity 독립 앱`입니다. 앱에서 Google 로그인이나 CLI 계정 전환을 대신 수행하지 않습니다.

- CLI: 검증된 실행 중 AGY를 확인하고, 사용할 연결이 없으면 검증된 managed AGY를 사용합니다.
- 독립 앱: 해당 앱의 검증된 language server만 조회합니다. 앱이 꺼져 있거나 조회가 실패해도 CLI로 전환하지 않습니다.
- 미선택: 조회하지 않고 사용할 제품을 안내합니다. Antigravity IDE는 선택지에 포함하지 않습니다.

로그인 계정을 저장해 고정하지 않습니다. 선택한 제품에서 로그인한 계정이 바뀌면 이후 인증된 조회 결과의 계정과 수치를 함께 반영합니다. 수동 새로고침은 프로세스를 재탐색하고 managed CLI 인증을 재확인합니다. 정상 정기 조회는 현재 실행 세션을 재사용합니다.

하나의 제품에 서로 다른 계정의 실행이 동시에 있거나 일부 연결의 계정을 확인할 수 없으면 실행 순서로 계정을 고르지 않습니다. 이전 실행을 종료하고 새로고침하도록 안내합니다. 두 계정의 사용량을 합산하지 않습니다.

`GetUserStatus` → quota RPC → identity 확인 순서로 한 요청의 계정 경계를 검증합니다. 도중 계정이 바뀌면 남은 전체 시간 안에서 한 번만 다시 조회합니다. 변경이 반복되면 이전 수치를 숨깁니다. 새로운 계정이 확인된 뒤 quota 요청이 실패해도 이전 계정의 수치를 유지하지 않습니다. 같은 계정의 일시적 통신 실패에는 마지막 값과 확인 시각을 stale로 유지합니다.

`AntigravityConnectionSettings` schema v4는 managed 정책과 `usageTarget`만 저장합니다. 계정 주소, provider subject, PID, 포트, 인증 토큰을 조회 대상 설정에 넣지 않습니다. 화면에는 현재 조회의 로그인 계정을 표시하고, stale 데이터에는 ‘마지막 확인 계정’으로 구분합니다.

연결 설정 v1·v2·v3는 현재 형식으로 직접 이전합니다. 과거 선택한 이메일만으로 제품을 추측하지 않으며, 대상이 불명확하면 제품을 한 번 선택하도록 안내합니다. 이전의 명시적인 `agy_cli` 선택은 CLI로 보존하고, 신규 설치는 CLI로 시작합니다. 쓰기·read-back 검증 뒤에만 완료 marker를 올리고 실패하면 이전 설정을 복구합니다. 기존 자격증명과 표시 설정은 임의 삭제하지 않습니다.

검증된 AGY가 없거나 서명이 거부되면 실행하지 않습니다. managed AGY는 기본 180초 idle timeout 뒤 앱 소유 process tree만 정리하며 외부 프로세스는 종료하지 않습니다. 수치는 인증된 localhost RPC 응답에서만 읽으며 TUI를 파싱하지 않습니다.

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

### AGY CLI 연결 인증

- managed AGY는 매 실행마다 암호학적 난수 토큰을 만들고 공식 CLI가 받아들이는 `--csrf_token` 시작 인자로 전달합니다. 동일 토큰을 HTTPS 준비 확인, quota·identity RPC의 `X-Codeium-Csrf-Token` 헤더와 연결 재검증에 사용합니다.
- 토큰은 검증된 실행 파일·PID·시작 시각에 묶인 메모리 registry에서만 조회합니다. 정리·격리 시 제거하며, RPC 전후에 같은 프로세스의 포트 소유권과 등록 토큰을 확인합니다. 복구 원장·UserDefaults·로그·진단에는 저장하지 않습니다.
- borrowed AGY는 검증한 해당 프로세스의 명령행 토큰만 사용합니다. 토큰 없이 정상 응답하는 기존 CLI는 `cliTokenless`로 유지합니다. CSRF가 필요한데 토큰을 확보하지 못하면 `unavailable` 원인을 보존하고 다음 허용 소스로 넘어갑니다. 외부 프로세스는 종료하지 않습니다.
- 정확한 401 Connect 오류의 `missing CSRF token` / `invalid CSRF token`은 Google 로그인 실패와 별도의 고정 오류 코드로 분류합니다. 원문 응답은 기록하지 않으며 readiness에서 계속 재시도해 timeout으로 바꾸지 않습니다.
- 자동 조회에서 CSRF가 거부되면 owned 세션을 최대 한 번 재생성합니다. 수동 새로고침·재시도·계정 경계 변경은 외부 AGY 로그인 변경을 반영하기 위해 기존 owned 세션을 새로 만들며, 이것도 같은 한 번의 예산을 사용합니다. 정상 자동 조회는 기존 세션을 재사용합니다.
- 인증 복구 후에도 조회 전후 identity를 대조합니다. 같은 조회에서 서로 다른 계정이 확인되면 이전 값을 숨깁니다. 계정 변경이 확인되지 않은 일시적 CSRF 실패는 마지막 성공 값과 시각을 stale로 유지합니다.
- 외부 CLI의 로그인 변경은 명시적 새로고침에서 재확인합니다. 인증 파일 감시나 OAuth 저장 형식 변경은 추가하지 않습니다.

인증 계약 검증은 격리한 동일 프로세스에서 헤더 없음→401, 올바른 헤더→인증된 identity와 숫자 quota, 다른 헤더→401을 확인합니다. CLI 버전이나 실행 파일 해시를 제품의 고정 허용 목록으로 사용하지 않습니다.

## 5. Google 연결 제거와 이전 데이터

2.5.1부터 Google 로그인, OAuth client 탐색, 원격 quota 요청, 토큰 갱신 경로를 제거합니다. 조회 요청·응답 타입에 OAuth 자격증명을 전달하지 않으며, 조회 coordinator는 자격증명을 읽거나 갱신할 수 없습니다.

이전 계정 메타데이터는 로그인 선택 UI에 사용하지 않습니다. 어느 제품을 조회할지 분명하지 않은 구버전 설정은 조회 대상을 한 번 선택하도록 안내합니다.

기존 계정 메타데이터와 자격증명은 임의 삭제하지 않습니다. 구형 저장본의 이전·복구·명시적 삭제에 필요한 저장소 코드는 유지합니다. 고급 진단의 ‘이전 연결 정보 삭제’는 이 자료만 정리하며 현재 조회 대상이나 외부 앱·CLI의 로그인을 변경하지 않습니다.

## 6. 저장소와 Keychain 정책

현재 runtime은 조회 선택, 계정 메타데이터, 자격증명을 분리합니다.

- 조회 대상·표시 설정: 채널별 UserDefaults의 typed Antigravity 설정
- 계정 메타데이터·원장: 채널별 Application Support의 `Antigravity` 디렉터리
- 이전 버전의 Google OAuth 자격증명: 앱 bundle identifier를 service로 사용하는 Security.framework vault의 `oauth.antigravity.v2.<uuid>` 참조
- managed CSRF: 메모리 전용이며 계정 저장소·원장에 기록하지 않음

운영과 staging은 각자의 앱 식별자와 저장 경로를 사용합니다. managed 실행 잠금만 공용 경로를 사용합니다. 조회 대상을 선택해도 OAuth 자격증명을 새로 만들거나 연결을 요구하지 않습니다.

이전 `oauth_creds.json`, `oauth_accounts.json`, 과거 Keychain 항목은 migration 입력입니다. 기존 자료를 읽고 정본 저장·read-back을 검증한 뒤 해당 이전 자료만 정리합니다. 권한·자료 충돌·손상이 있으면 원본을 보존하고 필요한 동작을 안내합니다. 무인 조회에서 인증 창을 반복 요청하지 않으며, 대화형 이전은 사용자 동작으로 진행합니다.

2.5.1은 이 OAuth 자격증명 저장 형식을 변경하지 않습니다. 새 조회 대상 설정은 제품 구분만 저장합니다.

## 7. 설정 UX 기준

설정 화면은 아래 상태를 분리해서 보여줘야 합니다.

- 조회 대상: CLI 또는 독립 앱. 선택은 조회 실패·앱 재실행에도 유지
- 로그인 계정: 선택한 제품에서 확인한 계정의 읽기 전용 표시
- 로컬 앱 상태: 실행 중, 연결 가능, token/port 누락, 첫 성공 조회 여부
- CLI 상태: 검증된 실행 파일 경로, 미감지, Google 서명 거부, 복구 실패
- 이전 연결 정보: 고급 진단에서 명시적으로 삭제 가능
- 표시 설정: standard/compact 다중 lane 선택, 메뉴바 단일 lane 선택

표시 원칙:

- 로컬 앱이 실행 중이어도 quota window가 없으면 0%처럼 보이면 안 됩니다.
- quota 모델은 감지됐지만 usage fraction이 없으면 100%처럼 보이면 안 됩니다.
- quota가 없고 identity만 있으면 메뉴바 숫자 대신 `!` 상태 마커를 표시하고, 팝오버/설정에서는 `계정 확인됨 · 수치 미지원` 계열 문구로 보여줍니다.
- 후보 경로의 `agy`가 Google 서명 검증에 실패하면 자동 실행을 막고 `감지됐지만 Google 서명 검증 실패`로 보여줍니다.
- CLI가 없어도 실행 중인 로컬 앱에서 조회할 수 있습니다.
- 조회 대상 변경은 이전 데이터를 즉시 숨기고 새 선택 저장 후 조회합니다. 저장 중에는 정기 조회가 이전 선택을 다시 읽지 않으며, 저장 후 같은 대상의 정기 조회가 시작돼도 선택 취소 오류로 처리하지 않습니다.
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
- `AntigravityQuotaPresentationMapperTests`: lane grouping, 미지원/불가 값, multi-lane 정렬, menu bar single lane, freshness
- `AntigravityQuotaPresentationRenderingTests`: standard/compact 실제 렌더 폭, 다중 lane, 합성 0% 방지
- `AntigravityRefreshCoordinatorTests`, `AntigravityRuntimeControllerTests`: 계정/세션 경계, stale 응답 차단, display mutation 직렬화
- `AntigravityAccountRepositoryTests`, `AntigravityMigrationCoordinatorTests`: vault write/read-back, 잔여 데이터 제거
- `AntigravityDisplaySettingsV2MigrationTests`, `AntigravitySettingsMigrationCoordinatorTests`: display schema v1→v2, 구 UserDefaults 이전, rollback/marker 순서, idle timeout 보존, generic Antigravity 키 제거
- `AntigravityDisplayAdapterTests`, `ProviderDisplayArchitectureTests`: known/unknown/unavailable lane, all-hidden, 1~6 compact row, Claude/Codex preference persistence, adapter status contract
- `AntigravityDiscoverySecurityTests`, `AntigravityManagedCLI*Tests`, `AntigravityManagedProcessTreeTests`: 실행 image 신뢰, managed lifecycle, idle teardown
- `AntigravityOAuthCredentialsStoreTests`: file-only status/load, legacy Keychain no-UI migration/delete
- `AntigravityOAuthAccountStoreTests`: multi-account active credential 동기화
- `ProviderEnvironmentDetectorTests`, `RuntimeProviderSettingsPresentationTests`, `PopoverViewModelTests`: 자동 조회 readiness 해석과 lane 경계

원격 endpoint가 private/internal 성격이므로 “실패하지 않는다”보다 “응답 shape 변화가 어디에서 깨졌는지 빠르게 드러난다”가 테스트의 목적입니다.

## 9. 운영 리스크

- Antigravity 2.0/CLI는 출시 직후라 binary name, flag, endpoint response shape가 바뀔 수 있습니다.
- local language server port와 CSRF token은 재시작 때 바뀝니다. stale cache가 의심되면 `AntigravityStatusProbe.invalidateCache()` 경로와 retry를 먼저 확인합니다.
- AGY CLI 설정 파일은 공식 문서상 JSON 파일입니다. 설정 내용을 임의로 수정하지 말고, 존재 여부와 경로 상태만 UX에 노출합니다.

## 10. 실제 AGY 회귀 검증

- AGY는 명령행에 quota RPC 포트를 노출하지 않으면서 동일 PID에서 복수의
  loopback listener를 열 수 있습니다. AGY 1.1.8에서는 HTTPS(gRPC)와
  plaintext HTTP listener가 연속 포트로 함께 열리므로, managed launcher는
  공식 `--log-file /dev/stderr` 옵션으로 자기 PTY에 나온 HTTPS bootstrap
  공지를 typed port로 파싱합니다. exact PID, 실행 파일, 사용자, 포트 소유권과
  실제 RPC 응답을 모두 검증한 뒤 그 포트만 사용하며, sibling HTTP listener를
  TLS로 추측해서 probe하지 않습니다.
- bootstrap log와 TUI가 PTY buffer를 채워 AGY의 RPC 처리까지 막지 않도록
  readiness 전 과정과 warm session 수명 동안 PTY를 계속 bounded drain합니다.
  raw 출력은 로그나 진단으로 노출하지 않고 typed interaction, announced port,
  truncation 상태만 유지합니다.
- managed readiness는 socket/RPC 초기화만으로 끝나지 않습니다. AGY는 keyring
  인증이 비동기로 끝나기 전에도 `GetUserStatus`에 HTTP 200을 반환하므로,
  readiness probe는 응답에서 계정 identity(email)가 디코드될 때까지 시작
  예산 안에서 재시도합니다. 진짜 로그아웃 상태는 PTY의 blocking
  login prompt 분류가 `loginRequired`로 별도 차단하며, identity가 끝내
  나타나지 않으면 인증 복원이 필요하다는 원인으로 실패합니다.
- managed 원장의 `incomplete` 관찰 기록은 신호 권한이 없지만, 기록된
  실행(owner/root child/observed descendants)이 전부 notFound이거나 PID
  재활용(kernel uniqueID 불일치)으로 확실히 죽었음이 증명되면 startup
  recovery가 stale로 정리합니다. ambiguous(unavailable 조회, uniqueID
  일치 생존)는 기존대로 차단을 유지하고, 그 차단은 로그인 안내가 아니라
  `managedRecoveryBlocked` setup 상태("이전 AGY 실행 정리 필요")로
  표시합니다.
- managed launch의 `posix_spawn`은 `ETXTBSY`(자동 업데이트로 인한 바이너리
  교체 중)에 한해 짧게 재시도하고, 다른 실패는 첫 시도에서 fail-closed를
  유지합니다. 재시도 성공 경로도 동일한 catalog 재검증과 kernel image 검증을
  통과해야 합니다. 환경변수는 계속 명시적 화이트리스트만 전달합니다. AGY
  인증 복원에 필요한 명시적인 환경변수만 전달하며, 변경 시 실제 로그인된 CLI로 검증합니다.
- `AntigravityLiveAGYIntegrationTests`는 opt-in 테스트입니다. 설치되고 로그인된
  공식 AGY를 production launcher로 실행해 HTTPS bootstrap port를 먼저 확인하고
  원본 grouped quota를 받은 뒤,
  Gemini와 Claude·GPT에 서버가 실제 제공한 quota가 숫자이며 지원되는 주기인지 확인하고
  local app → borrowed CLI → managed CLI 자동 조회 coordinator까지 검증합니다.
- live 게이트는 모든 계정에 같은 종류·개수의 quota가 존재한다고 가정하지 않습니다. 없는 quota를 0%로 합성하지 않으며, 주기별 decode·렌더링은 fixture 테스트로 검증합니다.
- 실제 계정 변경 검증은 `testUserDrivenAccountSwitchAtoBtoA`를 별도 실행합니다. `CLAUDEUSAGE_AGY_ACCOUNT_SWITCH_GATE`의 임시 디렉터리에서 `A1.ready`, `B.continue`/`B.ready`, `A2.continue`/`A2.ready` 마커만 교환하고 로그인은 사용자가 수행합니다. identity는 메모리에서만 비교하며 마커/로그에는 계정 주소나 토큰을 쓰지 않습니다.
- 통합 `Scripts/release.sh`는 전체 XCTest 직후 필수 live 테스트(인증된 quota, 격리 실행 파일 교체, OAuth 없는 로컬 선택·저장·세션 재사용)를 직접 실행합니다.
  XCTest의 skip 결과만으로는 AGY 배포 게이트를 통과한 것으로 보지 않습니다.

## 실행 파일 업데이트와 조회 복구

- `AntigravityRuntimeEnvironment`가 로컬 실행 구성을 관리합니다. 조회마다 경로·파일 메타데이터를 확인하고, 변경 시에만 공식 서명·권한·파일 동일성을 다시 검증합니다.
- 각 조회는 하나의 로컬 구성을 끝까지 사용합니다. 교체 시 기존 조회 종료와 app-owned 세션 정리를 기다리며, 정리가 확인되지 않으면 managed 실행을 차단하고 기록을 유지합니다. 계정 저장소·OAuth 자격증명은 재생성하지 않습니다.
- 앱 실행 후 AGY를 설치하거나 같은 경로에서 업데이트해도 다음 조회에서 반영합니다. 검증 도중 변경된 파일과 늦게 완료된 검증 결과는 사용하지 않습니다.
- 성공한 프로세스 탐색 캐시는 30초 동안 유지하되 매번 PID·실행 파일·포트 소유권을 재검증합니다. 수동 새로고침·재시도·계정 변경은 캐시를 우회하며 일반 자동 요청에 병합되지 않습니다.
- 설정·팝오버는 실행 파일 없음/변경/검증 거부/정리 차단과 인증·시간 초과·응답 형식 오류를 구분합니다. 고급 진단에는 secret-free 원인 코드와 조회 시각을 표시합니다. 실패 시 마지막 성공 데이터는 stale로 유지하되 다른 계정의 값은 표시하지 않습니다.
- 설치 파일 검증 시간은 전체 조회 시간에 포함됩니다. 검증 후 로컬 탐색에는 남은 전체 시간 안에서 최대 2초를 배정합니다.
- Antigravity IDE는 이번 지원 범위에 포함하지 않습니다. 독립 앱과 CLI의 조회 경로를 분리하고 선택한 제품의 현재 로그인만 표시합니다.
- `AntigravityLiveAGYIntegrationTests/testRuntimeEnvironmentRecoversAfterOfficialBinaryReplacement`는 격리한 공식 AGY 복사본을 같은 경로의 새 inode로 교체하고 실제 quota 재조회를 검증합니다. 사용 중인 AGY 파일은 변경하지 않습니다.
- 통합 릴리스 게이트는 실제 managed quota 조회, 파일 교체 후 quota 재조회, 조회 대상 저장·현재 로그인·재사용 검사를 각각 완료합니다. 인증 완료 전에 종료하는 포트 전용 진단은 릴리스 게이트에서 실행하지 않습니다.
