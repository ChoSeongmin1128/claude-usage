# 로드맵

## 남은 검증

- 별도 macOS 환경에서 2.4.13보다 오래된 운영 배포본의 직접 설치·첫 실행·계정 및 설정 보존 검증

## Homebrew Cask

- 다음 운영 버전의 원격 자산 검증 후 Cask를 수동 갱신하고 공개 tap 검사를 다시 통과
- 실제 `/Applications` 설치본에서 Homebrew→Homebrew, Homebrew→Sparkle, Sparkle 선행→Homebrew 교차 업데이트 검증
- `brew upgrade` 뒤 메뉴바 등록·설정·계정 보존과 격리 환경의 제거·재설치 데이터 보존 검증
- 수동 Cask 갱신과 교차 업데이트가 안정화된 뒤 운영 release driver의 최종 원격 검증 다음에 재시도 가능한 tap 반영 단계 연결

## 후속 검토

- 반복적인 AGY 초기 실행에서 간헐적으로 발생한 상호작용 필요 상태의 원인 확인
- Antigravity IDE 지원
- 장시간 idle 및 화면 잠금·해제의 성능 관찰
- 브랜드 자산 재사용 조건과 독립적인 앱 아이콘 검토
