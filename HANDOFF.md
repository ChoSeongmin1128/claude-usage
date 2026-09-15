# 유지보수 현황

## 배포 상태

- 운영: [v2.4.13](https://github.com/ChoSeongmin1128/claude-usage/releases/tag/v2.4.13)
- staging: [v2.5.1-staging](https://github.com/ChoSeongmin1128/claude-usage/releases/tag/v2.5.1-staging)

2.5.1은 조회 대상을 CLI와 독립 앱으로 구분하고 현재 로그인 계정을 읽기 전용으로 표시합니다. Google 연결·원격 조회를 제거했으며, 로그인 변경 중 계정과 수치의 일치 및 대상 전환 경합을 검증했습니다. 최종 소스에서 공식 AGY 조회·실행 파일 교체·로그인 전환 검증을 통과했습니다. 원격 ZIP·DMG의 공증·서명·Gatekeeper, 릴리스 노트와 공개 feed 일치 및 Pages `built` 상태도 확인했습니다. 정식 2.5.0 staging에서 2.5.1로 실제 Sparkle 업데이트 후 재실행·AGY 조회·조회 대상 설정 보존을 확인했습니다.

현재 배포 상태는 GitHub Releases와 공개 채널 feed를 함께 확인합니다. staging 후보는 불변이며 운영 승격은 별도 결정입니다.

## 남은 제한

- 운영 구버전의 실제 직행 설치는 별도 macOS 검증 환경 필요
- 초기 혼합 채널 배포본은 [업데이트 호환 안내](docs/upgrade-compatibility.md)의 예외 경로를 따름
- AGY 초기 인증 지연과 upstream 인터페이스 변경 가능성
- Antigravity IDE 미지원
- 브랜드 자산의 권리는 소스 코드의 MIT 라이선스에 포함되지 않음

## 유지보수 시작점

- [개발 및 검증](docs/PROJECT_WORKFLOW.md)
- [배포와 복구](docs/RELEASE.md)
- [인증과 계정 경계](docs/authentication-and-sources.md)
- [Antigravity 실행 계약](docs/antigravity-usage-sources.md)
- [로드맵](WORK_PLAN.md)

개인 계정 전환 기록·머신별 검증 로그·로컬 경로는 이 문서에 기록하지 않습니다.
