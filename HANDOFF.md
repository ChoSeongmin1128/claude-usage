# 유지보수 현황

## 배포 상태

- 운영: [v2.5.2](https://github.com/ChoSeongmin1128/claude-usage/releases/tag/v2.5.2), build 20502
- staging: [v2.5.3-stg.4](https://github.com/ChoSeongmin1128/claude-usage/releases/tag/v2.5.3-stg.4), build 20506, source `90d66496a3bfc3fa20bf5340ebedf15ffb2aeaba`

staging은 Codex 자격 소유권·계정 변경·요청 취소, 자동 조회 설정 반영과 서비스별 예약 주기, AGY 포트 검사 시간 초과 전달 수정을 포함합니다. 전체 XCTest 1,001개 통과·선택 실행 7개 skip, 공식 AGY·Codex 실연동 4개 별도 통과, Thread Sanitizer 25개 통과 및 Release 빌드를 확인했습니다.

통합 driver에서 최종 main을 다시 검증하고 ZIP·DMG를 공증·게시했습니다. 원격 ZIP·DMG 체크섬, 코드 서명·staple·Gatekeeper, 릴리스 노트와 서명된 공개 feed 일치, Pages `built`를 확인했습니다. 변경 사항은 [버전별 노트](docs/release-notes/2.5.3.md)를 참고하세요.

설치 검증 앱의 자동 조회 중단·재개와 10분 계측에서 정상 조회 20회, 약 30초 주기, 지속적인 CPU·메모리 증가 없음도 확인했습니다. 구형 staging에서 stg.1로의 실제 업데이트는 완료했으며, stg.1에서 stg.4로의 실제 업데이트와 운영 승격 검증이 남아 있습니다.

## 남은 제한

- Codex 계정 변경·경합은 자동 테스트로, 현재 계정의 인증 갱신·identity·숫자 quota는 공식 CLI 실연동으로 검증했습니다. 실제 서로 다른 Codex 계정의 전환은 이번 검증에 포함하지 않았습니다.
- 반복적인 AGY 초기 실행에서 상호작용 필요 상태가 간헐적으로 관측됐으며 구체적인 원인은 확정하지 못했습니다. 최종 필수 실연동과 10분 정기 조회에서는 재현되지 않았습니다.
- 2.4.13보다 오래된 운영 배포본의 실제 직행 설치에는 별도 macOS 검증 환경이 필요합니다.
- 초기 혼합 채널 배포본은 [업데이트 호환 안내](docs/upgrade-compatibility.md)의 예외 경로를 따릅니다.
- Antigravity IDE는 지원하지 않습니다.
- 브랜드 자산의 권리는 소스 코드의 MIT 라이선스에 포함되지 않습니다.

## 유지보수 시작점

- [개발 및 검증](docs/PROJECT_WORKFLOW.md)
- [배포와 복구](docs/RELEASE.md)
- [인증과 계정 경계](docs/authentication-and-sources.md)
- [Antigravity 실행 계약](docs/antigravity-usage-sources.md)
- [로드맵](WORK_PLAN.md)

다음 단계는 게시된 stg.4의 실제 업데이트 확인입니다. 이후 승인 후보를 `--from-staging v2.5.3-stg.4`로 지정하고 배포 입력과 build 20506을 유지해 운영으로 승격합니다. 개인 계정·머신별 로그·로컬 경로는 Git에 기록하지 않습니다.
