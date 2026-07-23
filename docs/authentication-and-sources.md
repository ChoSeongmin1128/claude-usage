# Claude 인증 및 사용량 소스

최종 갱신: 2026-07-23

이 문서는 현재 `ClaudeUsage`가 Claude 인증과 사용량 조회를 어떤 경로로 다루는지 정리한 문서입니다.
Antigravity의 로컬 앱, AGY CLI, Google OAuth 원격 quota 정책은 [Antigravity 사용량 소스와 설정 UX](antigravity-usage-sources.md)를 기준으로 합니다.

## 1. 인증 경로

Claude는 한 가지 자격만 쓰지 않습니다. 앱은 아래 경로를 함께 다룹니다.

### Claude Code CLI OAuth

가장 안정적인 경로입니다. 다만 앱 안에서 사용자가 처음 누르게 되는 기본 CTA는 아닙니다.

- 설치: `brew install --cask claude-code`
- 로그인: `claude auth login`
- 앱 반영: Claude Code 계정을 선택한 뒤 `Claude Code 다시 연결`
- 이전 버전에서 업데이트: 설정의 `Claude Code 연결 업데이트`

이 경로를 권장하는 이유는 단순합니다.

- sessionKey보다 장기적으로 안정적입니다.
- 자격이 만료됐거나 확인 실패 상태면 사용자는 `claude login` 을 다시 실행해 복구할 수 있습니다.
- Claude Code가 이미 profile metadata를 같이 제공할 수 있습니다.
- 앱이 `organizationUuid`, `subscriptionType`, `rateLimitTier`, `hasExtraUsageEnabled`를 읽는 데 유리합니다.

#### 자격 저장소와 Keychain 프롬프트 정책

Claude Code 2.1.x는 로그인하거나 OAuth token을 회전할 때 macOS Keychain만
갱신하고 `~/.claude/.credentials.json`은 이전 token을 가진 채 남길 수 있습니다.
따라서 파일이 존재한다는 이유만으로 항상 최신 자격으로 판단하지 않습니다.

- 앱 시작, 주기적 사용량 갱신, 계정 전환은 ClaudeUsage 앱 전용 vault와 자격
  파일만 읽으며 Claude Code 소유 Keychain을 조회하지 않습니다.
- 사용자가 `Claude Code 다시 연결`을 누른 경우에만 현재 config에 대응하는
  `Claude Code-credentials` 항목을 한 번 읽습니다.
- 이 명시적 연결에서는 자격 파일과 Keychain 후보의 만료 시각을 비교합니다.
  만료 시각이 같거나 Keychain 쪽이 더 늦으면 Claude Code의 현재 저장소인
  Keychain을 선택합니다.
- 선택한 자격에서는 Claude OAuth 필드만 Security.framework 기반 앱 전용
  vault에 복사하고, CLI mirror인지 앱이 관리하는 이전 credential인지 소유권을
  함께 기록합니다. Claude Code Keychain 항목과 CLI가 소유한 다른 credential은
  수정하거나 삭제하지 않습니다.
- 파일 기반 refresh가 필요한 경우에만 회전된 token lineage를 같은 파일에
  원자적으로 write-back합니다. Keychain에서 가져온 mirror는 앱이 독립적으로
  refresh하지 않습니다.
- 이전 버전에서 앱이 이미 refresh한 credential은 CLI mirror와 다른 lineage로
  표시해 새 vault에서 계속 갱신합니다. 오래된 CLI 파일이 이 credential을
  덮어쓰지 않습니다.

이 경계 때문에 `claude auth login` 직후에는 앱에서 `Claude Code 다시 연결`을
한 번 눌러야 할 수 있습니다. 이때 macOS 인증은 최대 한 번 발생할 수 있지만,
이후 앱 실행이나 브라우저/Claude Code 계정 전환은 Keychain UI 없이 동작해야
합니다.

#### 기존 사용자 업데이트 동작

- Chrome/웹 로그인 계정이 활성인 사용자는 업데이트만 하면 되며 Claude Code
  이전 안내나 macOS 인증이 표시되지 않습니다.
- 이전 ClaudeUsage 버전의 Claude Code cache가 있는 사용자는 Claude Code
  계정을 사용할 때 `Claude Code 연결 업데이트` 한 가지 행동만 보게 됩니다.
- 연결 업데이트는 같은 macOS 인증 context로 기존 정보 읽기, 새 vault 저장
  검증, 이전 정보 정리를 수행합니다. 정상 상태에서는 인증 창이 최대 한 번만
  표시됩니다.
- 사용자가 인증을 취소하면 같은 앱 실행 중에는 다시 요청하지 않습니다.
- 이전 credential이 이미 서버에서 폐기된 예외 상황에만 `claude auth login`
  후 `Claude Code 다시 연결`이 필요합니다.

### Chrome 가져오기

일반 사용자의 첫 시도 경로입니다.

- Chrome 로그인 상태에서 `claude.ai`의 `sessionKey` 쿠키를 자동 추출합니다.
- 앱은 Chrome `Cookies` DB를 임시 복사하고 `Safe Storage` 기반 복호화를 시도합니다.

이 경로는 편하지만, sessionKey 자체는 서비스 제한과 서버 상태의 영향을 더 많이 받습니다.

### 웹 로그인

Chrome 가져오기가 안 될 때의 보조 일반 경로입니다.

- 내장 로그인 창에서 `claude.ai` 로그인
- 쿠키와 Web Storage에서 `sessionKey` 자동 추출

### 수동 sessionKey

마지막 수단입니다.

- 고급 설정에서 `sessionKey` 값만 직접 입력
- 전체 쿠키 문자열이 아니라 값만 붙여넣어야 합니다

## 2. 사용량 조회 소스

Claude 사용량은 아래 소스를 함께 가집니다.

### Web session

- `claude.ai/organizations/.../usage`
- sessionKey 기반

### OAuth

- `https://api.anthropic.com/api/oauth/usage`
- Claude Code OAuth 토큰 기반

### Messages header fallback

보조 복구용입니다.

- `v1/messages` 최소 요청을 보냅니다
- rate-limit 헤더를 읽어 현재/주간 사용률을 복구합니다
- 기본 polling 경로를 대체하는 용도가 아닙니다

## 3. 현재 소스 정책

- `Web(sessionKey/cookie)`와 `OAuth`를 모두 주경로로 취급합니다
- sessionKey는 제거 대상이 아닙니다
- 다만 세션 경로가 불안정할 때는 `Claude Code CLI OAuth`를 함께 준비하는 방향을 권장합니다

## 4. 보조 사용량 복구 정책

앱 설정의 `보조 사용량 복구`는 아래 세 모드를 가집니다.

### 끄기

- 복구 기능을 사용하지 않습니다

### 수동 보조

- 사용자가 `Messages 헤더 복구 테스트`를 직접 실행합니다
- 자동 호출은 하지 않습니다

### 자동 보조

- OAuth 사용량 조회 실패 시에만 자동 시도합니다
- `자동 중지 기준`보다 현재 사용량이 낮으면 시도하지 않습니다
- 기본 임계값은 `20%`입니다

## 5. 갱신 예상 시각과 알림 정책

Claude의 `resets_at` 값은 정각 고정 리셋 시간이 아니라 API가 알려주는 현재 사용량 창의 `갱신 예상 시각`으로 취급합니다. 이 값이 움직이는 것만으로 세션이 리셋됐다고 판단하지 않습니다.

- 일반 표시 문구는 `갱신 예상` 기준으로 표시합니다.
- compact 메뉴바 표시는 기존처럼 짧은 시간 표시를 유지합니다.
- 임계값 알림은 `resetAt` 변경이 아니라 사용률이 임계값을 넘는 상태 전이 기준으로 보냅니다.
- 앱 첫 조회에서 이미 임계값을 넘은 상태면 즉시 알림을 보내지 않고, 이후 사용률이 내려갔다가 다시 넘을 때만 재알림합니다.
- 재알림은 사용률이 임계값보다 5%p 이상 낮아진 뒤 다시 넘을 때 허용합니다.

## 6. 왜 CLI OAuth를 권장하는가

현재 앱은 sessionKey 경로를 계속 지원합니다. 그런데 아래 조건에서는 CLI OAuth를 같이 준비하는 편이 맞습니다.

- sessionKey 경로가 불안정함
- 세션 경로 실패율이 높음
- `Cloudflare`, `429`, 일시적 서버 오류가 잦음
- 장기적으로 `organization` / `subscription` metadata까지 안정적으로 보고 싶음

즉, sessionKey는 버리는 게 아니라 `함께 유지`하되, OAuth를 추가로 준비해서 복원력과 메타데이터 품질을 높이는 구조입니다.

## 7. 사용자 입장에서 추천 순서

앱 안에서 처음 시도할 순서:

1. `Chrome 가져오기`
2. `웹 로그인`
3. `수동 sessionKey`

장기적으로 권장하는 안정성 순서:

1. `Claude Code CLI OAuth`
2. `Chrome 가져오기`
3. `웹 로그인`
4. `수동 sessionKey`

즉, 앱 UI의 첫 행동과 장기 운영 기준의 권장 경로는 다릅니다. 첫 행동은 `Chrome 가져오기`, 가장 안정적인 운영 경로는 `CLI OAuth`입니다.
