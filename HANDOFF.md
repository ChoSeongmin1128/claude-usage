# 유지보수 현황

## 배포 상태

- 운영: [v2.4.13](https://github.com/ChoSeongmin1128/claude-usage/releases/tag/v2.4.13)
- staging: [v2.4.15-staging](https://github.com/ChoSeongmin1128/claude-usage/releases/tag/v2.4.15-staging)
- 다음 후보: 2.5.0 staging — Swift 6, 공개 문서 정리, MIT 라이선스와 외부 구성 요소 고지

현재 배포 상태는 GitHub Releases와 공개 채널 feed를 함께 확인합니다. staging 후보는 불변이며 운영 승격은 별도 결정입니다.

## 남은 검증과 제한

- 2.5.0 최종 앱의 라이선스 리소스·실앱 QA·staging 게시 검증
- 서명된 feed를 사용하는 설치본에서 다음 후보로의 실제 업그레이드
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
