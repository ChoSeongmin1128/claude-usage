# Antigravity 연결과 사용량 조회

ClaudeUsage는 AGY CLI의 공식 사용량 보고로 Google Antigravity quota를 로컬에서 조회합니다.

## 지원 대상

- [Google Antigravity CLI](https://antigravity.google/blog/introducing-google-antigravity-cli?app=antigravity)
- [Antigravity CLI 문서](https://antigravity.google/docs/cli/overview)

2.10.0부터 AGY CLI만 조회합니다. Antigravity 2.0 독립 앱은 기계로 읽을 수 있는 공식 사용량 경로가 없어 조회하지 않으며, 이전 버전에서 독립 앱을 고른 설정은 AGY CLI로 바뀝니다. Antigravity IDE는 지원하지 않습니다.

Google 계정 연결이나 별도 OAuth 로그인은 제공하지 않습니다. 로그인 변경은 AGY CLI에서 직접 수행한 뒤 ClaudeUsage를 새로고침합니다. 설치는 `curl -fsSL https://antigravity.google/cli/install.sh | bash`로 하고, 설치 뒤 `agy`를 실행해 로그인합니다.

## 조회 방식

### AGY CLI

조회할 때마다 공식 AGY의 사용량 보고(`agy -p /usage --output-format json`)를 낮은 우선순위로 한 번 실행합니다. 이 보고는 모델을 호출하지 않아 quota를 쓰지 않으며, 실행한 AGY는 보고와 함께 종료됩니다. 조회 사이에 ClaudeUsage가 AGY를 계속 실행해 두지 않습니다.

- AGY CLI 1.1.11 이상이 필요합니다. 그 이전 버전은 이 요청을 모델 프롬프트로 처리하므로 ClaudeUsage가 요청하지 않습니다.
- 보고에는 계정 정보가 없습니다. 표시되는 사용량은 CLI에 현재 로그인한 계정의 것이며, 로그인 계정은 `AGY CLI 로그인 계정`으로 표시합니다. CLI에서 로그인을 바꾸면 다음 조회부터 새 계정의 사용량이 표시됩니다.
- 백그라운드 조회는 브라우저 로그인 창을 열지 않고, AGY에 명령 이름으로 등록한 MCP 서버도 실행하지 않습니다.
- 사용자가 터미널에서 실행 중인 AGY 세션은 조회하거나 종료하지 않습니다.

### 공통

Antigravity의 설정 파일이나 대화형 TUI 화면은 사용량 자료로 파싱하지 않습니다.

계정에 따라 quota 종류와 주기가 다를 수 있습니다. 응답에 없는 quota를 0%나 100%로 만들지 않으며, 계정만 확인되고 숫자 사용량이 없으면 수치 미지원 상태로 표시합니다. 일시적인 조회 실패에는 마지막 성공 값과 확인 시각을 이전 값으로 유지합니다.

## 실행 파일과 프로세스 보호

AGY CLI는 Google이 서명한 정규 실행 파일인지, 파일 권한과 소유권이 안전한지 확인한 뒤 사용합니다. 실행 직전에 같은 파일인지 다시 확인하고, 실행된 이미지가 검증한 파일과 같은지 확인한 뒤에만 AGY 코드가 실행됩니다. 실행 파일이 설치·업데이트·교체되면 다음 조회에서 다시 검증하며 ClaudeUsage를 재시작할 필요가 없습니다.

사용량 보고는 전용 프로세스 그룹에서 실행하고, 끝나거나 제한 시간을 넘기면 그 그룹만 정리합니다. 사용자가 실행한 AGY나 Antigravity 앱은 종료하지 않습니다.

이전 버전이 실행해 둔 AGY 기록이 남아 있으면 시작할 때 한 번 정리합니다. 이 정리가 끝나지 않아도 조회는 막히지 않습니다.

## 인증과 개인정보

UserDefaults, Application Support, 로그와 진단 화면에는 토큰이나 원본 인증 응답을 저장하지 않습니다. AGY CLI 사용량 보고는 AGY가 스스로 로그인 정보를 읽으며, ClaudeUsage는 CLI 자격증명을 읽지 않습니다.

## 문제 해결

1. 터미널에서 `agy`를 실행해 로그인 상태를 확인합니다.
2. 수동 새로고침으로 사용량을 다시 확인합니다.
3. CLI가 감지되지 않으면 공식 AGY 설치 경로와 실행 파일 서명을 확인합니다.
4. `AGY CLI 업데이트 필요`가 표시되면 AGY CLI를 1.1.11 이상으로 업데이트합니다.
5. `AGY 사용량 보고 실패`가 표시되면 AGY CLI의 로그인 상태를 확인한 뒤 다시 시도합니다. AGY CLI가 로그아웃되어 있으면 보고가 응답하지 않아 이 상태가 됩니다. 이때는 다른 계정의 것일 수 있는 이전 사용량을 표시하지 않습니다.
6. `AGY 사용량 보고 중지`가 표시되면 AGY가 사용량 보고 대신 모델 응답을 실행한 것입니다. quota가 더 쓰이지 않도록 자동 조회를 멈추며, AGY CLI가 업데이트되거나 ClaudeUsage를 다시 실행하면 다시 조회합니다. 모델 응답 흔적이 없는 예상 밖 응답은 형식 변경으로 표시하고 다음 조회에서 다시 시도합니다.
