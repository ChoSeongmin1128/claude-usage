# 유지보수 현황

## 배포 상태

- 운영: [v2.5.2](https://github.com/ChoSeongmin1128/claude-usage/releases/tag/v2.5.2)
- staging: [v2.5.3-stg.1](https://github.com/ChoSeongmin1128/claude-usage/releases/tag/v2.5.3-stg.1), build 20503

첫 후보는 번호 체계 검증용이며 조회 기능은 운영 2.5.2와 같습니다. 통합 driver의 전체 검사, ZIP·DMG 공증, 원격 자산과 서명된 feed, Pages 게시 검증을 완료했습니다. 구형 staging 설치본에서 첫 후보로의 실제 Sparkle 업데이트와 설치 앱의 서명·공증 검증도 완료했습니다.

2.5.2는 검증된 2.5.1의 앱 코드를 유지하며, AGY 조회 대상·현재 로그인 표시 개선과 Sparkle 2.10·서명된 업데이트 안내·Swift 6·MIT 고지를 운영에 포함합니다. 두 채널을 동일 소스 커밋에서 통합 driver로 게시했습니다. 전체 XCTest와 필수 공식 AGY 검증, 원격 ZIP·DMG의 공증·서명·Gatekeeper, 릴리스 노트와 공개 feed 일치 및 Pages `built` 상태를 확인했습니다. 변경 사항은 [버전별 노트](docs/release-notes/2.5.2.md)를 참고하세요.

운영 2.4.13에서 2.5.2로 실제 Sparkle 업데이트·재실행, Claude·Codex·AGY 조회와 기존 계정·표시 설정 보존을 확인했습니다. AGY 연결 설정은 v2에서 v4로 이전됐으며 설치 앱의 서명·공증 검증도 통과했습니다.

현재 배포 상태는 GitHub Releases와 공개 채널 feed를 함께 확인합니다. staging 후보는 불변이며 운영 승격은 별도 결정입니다.

## 남은 제한

- 2.4.13보다 오래된 운영 배포본의 실제 직행 설치는 별도 macOS 검증 환경 필요
- 초기 혼합 채널 배포본은 [업데이트 호환 안내](docs/upgrade-compatibility.md)의 예외 경로를 따름
- AGY 초기 인증 지연과 upstream 인터페이스 변경 가능성
- Antigravity IDE 미지원
- 브랜드 자산의 권리는 소스 코드의 MIT 라이선스에 포함되지 않음

다음 후보 `2.5.3-stg.4 (20506)`의 구현·검증을 완료했습니다. Codex 자격 소유권·계정 변경·요청 취소, 자동 조회 설정 반영과 서비스별 예약 주기, AGY 포트 검사 시간 초과의 오류 전달 수정을 포함합니다. 전체 XCTest 1,001개 통과·선택 실행 7개 skip, 공식 AGY·Codex 실연동 4개 별도 통과, Thread Sanitizer 25개 통과 및 Release 빌드·서명을 확인했습니다. 설치 앱의 설정 중단·재개와 10분 계측에서 정상 조회 20회, 30초 주기, 지속적인 CPU·메모리 증가 없음도 확인했습니다. 아직 게시하지 않았으며, 게시 후 stg.1에서의 실제 업데이트와 운영 승격 검증이 남아 있습니다.

Codex 계정 변경·경합은 자동 테스트로, 현재 계정의 인증 갱신과 숫자 quota는 공식 CLI 실연동으로 검증합니다. 운영 승격 시에는 최종 승인한 후보를 명시하고 배포 입력과 build를 유지합니다.

## 유지보수 시작점

- [개발 및 검증](docs/PROJECT_WORKFLOW.md)
- [배포와 복구](docs/RELEASE.md)
- [인증과 계정 경계](docs/authentication-and-sources.md)
- [Antigravity 실행 계약](docs/antigravity-usage-sources.md)
- [로드맵](WORK_PLAN.md)

개인 계정 전환 기록·머신별 검증 로그·로컬 경로는 이 문서에 기록하지 않습니다.
