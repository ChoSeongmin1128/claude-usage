# ClaudeUsage 유지보수 인계

최종 갱신: 2026-09-15

## 현재 배포 상태

- 저장소: `ChoSeongmin1128/claude-usage`
- staging: [`v2.4.14-staging`](https://github.com/ChoSeongmin1128/claude-usage/releases/tag/v2.4.14-staging), 2.4.14 (20414), 소스 `bbcf88c40602e597bf2a3a880adf11b99309a726`
- 운영: `v2.4.13`, 2.4.13 (20413). 이번 작업에서 운영 앱·feed·Release는 교체하지 않음
- main squash의 tree가 검증한 dev tree `8209350a3e8613a9d904d8852e114b84b6f83bb7`과 일치. dev는 새 main 이력에 정렬 후 게시 결과 문서만 갱신
- 통합 release driver로 ZIP·DMG Apple 공증 Accepted, staple·Gatekeeper·원격 자산 검증 완료
- Pages 커밋 `7d4440d228f25880c57f43e94f08f26fffaea3c6`의 상태 `built`, 공개 staging feed 2.4.14·운영 feed 2.4.13 확인
- GitHub CLI 계정은 `nathan-glorang`으로 복원

## 설치본과 검증 결과

- `/Applications/ClaudeUsage-stg.app`에서 Sparkle 2.4.13 → 2.4.14 업데이트 완료. 버전·build·staging bundle ID와 feed 확인
- GitHub에서 DMG를 다시 다운로드하여 API SHA-256과 비교. 설치 실행 파일은 원격 DMG 실행 파일과 SHA-256 일치, codesign·stapler·Gatekeeper 재검증 완료
- 최종 main 전체 XCTest 1013개 집계, 환경/opt-in skip 5개, 실패 0. release-driver 테스트 338개 통과
- 필수 실증은 skip과 별도로 실행: 공식 AGY 1.2.2 인증된 identity·숫자 quota, 격리 공식 실행 파일 교체 후 복구 모두 통과
- 사용자가 직접 로그인한 A→B→A 전환에서 identity와 quota 2→4→2 일치. 같은 runtime에서 정상 자동 조회의 프로세스 재사용 확인
- dev Release 실앱과 최종 설치본 모두 AGY 한도 2개·수동 새로고침·고급 진단 `전체 quota` 확인. dev idle CPU 0.1% 표본 확인
- 검증 설정 창은 종료했으며 현재 staging 앱만 실행. 운영 앱은 종료 상태이고 파일은 기존 2.4.13 유지
- 검증 DMG를 해제하고 이번 작업의 임시 빌드·로그·probe 정리 완료. 사용자 AGY와 사용자가 직접 연 로그인 창은 정리 대상에 포함하지 않음

## 현재 동작과 남은 위험

- managed AGY의 실행별 CSRF를 준비 확인·quota/identity RPC·프로세스/포트 재검증까지 전달. 메모리에서만 보관하고 정리 시 폐기
- CSRF 필요·불일치·확보 실패를 Google 로그인과 구분. 복구 재생성은 요청당 최대 한 번이며 정상 자동 조회는 세션 재사용
- CLI에서 로그인 계정을 바꾼 후 수동 새로고침하면 owned 세션을 새로 만들고 identity를 다시 검증. 확인된 계정 불일치는 후속 연결 오류보다 우선하여 이전 사용량을 숨김
- 운영 2.4.13에는 이 수정이 없어 AGY 1.2.2에서 CSRF 조회 실패가 남음. 운영 승격은 별도 승인 범위
- 실기 검증은 AGY 1.2.2 기준이며 구버전 tokenless 경로는 fixture로 검증. upstream RPC 변경 가능성과 장시간 idle CPU는 계속 관찰 필요
- 현재 게시된 2.4.14는 이전 업데이트 체계를 사용. 버전별 노트·서명된 feed·DMG 업데이트 구현은 dev에서 다음 staging 후보를 검증 중이며 아직 게시되지 않음

## 다음 시작점

- 현재 작업과 후속 후보: `WORK_PLAN.md`
- 제품 인증·계정·runtime 계약: `docs/antigravity-usage-sources.md`
- 배포 절차: `docs/RELEASE.md`, `docs/PROJECT_WORKFLOW.md`
- `AGENTS.md`는 local-only, `CLAUDE.md`는 `@AGENTS.md`만 유지
