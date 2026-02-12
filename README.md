# ClaudeUsage

macOS 메뉴바에서 Claude.ai 사용량을 실시간으로 모니터링하는 네이티브 앱

## 주요 기능

- **메뉴바 실시간 표시** — 퍼센트, 리셋 시간, 아이콘을 조합하여 상단바에 표시
- **다양한 아이콘 스타일** — 배터리바, 원형, 동심원, 이중 배터리, 좌우 배터리
- **5시간 / 주간 세션** — 개별 또는 동시 모니터링
- **Popover 대시보드** — 클릭 시 전체 세션 상태 한눈에 확인
- **알림 시스템** — 사용량 임계치별 macOS 알림 (5시간/주간 개별 설정)
- **자동 로그인** — claude.ai 로그인으로 세션 키 자동 추출
- **절전 모드** — 배터리 사용 시 새로고침 간격 자동 조절

## 설치

### 빌드된 앱 사용

1. `ClaudeUsage.zip` 압축 해제
2. `ClaudeUsage.app`을 `/Applications`로 이동
3. 처음 실행 시 차단되면: 시스템 설정 → 개인정보 보호 및 보안 → "그래도 열기"

자세한 설치 방법은 [scripts/README.txt](scripts/README.txt) 참고

### 소스에서 빌드

```bash
git clone https://github.com/ChoSeongmin1128/claude-usage.git
cd claude-usage
xcodebuild -scheme ClaudeUsage -configuration Release
```

## 설정

앱 실행 후 메뉴바 아이콘 클릭 → 설정에서 구성:

- **인증** — Claude 로그인 또는 세션 키 직접 입력
- **디스플레이** — Claude 아이콘, 퍼센트, 리셋 시간(없음/5시간/주간/동시), 아이콘 스타일
- **새로고침** — 간격 (5~120초), 자동 새로고침
- **알림** — 사용량 임계치 (최대 3단계), 5시간/주간 개별 설정
- **절전** — 배터리 모드 시 새로고침 감소

## 프로젝트 구조

```
ClaudeUsage/
├── App/                    # AppDelegate, 메뉴바 관리
├── Models/                 # AppSettings, UsageModels, APIError
├── Services/               # ClaudeAPIService, KeychainManager, NotificationManager
├── Utilities/              # MenuBarIconRenderer, ColorProvider, TimeFormatter, Logger
└── Views/                  # PopoverView, SettingsView, LoginWindowView 등
```

## 기술 스택

- **언어**: Swift 6 (Strict Concurrency)
- **플랫폼**: macOS 14.0+ (Sonoma)
- **UI**: SwiftUI + AppKit
- **아키텍처**: MainActor 기반

## 라이선스

MIT License
