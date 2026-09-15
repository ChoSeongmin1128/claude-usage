# ClaudeUsage 유지보수 인계

최종 갱신: 2026-09-15

## 현재 배포 상태

- 저장소: `ChoSeongmin1128/claude-usage`
- 운영: `v2.4.13`, 2.4.13 (20413). 검증된 staging과 동일한 소스 `5e6e4ff2685aea469c6b3a60f7ea588f1ccc2e71`에서 운영 채널로 재빌드·공증·게시 완료
- staging: `v2.4.13-staging`, 2.4.13 (20413), 릴리스 소스 `5e6e4ff2685aea469c6b3a60f7ea588f1ccc2e71`
- 두 채널 GitHub Release의 ZIP·DMG·appcast와 Pages feed 검증 완료
- ZIP·DMG Apple 공증 Accepted, staple·Gatekeeper·재다운로드 체크섬 검증 완료
- GitHub CLI 계정은 `nathan-glorang`으로 복원

## 현재 구현

- Antigravity 실행 파일 메타데이터 변경 시 공식 서명·권한을 다시 검증하고 로컬 실행 구성을 교체
- 기존 조회 종료와 app-owned 프로세스 정리를 기다림. 정리 미확인 시 managed 실행 차단과 원장 보존
- 앱 실행 후 신규 설치·같은 경로 업데이트 반영, 프로세스 탐색 캐시 30초 만료와 수동/계정 변경 강제 재탐색
- 실패 원인과 시각 표시, 마지막 성공 데이터의 stale 처리 및 계정 경계 유지
- 계정 저장 형식·OAuth 방식·소스 순서 유지. Antigravity IDE는 미지원

## 검증과 남은 확인

- 전체 XCTest 998개, 4개 조건부 skip, 실패 0
- release-driver 테스트 338개 통과
- 최종 릴리스 게이트의 공식 AGY 사용량 조회 및 격리 실행 파일 교체 후 조회 모두 통과
- dev Release 실앱에서 4개 quota, 수동 새로고침, 진단 시각 표시 확인. idle CPU 0.0% 표본 확인
- 게시 후 /Applications/ClaudeUsage-stg.app의 Sparkle 2.4.12 → 2.4.13 업그레이드 확인. 원격 DMG 실행 파일 SHA-256과 설치본 일치, codesign·stapler·Gatekeeper 재검증 완료
- 사용자 요청에 따라 Chrome↔Claude Code 전환은 5회 왕복(총 10번 전환)으로 완료. 각 전환의 UI 인증 경로 일치, Keychain/password prompt 없음, 최종 Chrome 선택 및 저장된 chrome_profile provenance 확인
- 검증용 설정 창과 활성 상태 보기는 종료. 원래 열려 있던 Finder 휴지통 창은 유지. 현재 운영 앱만 실행 중이며 staging 2.4.13 설치본은 종료 상태
- 운영 설치본도 원격 DMG에서 2.4.13으로 갱신 완료. 운영 feed·bundle ID·version/build 및 실제 AGY 4개 quota 조회 확인. 운영 설정 검증 창은 종료
- 현재 UserDefaults의 legacy `claude-session-key` 부재, Claude 계정 migration 4, Antigravity settings migration 3 확인. 값·토큰 출력 없음

## 남은 위험과 다음 시작점

- 현재 게시된 2.4.13은 신규 AGY의 CSRF 요구를 전달하지 못해 `401 missing CSRF token`이 발생합니다. dev에서 인증 전달과 계정 변경 복구를 검증 중이며 아직 새 staging 후보를 게시하지 않았습니다. 현재 작업 상태는 `WORK_PLAN.md`를 확인합니다.

- 공식 AGY cold-start에서 로그인 요구가 일시적으로 나타날 수 있음. 최초 배포 시도는 이 오류로 게시 전에 중단됨. 포트만 확인하고 인증 완료 전에 종료하는 진단을 릴리스 게이트에서 분리한 뒤, 실제 조회 반복 3회와 최종 필수 두 검증 통과
- upstream 로컬 RPC와 Google endpoint 변경 가능성, 장시간 idle CPU는 계속 관찰 필요
- 이번 작업 중 prod와 staging 앱을 동시에 실행하지 않음. 검증할 채널 하나만 실행
- 다음 변경은 최신 main 기반 dev에서 진행. 현재 dev에는 릴리스 후 문서 갱신이 있을 수 있으므로 보존
- 후속 구현: Antigravity IDE의 경로·서명·포트·다중 계정 검증. 운영 승격 완료

## 문서 기준

- 로컬 규칙: `AGENTS.md`, `CLAUDE.md`는 `@AGENTS.md`만 포함
- 현재 작업: `WORK_PLAN.md`
- 제품 계약: `docs/antigravity-usage-sources.md`
- 배포: `docs/RELEASE.md`, `docs/PROJECT_WORKFLOW.md`
