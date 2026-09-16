# Antigravity 연결과 사용량 조회

ClaudeUsage는 Google Antigravity 2.0 독립 앱과 AGY CLI의 현재 로그인 계정 및 quota를 로컬에서 조회합니다.

## 지원 대상

- [Google Antigravity 2.0](https://antigravity.google/blog/introducing-google-antigravity-2)
- [Google Antigravity CLI](https://antigravity.google/blog/introducing-google-antigravity-cli?app=antigravity)
- [Antigravity CLI 문서](https://antigravity.google/docs/cli/overview)

Antigravity 설정의 `조회 대상`에서 독립 앱 또는 AGY CLI를 선택합니다. 두 제품의 로그인이 다를 수 있으므로 ClaudeUsage가 자동으로 다른 제품으로 전환하지 않습니다. Antigravity IDE는 현재 지원하지 않습니다.

로그인 계정은 선택 메뉴가 아니라 해당 제품에서 확인한 현재 계정으로 표시합니다. 로그인 변경은 Antigravity 앱 또는 AGY CLI에서 직접 수행한 뒤 ClaudeUsage를 새로고침합니다.

Google 계정 연결이나 별도 OAuth 로그인은 제공하지 않습니다. 로컬 제품에서 인증된 숫자형 quota를 확인할 수 없는 계정은 사용량을 표시할 수 없습니다.

## 조회 방식

ClaudeUsage는 Antigravity의 설정 파일이나 TUI 화면을 사용량 자료로 파싱하지 않습니다. 검증된 로컬 프로세스의 구조화된 localhost RPC에서 계정 identity와 quota를 함께 확인합니다.

CLI를 선택하면 실행 중인 공식 AGY를 먼저 확인하고, 사용할 수 없을 때 ClaudeUsage가 검증한 AGY 세션을 시작할 수 있습니다. 독립 앱을 선택하면 해당 앱의 프로세스만 조회합니다. 선택한 제품에서 실패했다는 이유로 다른 제품의 계정이나 quota를 대신 표시하지 않습니다.

계정에 따라 quota 종류와 주기가 다를 수 있습니다. 응답에 없는 quota를 0%나 100%로 만들지 않으며, 계정만 확인되고 숫자 사용량이 없으면 수치 미지원 상태로 표시합니다.

## 실행 파일과 프로세스 보호

AGY CLI는 Google이 서명한 정규 실행 파일인지, 파일 권한과 소유권이 안전한지 확인한 뒤 사용합니다. 실행 파일이 설치·업데이트·교체되면 다음 조회에서 다시 검증하며 ClaudeUsage를 재시작할 필요가 없습니다.

ClaudeUsage가 시작한 프로세스만 정리합니다. 사용자가 실행한 AGY나 Antigravity 앱은 종료하지 않습니다. 프로세스·실행 파일·포트 소유권이 달라지면 기존 연결과 인증 정보를 재사용하지 않습니다.

## 인증과 개인정보

관리되는 AGY의 CSRF 토큰은 실행별로 만들고 메모리에만 보관합니다. UserDefaults, Application Support, 로그와 진단 화면에는 토큰이나 원본 인증 응답을 저장하지 않습니다.

조회 전후의 계정 identity를 비교합니다. 계정이 바뀌었거나 일치하지 않으면 이전 계정의 사용량을 즉시 숨깁니다. 일시적인 연결 실패에는 같은 계정의 마지막 성공 값과 확인 시각을 이전 값으로 유지합니다.

## 문제 해결

1. 선택한 Antigravity 제품에서 로그인이 완료됐는지 확인합니다.
2. ClaudeUsage 설정의 `조회 대상`이 로그인한 제품과 같은지 확인합니다.
3. 수동 새로고침으로 현재 계정과 quota를 다시 확인합니다.
4. CLI가 감지되지 않으면 공식 AGY 설치 경로와 실행 파일 서명을 확인합니다.
5. 검증 거부·이전 프로세스 정리 필요·CSRF 인증 실패는 일반 연결 실패와 구분해 표시하므로 안내된 원인을 먼저 해결합니다.

실행 중 업데이트나 계정 변경이 겹쳐도 한 번의 조회 안에서는 복구를 한 번만 시도하며 무한 재시작하지 않습니다. 같은 오류가 이어지면 표시된 원인을 확인한 뒤 다시 시도합니다.
