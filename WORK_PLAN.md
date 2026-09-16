# 로드맵

## 남은 검증

- 별도 macOS 환경에서 2.4.13보다 오래된 운영 배포본의 직접 설치·첫 실행·계정 및 설정 보존 검증

## Homebrew Cask 도입

- [Homebrew 배포 설계](docs/homebrew-distribution.md)에 따라 별도 공개 tap과 운영 전용 Cask 구성
- 검증된 운영 Release manifest에서 Cask version·DMG URL·SHA-256을 결정적으로 생성하고 style·audit·livecheck 검사 추가
- 신규 설치, 동일 artifact `--adopt`, Homebrew→Homebrew, Homebrew→Sparkle, Sparkle 선행→Homebrew 교차 업데이트 검증
- `brew upgrade` 뒤 메뉴바 등록·설정·계정 보존과 제거·재설치의 데이터 보존 검증
- 별도 Cask 게시를 안정화한 뒤 운영 release driver의 최종 원격 검증 후 재시도 가능한 단계로 연동
- 실제 공개 tap 검증이 끝난 뒤에만 README에 설치 명령 공개

## 후속 검토

- 반복적인 AGY 초기 실행에서 간헐적으로 발생한 상호작용 필요 상태의 원인 확인
- Antigravity IDE 지원
- 장시간 idle 및 화면 잠금·해제의 성능 관찰
- 브랜드 자산 재사용 조건과 독립적인 앱 아이콘 검토
