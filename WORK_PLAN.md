# 로드맵

## 남은 검증

- 별도 macOS 환경에서 2.4.13보다 오래된 운영 배포본의 직접 설치·첫 실행·계정 및 설정 보존 검증

## Homebrew Cask 도입

- 완료: 검증된 운영 Release manifest, 결정적 Cask renderer, 상태 충돌 검증과 style·audit·livecheck·fetch 검사
- 완료: 운영 2.5.3으로 로컬 tap 후보와 최소 권한 CI 구성 및 실제 원격 artifact 검증
- 별도 공개 `ChoSeongmin1128/homebrew-tap` 생성·push와 GitHub Actions·공개 clone 재검증
- 신규 설치, 수동 설치본의 앱 번들 전환, Homebrew→Homebrew, Homebrew→Sparkle, Sparkle 선행→Homebrew 교차 업데이트 검증
- `auto_updates` Cask의 `--adopt`가 동일성 검사를 생략하므로 직접 안내하지 않고, 필요하면 원격 DMG와 전체 bundle identity를 검증하는 편입 도구를 먼저 구현
- `brew upgrade` 뒤 메뉴바 등록·설정·계정 보존과 제거·재설치의 데이터 보존 검증
- 별도 Cask 게시를 안정화한 뒤 운영 release driver의 최종 원격 검증 후 재시도 가능한 단계로 연동
- 실제 공개 tap 검증이 끝난 뒤에만 README에 설치 명령 공개

## 후속 검토

- 반복적인 AGY 초기 실행에서 간헐적으로 발생한 상호작용 필요 상태의 원인 확인
- Antigravity IDE 지원
- 장시간 idle 및 화면 잠금·해제의 성능 관찰
- 브랜드 자산 재사용 조건과 독립적인 앱 아이콘 검토
