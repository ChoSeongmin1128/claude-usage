# 개발 및 기여

## 브랜치와 변경 단위

- `main`: 검증된 배포 기준
- `dev`: 최신 main에서 시작하는 구현·리뷰 작업
- `gh-pages`: 검증된 appcast의 배포 결과
- staging: 코드 브랜치가 아닌 릴리스 채널

관련된 변경을 한 커밋으로 묶고 dev에 push합니다. 코드 리뷰와 전체 테스트·Release 빌드·실앱 검증을 마친 뒤 main에 squash합니다. staged tree가 검증한 dev tree와 같은지 확인하고, 게시 산출물은 그 main 커밋에서 다시 만듭니다. 다음 작업 전에는 반영이 끝난 dev를 새 main 이력에 정렬합니다.

진행 중인 변경을 덮어쓰거나, 충돌 해결 과정에서 검증한 tree와 다른 내용을 조합하지 않습니다. 커밋 메시지는 무엇을 왜 바꿨는지 설명합니다.

## 로컬 환경

Xcode 프로젝트에서 자신의 서명 설정을 사용합니다. 공식 배포 driver는 대상 저장소·계정·원격·서명 정책을 고정하여 검증하므로, 포크에서 배포하려면 해당 정책과 채널 설정을 먼저 검토해야 합니다.

커밋하지 않는 항목:

- `Config/Sparkle.release.local.xcconfig`, `.env` 등 로컬 설정
- 개인키·인증서·프로비저닝 파일과 공증 자격
- 토큰·계정 주소·원본 인증 응답
- 개인 머신의 절대 경로, SSH 설정, 계정 전환 기록
- 빌드·다운로드·마운트·검증 로그 등 임시 산출물

Sparkle 공개키는 검증의 신뢰 기준이므로 추적합니다. 개인키는 Keychain에 보관합니다. 로컬 설정 재생성과 서명 키 교체는 다른 작업이며, 키 교체에는 기존 설치본의 업데이트 복구 검증이 필요합니다.

## 코드 검사

```bash
python3 Scripts/check-changes.py --base main
# 필요한 경우 변경 범위만 포맷
python3 Scripts/check-changes.py --base main --fix
```

Swift는 Xcode 내장 swift-format과 `.swift-format` 설정으로 변경한 줄을 검사합니다. 새 파일은 전체를 검사합니다. 관련 없는 파일의 일괄 포맷은 하지 않습니다. 변경된 셸 파일에는 ShellCheck 0.11.0이 필요하며, 버전 불일치나 검사 실패는 배포를 차단합니다.

## 테스트

```bash
xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage   -destination 'platform=macOS' test
Scripts/tests/release-driver-tests.sh
```

실제 외부 서비스가 필요한 테스트는 명시적인 opt-in으로 실행합니다. 필수 AGY release gate에서는 공식 CLI의 인증된 identity와 숫자 quota, 격리한 공식 실행 파일 교체 후 복구를 확인해야 합니다. skip이나 HTTP 200만으로 통과 처리하지 않습니다.

동시성 변경은 취소·공유 조회·계정 전환·프로세스 소유권을 검토하고 필요한 경로를 Thread Sanitizer로 검증합니다. 사용자 로그인은 사용자가 수행하며 반복·경합은 가능한 한 결정적 fixture로 검증합니다.

## Swift 6의 실행 경계

| 영역 | 책임 |
|---|---|
| 화면·Sparkle UI 엔진·타이머 등록 | MainActor |
| 계정·quota·출처 값 모델 | Sendable 값과 명시적인 nonisolated 계약 |
| 동기 파일·Keychain 저장소 | nonisolated 프로토콜과 구현의 잠금·파일 검증 |
| Codex 토큰 캐시 | 상태를 소유하는 잠금으로 읽기·갱신 보호 |
| Codex 토큰 갱신 작업 | MainActor에서 중복 작업 공유 |
| AGY 구성·조회·계정 변경 | 기존 actor와 lease·세대·취소 경계 |

`MainActor.assumeIsolated`는 MainActor에서 등록한 main-run-loop 타이머와 `queue: .main` 알림처럼 실행 위치를 입증할 수 있는 동기 콜백에만 사용합니다. 임의의 백그라운드 작업을 통과시키는 용도로 사용하지 않습니다.

지연 렌더링 클로저에는 생성 시점의 화면 테마를 전달합니다. UI 객체 정리는 isolated deinit을 사용하지만, AGY 프로세스와 파일 소유권의 정리는 기존 명시적인 종료 절차를 유지합니다. Swift 6 전환만으로 기존 `@unchecked Sendable` 구현의 안전성이 보장되지는 않습니다.

## 공개 문서와 릴리스 노트

README는 설치·사용·개발 안내, 기술 문서는 현재 계약과 재현 가능한 절차를 설명합니다. 개인 작업 일지·계정 전환 이력·머신별 검증 로그는 공개 문서에 추가하지 않습니다. 예시는 가상 데이터와 일반화된 경로를 사용합니다.

버전별 `docs/release-notes/X.Y.Z.md`에 사용자에게 달라지는 내용과 알려진 제한을 작성하고 코드와 함께 리뷰합니다. 통합 driver가 같은 내용을 GitHub와 Sparkle에 전달합니다. 릴리스 노트는 버전명 한 줄이나 자동 생성 커밋 목록으로 대체하지 않습니다.

라이선스 또는 의존성을 변경할 때는 `LICENSE`와 `THIRD_PARTY_NOTICES.md`를 검토합니다. 두 정본은 앱 리소스에도 포함됩니다. 외부 저작권 고지는 개인 작업 이력과 구분하여 보존합니다.

## 실앱 검증

설치 앱은 Finder에서 직접 실행합니다. 자동화 호스트의 실행 파일 호출이나 `open` 실행은 macOS ControlCenter의 메뉴바 연결을 오염시킬 수 있습니다. 한 채널만 실행한 상태에서 메뉴바·팝오버·계정 선택·새로고침·업데이트를 확인합니다.

설치된 이전 버전에서 새 버전으로의 실제 업그레이드, 서명된 feed를 요구하는 설치본에서의 다음 업그레이드를 확인합니다. 검증이 끝나면 작업에서 만든 임시 산출물과 검증 창을 정리합니다. 상세 절차는 [배포 가이드](RELEASE.md)를 따릅니다.
