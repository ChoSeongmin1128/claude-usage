# Claude 인증 및 사용량 소스

최종 갱신: 2026-04-02

이 문서는 현재 `ClaudeUsage`가 Claude 인증과 사용량 조회를 어떤 경로로 다루는지 정리한 문서입니다.

## 1. 인증 경로

Claude는 한 가지 자격만 쓰지 않습니다. 앱은 아래 경로를 함께 다룹니다.

### Claude Code CLI OAuth

가장 권장하는 경로입니다.

- 설치: `brew install --cask claude-code`
- 로그인: `claude login`
- 앱 반영: `설정 > Claude > 인증 > 상태 새로고침`

이 경로를 권장하는 이유는 단순합니다.

- sessionKey보다 장기적으로 안정적입니다.
- Claude Code가 이미 profile metadata를 같이 제공할 수 있습니다.
- 앱이 `organizationUuid`, `subscriptionType`, `rateLimitTier`, `hasExtraUsageEnabled`를 읽는 데 유리합니다.

### Chrome 가져오기

일반 사용자 기본 경로입니다.

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

## 5. 왜 CLI OAuth를 권장하는가

현재 앱은 sessionKey 경로를 계속 지원합니다. 그런데 아래 조건에서는 CLI OAuth를 같이 준비하는 편이 맞습니다.

- sessionKey 경로가 불안정함
- 세션 경로 실패율이 높음
- `Cloudflare`, `429`, 일시적 서버 오류가 잦음
- 장기적으로 `organization` / `subscription` metadata까지 안정적으로 보고 싶음

즉, sessionKey는 버리는 게 아니라 `함께 유지`하되, OAuth를 추가로 준비해서 복원력과 메타데이터 품질을 높이는 구조입니다.

## 6. 사용자 입장에서 추천 순서

1. `Claude Code CLI OAuth`
2. `Chrome 가져오기`
3. `웹 로그인`
4. `수동 sessionKey`

이 순서가 현재 제품 기준으로 가장 덜 불안정합니다.
