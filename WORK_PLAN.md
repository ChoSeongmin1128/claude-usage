# ClaudeUsage 작업 계획

최종 갱신: 2026-09-11

## 현재 작업: 2.4.13 staging

- AGY 실행 파일 변경·신규 설치 자동 복구, 로컬 구성 교체와 소유권 보존
- 프로세스 탐색 캐시 30초 만료와 수동/계정 변경 강제 재탐색
- 오류 원인 보존, 설정·팝오버 안내 통일, secret-free 진단 코드·조회 시각
- 구현 및 998개 전체 테스트 확인, 실제 AGY 3개 테스트 확인(격리 복사본 교체 후 quota 재조회 포함)
- Release 빌드·서명 검증 완료, dev 실앱에서 4개 quota·수동 재탐색·진단 시각 표시 확인, idle CPU 0.0% 표본 확인
- 남은 항목: main squash, 공증 staging 게시, 원격 ZIP/DMG·Pages·업그레이드·계정 전환 검증

## 후속 작업

- Antigravity IDE의 별도 경로·식별자·서명·포트·계정 선택 검증과 지원
- 운영 승격은 이번 작업에 포함하지 않음

## 유지할 계약

- borrowed AGY 종료 금지, app-owned process tree만 정확한 소유권 증거로 정리
- 계정 저장 형식과 OAuth 방식 유지, 실패를 0% 사용으로 표시하지 않음
- 배포 후보는 전체 테스트·공식 AGY live integration·공증·원격 아티팩트 검증 필수
- immutable staging tag/assets 유지, 실패 후보는 다음 patch로 수정
- 사용자 운영 설치 앱 유지, 계정별 credential provenance와 프롬프트 회귀 검증
- 이번 작업 중 prod와 staging은 동시에 실행하지 않음. 검증할 채널 하나만 실행
