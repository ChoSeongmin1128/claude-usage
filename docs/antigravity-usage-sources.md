# Antigravity 사용량 소스와 설정 UX

최종 갱신: 2026-05-20

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
- AGY CLI 로컬 상태 파일은 usage source로 파싱하지 않습니다. `ccusage` 최신 문서도 Antigravity CLI의 `~/.gemini/antigravity-cli` 로컬 파일이 readable token usage나 per-turn accounting을 안정적으로 제공하지 않는다고 보고 있습니다.
- CLI 감지는 `agy` 실행 파일, `~/.gemini/antigravity-cli` 상태 디렉터리, `settings.json` 존재 여부를 분리해서 표시합니다.
- `agy` 명령은 PATH에 있어도 shell wrapper가 사라진 bundle 내부 경로를 가리킬 수 있습니다. ClaudeUsage는 wrapper target을 정적으로 확인해 깨진 CLI를 정상 CLI로 표시하지 않습니다.
- Windows는 현재 제품 요구사항에서 제외합니다.

## 2. CodexBar 기준에서 가져온 판단

CodexBar 최신 구현은 Antigravity에 대해 로컬 language server probe와 Google OAuth 원격 usage를 모두 둡니다. multi-account는 token-account 값으로 `AntigravityOAuthCredentials` JSON을 저장하고, 원격 fetch에는 `ANTIGRAVITY_OAUTH_CREDENTIALS_JSON` 환경 주입을 씁니다.

ClaudeUsage는 CodexBar와 호환을 목표로 하지 않습니다. 대신 아래 판단만 제품 방향으로 가져옵니다.

- Antigravity OAuth 토큰은 Keychain 전제보다 파일 기반 로컬 계정 저장이 사용성 측면에서 낫습니다.
- Keychain prompt를 refresh 경로에 섞으면 메뉴바 앱의 백그라운드 갱신 UX가 나빠집니다.
- 여러 Google 계정 전환은 provider 설정 UX 안에서 명시적으로 다룹니다.
- 로컬 앱 API가 quota window를 주지 않는 경우가 있으므로 원격 OAuth path가 필요합니다.
- Google Cloud Code Assist 계열 원격 endpoint는 공개 안정 API가 아니므로 parser/request 코드는 테스트로 방어해야 합니다.

## 3. 데이터 소스 모드

Antigravity 설정은 세 가지 모드를 가집니다.

| 모드 | 동작 | 사용자에게 맞는 경우 |
|---|---|---|
| `자동` | 로컬 앱 API를 먼저 조회하고, 실패하거나 quota window가 없으면 Google OAuth 원격 조회로 보완 | 대부분의 사용자 |
| `로컬 앱` | 실행 중인 Antigravity 2.0 language server만 조회 | OAuth 연결 없이 앱 상태만 보고 싶은 경우 |
| `Google OAuth` | ClaudeUsage에 연결한 Google OAuth 계정으로 원격 quota만 조회 | CLI/원격 작업 중심이거나 Antigravity 앱이 꺼져 있어도 quota를 보고 싶은 경우 |

자동 모드에서 로컬 API가 성공했지만 quota window가 비어 있으면 identity-only 결과로 바로 확정하지 않습니다. 먼저 원격 OAuth로 보완하고, 원격도 실패하면 로컬 identity-only 결과를 유지합니다.

## 4. 로컬 앱 조회

책임 분리:

- `AntigravityStatusProbe`: 프로세스 탐지, 캐시, 2.0 language server 명령 판별
- `AntigravityAPIService`: endpoint 후보 구성, local HTTP/HTTPS 요청, retry
- `AntigravityLocalUsageParsing`: 로컬 응답 DTO와 quota 파싱
- `AntigravityUsageMapper`: 모델 quota를 primary/secondary/tertiary usage window로 정규화

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
- `AntigravityRemoteUsageService`: token refresh, project resolve, quota endpoint 호출
- `AntigravityRemoteUsageParsing`: 원격 응답 DTO와 quota/plan 파싱

원격 endpoint:

- `POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`
- `POST https://cloudcode-pa.googleapis.com/v1internal:onboardUser`
- `POST https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels`
- `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`

원격 조회는 Google OAuth access token을 사용합니다. access token이 없거나 만료 임박이면 refresh token으로 갱신합니다. project ID가 없으면 `loadCodeAssist` 응답, `onboardUser`, 재조회 순서로 project ID를 보완하고, 찾은 값은 credentials에 저장합니다. OAuth client secret은 Antigravity bundle 내부 형식이 바뀔 수 있으므로 `GOCSPX-` 접두사 뒤 길이를 고정하지 않습니다.

`fetchAvailableModels` 가 403이거나, 200 응답이지만 usable usage fraction을 주지 않으면 `retrieveUserQuota` 를 fallback으로 시도합니다. 둘 다 403이면 인증 자체가 깨진 것으로 보지 않고 identity-only 상태를 허용합니다. 401은 재로그인이 필요한 인증 실패로 봅니다. `retrieveUserQuota` 가 비어 있거나 유효한 모델 bucket을 주지 않으면 정상 quota 없음으로 삼키지 않고 parse failure로 처리합니다. 이 fallback endpoint는 shape 변화가 생겼을 때 조용히 identity-only로 퇴행하면 문제를 늦게 발견하기 때문입니다.

모델 ID는 있지만 `remainingFraction` 이 없는 quota는 usage window로 만들지 않습니다. Antigravity 응답 shape가 바뀌어 사용량 값이 빠진 경우 0%/100% 같은 가짜 수치를 표시하지 않고, 계정/plan만 있는 `quota 정보 없음` 상태로 남깁니다.

OAuth 로그인 callback은 loopback server로만 받습니다. callback parser는 `GET`, `Host: 127.0.0.1:<port>`, `/callback` path, OAuth `state` 를 모두 확인합니다.

OAuth client 정보는 아래 순서로 찾습니다.

1. `ANTIGRAVITY_OAUTH_CLIENT_ID`, `ANTIGRAVITY_OAUTH_CLIENT_SECRET`
2. `/Applications/Antigravity.app/Contents/Resources/app/out/main.js`
3. `/Applications/Antigravity.app/Contents/Resources/bin/language_server`
4. 사용자 `~/Applications/Antigravity.app` 의 같은 경로

Antigravity 2.0 language server에는 같은 client ID에 여러 secret 후보가 들어 있을 수 있으므로 token refresh에서 같은 client ID의 secret 후보를 순서대로 재시도합니다.

## 6. 저장소와 Keychain 정책

Antigravity OAuth 저장 위치:

- active credential: `~/Library/Application Support/ClaudeUsage/Antigravity/oauth_creds.json`
- account list: `~/Library/Application Support/ClaudeUsage/Antigravity/oauth_accounts.json`
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

- 데이터 소스: `자동`, `로컬 앱`, `Google OAuth`
- 로컬 앱 상태: 실행 중, 연결 가능, token/port 누락, 첫 성공 조회 여부
- CLI 상태: `agy` 바이너리, 실행 가능 여부, 상태 디렉터리, `settings.json`
- OAuth 상태: 연결 여부, active Google account, 계정 추가/선택/해제
- 마지막 사용량 소스: 자동 모드에서 실제로 local/remote 중 무엇을 썼는지

표시 원칙:

- 로컬 앱이 실행 중이어도 quota window가 없으면 0%처럼 보이면 안 됩니다.
- quota 모델은 감지됐지만 usage fraction이 없으면 100%처럼 보이면 안 됩니다.
- quota가 없고 identity만 있으면 `연결` / `quota 정보 없음` 계열 문구로 보여줍니다.
- PATH의 `agy`가 없는 대상 파일을 가리키면 `CLI 복구 필요`로 보여주고, CLI 자체 사용량이 별도 source로 준비됐다고 표현하지 않습니다.
- CLI가 없어도 로컬 앱 API와 Google OAuth 원격 조회는 사용할 수 있습니다.
- `Google OAuth` 모드에서는 Antigravity 앱의 로그인 상태를 OAuth 준비 완료로 취급하지 않습니다. ClaudeUsage에 연결한 OAuth 계정이 있어야 합니다.
- `로컬 앱` 모드에서는 ClaudeUsage OAuth가 없어도 로컬 runtime만 기준으로 판단합니다.

## 8. 테스트 기준

Antigravity 쪽 변경은 최소 아래 범위의 테스트를 유지해야 합니다.

- `AntigravityStatusProbeTests`: 2.0 `language_server`, legacy binary, process priority, invalid port filtering
- `AntigravityLocalUsageParsingTests`: `GetUserStatus`, `GetCommandModelConfigs`, response code 처리
- `AntigravityRemoteUsageParsingTests`: plan, project, quota bucket, token claim parsing
- `AntigravityRemoteUsageServiceTests`: refresh, invalid client retry, project persistence, 401/403 처리
- `AntigravityRuntimeRefresherTests`: auto/local/remote mode fallback과 identity-only 보완
- `AntigravityOAuthCredentialsStoreTests`: file-only status/load, legacy Keychain no-UI migration/delete
- `AntigravityOAuthLoginRunnerTests`: loopback OAuth callback host/method/state 검증
- `AntigravityOAuthAccountStoreTests`: multi-account active credential 동기화
- `AntigravityOAuthSettingsViewModelTests`: login cancel, account add/select/disconnect UX 상태
- `ProviderEnvironmentDetectorTests`, `RuntimeProviderSettingsPresentationTests`, `PopoverViewModelTests`: data source별 readiness 해석

원격 endpoint가 private/internal 성격이므로 “실패하지 않는다”보다 “응답 shape 변화가 어디에서 깨졌는지 빠르게 드러난다”가 테스트의 목적입니다.

## 9. 운영 리스크

- Antigravity 2.0/CLI는 출시 직후라 binary name, flag, endpoint response shape가 바뀔 수 있습니다.
- Google Cloud Code Assist endpoint는 공개 안정 API가 아니므로 403/parse failure 증가 시 upstream 변경을 먼저 의심해야 합니다.
- OAuth client discovery는 설치된 Antigravity.app 내부 bundle에 의존합니다. 앱 bundle 구조가 바뀌면 환경변수 override가 우선 복구 수단입니다.
- local language server port와 CSRF token은 재시작 때 바뀝니다. stale cache가 의심되면 `AntigravityStatusProbe.invalidateCache()` 경로와 retry를 먼저 확인합니다.
- AGY CLI 설정 파일은 공식 문서상 JSON 파일입니다. 설정 내용을 임의로 수정하지 말고, 존재 여부와 경로 상태만 UX에 노출합니다.
