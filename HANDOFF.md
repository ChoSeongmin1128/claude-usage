# 유지보수 현황

## 배포 상태

- 운영: [v2.4.13](https://github.com/ChoSeongmin1128/claude-usage/releases/tag/v2.4.13)
- staging: [v2.5.0-staging](https://github.com/ChoSeongmin1128/claude-usage/releases/tag/v2.5.0-staging)
- 다음 후보: 2.5.1 staging — 조회 대상 선택과 현재 로그인 표시, Google 연결 제거와 전환 오류 수정

2.5.0은 Swift 6 전환, 제한된 운영 진단, 공개 문서 정리, MIT 라이선스와 외부 구성 요소 고지를 포함합니다. Sparkle 2.10의 서명된 feed와 버전별 변경 사항을 사용하며, 원격 ZIP·DMG의 공증·서명·라이선스 리소스 및 공개 feed 검증을 통과했습니다. 서명된 feed를 요구하는 이전 staging에서 변경 사항 표시·업그레이드·사용량 조회도 확인했습니다.

현재 배포 상태는 GitHub Releases와 공개 채널 feed를 함께 확인합니다. staging 후보는 불변이며 운영 승격은 별도 결정입니다.

## 남은 제한

- 2.5.1의 최종 게시와 설치본 업그레이드 검증
- 운영 구버전의 실제 직행 설치는 별도 macOS 검증 환경 필요
- 초기 혼합 채널 배포본은 [업데이트 호환 안내](docs/upgrade-compatibility.md)의 예외 경로를 따름
- AGY 초기 인증 지연과 upstream 인터페이스 변경 가능성
- 현재 게시된 2.5.0의 로컬 자동 조회는 특정 계정에 고정되지 않으므로 앱과 CLI의 로그인 계정이 다르면 성공한 조회 경로에 따라 표시 계정이 달라질 수 있음
- Antigravity IDE 미지원
- 브랜드 자산의 권리는 소스 코드의 MIT 라이선스에 포함되지 않음

## 유지보수 시작점

- [개발 및 검증](docs/PROJECT_WORKFLOW.md)
- [배포와 복구](docs/RELEASE.md)
- [인증과 계정 경계](docs/authentication-and-sources.md)
- [Antigravity 실행 계약](docs/antigravity-usage-sources.md)
- [로드맵](WORK_PLAN.md)

개인 계정 전환 기록·머신별 검증 로그·로컬 경로는 이 문서에 기록하지 않습니다.
