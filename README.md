# ClaudeUsage

macOS 메뉴바에서 Claude.ai 사용량을 실시간으로 모니터링하는 네이티브 앱

## 주요 기능

- **메뉴바 실시간 표시** — 퍼센트, 리셋 시간, 아이콘을 조합하여 상단바에 표시
- **다양한 아이콘 스타일** — 배터리바, 원형, 동심원, 이중 배터리, 좌우 배터리
- **5시간 / 주간 세션** — 개별 또는 동시 모니터링
- **Popover 대시보드** — 클릭 시 전체 세션 상태 한눈에 확인 (기본/간소화 모드, 핀 고정)
- **알림 시스템** — 사용량 임계치별 macOS 알림 (5시간/주간 개별 설정)
- **자동 로그인** — claude.ai 로그인으로 세션 키 자동 추출
- **절전 모드** — 배터리 사용 시 새로고침 간격 자동 조절
- **업데이트 확인** — GitHub Releases 기반 새 버전 감지 및 다운로드 안내

## 설치

### 릴리즈 다운로드

1. [ClaudeUsage.zip 다운로드](https://github.com/ChoSeongmin1128/claude-usage/releases/latest/download/ClaudeUsage.zip)
2. 압축 해제 후 `ClaudeUsage.app`을 원하는 위치로 이동
3. 처음 실행 시 우클릭 → 열기, 또는 시스템 설정 → 개인정보 보호 및 보안 → "그래도 열기"

### 소스에서 빌드

```bash
git clone https://github.com/ChoSeongmin1128/claude-usage.git
cd claude-usage
xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -configuration Release
```

## 설정

앱 실행 후 메뉴바 아이콘 클릭 → 설정에서 구성:

- **인증** — Claude 로그인 또는 세션 키 직접 입력
- **디스플레이** — Claude 아이콘, 퍼센트, 리셋 시간(없음/5시간/주간/동시), 아이콘 스타일
- **새로고침** — 간격 (5~120초), 자동 새로고침
- **알림** — 사용량 임계치 (최대 3단계), 5시간/주간 개별 설정
- **절전** — 배터리 모드 시 새로고침 감소
- **업데이트** — 앱 시작 시 자동 확인, 수동 확인

## 프로젝트 구조

```
ClaudeUsage/
├── App/                    # AppDelegate, 메뉴바 관리
├── Models/                 # AppSettings, UsageModels, APIError
├── Services/               # ClaudeAPIService, KeychainManager, NotificationManager, UpdateService
├── Utilities/              # MenuBarIconRenderer, ColorProvider, TimeFormatter, Logger, PowerMonitor
└── Views/                  # PopoverView, SettingsView, LoginWindowView, UsageSectionView 등
```

## 기술 스택

- **언어**: Swift 5.0
- **플랫폼**: macOS 14.0+ (Sonoma)
- **UI**: SwiftUI + AppKit
- **아키텍처**: MainActor 기반

## 라이선스

MIT License
