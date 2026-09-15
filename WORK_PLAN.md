# ClaudeUsage 작업 계획

최종 갱신: 2026-09-15

## 진행 중: AGY CSRF 인증 호환성과 staging 검증

범위는 구현·테스트·staging 배포입니다. 운영 배포, IDE 지원, OAuth 저장 형식 변경은 포함하지 않습니다.

- 완료: 공식 설치 AGY의 동일 프로세스에서 토큰 없음 401 / 정상 토큰 200 / 잘못된 토큰 401 확인, 로그인 identity와 숫자 quota 확인
- 완료: 실행→준비 확인→RPC→연결 재검증에 CLI CSRF 전달, 메모리 소유권 등록과 정리, typed 오류, 요청당 최대 한 번의 인증 복구 구현
- 완료: 정상 자동 조회 세션 재사용, 명시적 새로고침의 세션 재생성, 계정 불일치 우선 처리 및 회귀 테스트
- 완료: 최종 diff 리뷰, 전체 XCTest 1013개(5개 opt-in/환경 조건 skip, 실패 0), Release 빌드, release-driver 338개 통과
- 완료: 공식 AGY 인증된 quota와 격리 실행 파일 교체 복구, 실제 A→B→A(identity·quota 2→4→2) 전환 검증
- 완료: dev staging 실앱 조회·수동 새로고침·고급 진단 전체 quota 확인, idle CPU 0.1% 표본 확인
- 진행: dev 커밋·push, 동일 tree main squash와 dev 정렬, 2.4.14 staging 후보 공증·게시
- 대기: 원격 ZIP·DMG·체크섬·Pages built·공개 staging feed·설치 앱 조회 검증과 임시 산출물 정리

실제 로그인은 사용자가 AGY에서 직접 수행합니다. Claude↔Claude Code 전환 검증은 이번 범위에 포함하지 않습니다. 작업 중에는 한 채널만 실행하며 앱 실행·종료는 프로세스 명령을 우선합니다.

## 후속 후보

- Antigravity IDE 지원: 별도 경로·식별자·서명·포트·계정 선택 검증
- 공식 AGY cold-start 인증 요구와 장시간 idle CPU 관찰

현재 게시 상태와 다음 시작점은 `HANDOFF.md`를 확인합니다.
