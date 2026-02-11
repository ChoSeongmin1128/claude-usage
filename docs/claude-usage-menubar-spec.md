# Claude Usage Menu Bar App - 상세 기획서

## 📋 프로젝트 개요

macOS 메뉴바에서 Claude.ai 사용량을 실시간으로 모니터링하는 네이티브 앱

- **플랫폼**: macOS 14.0+ (Sonoma)
- **언어**: Swift 5.0+
- **프레임워크**: SwiftUI
- **용도**: 개인 사용
- **라이선스**: MIT (오픈소스)

---

## 🎯 핵심 기능

### 1. 메뉴바 디스플레이

#### 기본 구성
```
[Claude 아이콘] [사용량 표시]
```

#### 표시 모드 (3가지 선택 가능)

**모드 1: 퍼센트**
```
[🔵] 67%
```

**모드 2: 배터리바**
```
[🔵] ████████▒▒▒▒
```

**모드 3: 원형 로딩**
```
[🔵] ◐
```

#### 색상 코딩 시스템 (동적 그라데이션)

퍼센트에 따라 초록색 → 노란색 → 빨간색으로 부드럽게 전환

| 사용량 | 색상 예시 | 설명 |
|--------|----------|------|
| 0% | 🟢 초록색 | HSL(120°, 100%, 40%) - 완전 안전 |
| 25% | 🟢 연두색 | HSL(90°, 100%, 40%) - 여유 있음 |
| 50% | 🟡 노란색 | HSL(60°, 100%, 50%) - 절반 사용 |
| 75% | 🟠 주황색 | HSL(30°, 100%, 50%) - 주의 필요 |
| 90% | 🔴 빨간색 | HSL(0°, 100%, 50%) - 거의 소진 |
| 100% | ⚫ 회색 | #808080 - 완전 소진 |

**색상 계산 공식**: `Hue = 120 - (percentage × 1.2)` (0-100%)
- 120° (초록) → 0° (빨강)으로 선형 변환
- 100% 도달 시 회색으로 전환

#### 토글 기능

**기본 표시**: 5시간 세션 사용량
**Option+클릭**: 주간 한도로 전환

```
Option+클릭 → 전환
[🔵] 67% (5시간) ↔ [🔵] 45% (주간)
```

#### 툴팁
```
마우스 오버 시:
"5-Hour Session: 67%
(Option+Click to show Weekly)"
```

---

## 📊 Popover 인터페이스

### 레이아웃 구조

```
┌────────────────────────────────────┐
│  Menu Bar: [5-Hour] [Weekly]  [🔄] │  ← 상단 컨트롤
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │
│                                    │
│  📊 5-Hour Session            67%  │
│  ████████████▒▒▒▒                 │
│  Resets in 2h 34m                 │
│  ────────────────────────────────  │
│                                    │
│  📅 Weekly Limit (All Models) 45%  │
│  ████████▒▒▒▒▒▒▒▒                 │
│  Resets in 4d 12h                 │
│  ────────────────────────────────  │
│                                    │
│  🎯 Sonnet (Weekly)           32%  │
│  ██████▒▒▒▒▒▒▒▒▒▒                 │
│  Resets in 4d 12h                 │
│  ────────────────────────────────  │
│                                    │
│  [View Usage Details →]           │
│  [⚙️ Settings]         [Quit]     │
└────────────────────────────────────┘
```

### 구성 요소

#### 1. 상단 컨트롤 바
- **Segmented Control**: 메뉴바 표시 지표 선택
  - `[5-Hour] [Weekly]`
- **새로고침 버튼**: 수동 갱신 (🔄)

#### 2. 사용량 섹션 (3개)

**5-Hour Session**
- 아이콘: 📊
- 진행바: 색상 코딩된 프로그레스 바
- 퍼센트: 67%
- 리셋 정보: "Resets in 2h 34m" (상대 시간)

**Weekly Limit (All Models)**
- 아이콘: 📅
- 진행바: 색상 코딩된 프로그레스 바
- 퍼센트: 45%
- 리셋 정보: "Resets in 4d 12h"

**Sonnet (Weekly)**
- 아이콘: 🎯
- 진행바: 색상 코딩된 프로그레스 바
- 퍼센트: 32%
- 리셋 정보: "Resets in 4d 12h"
- 주의: Free 플랜 사용자는 이 섹션 숨김

#### 3. 하단 액션 바
- **View Usage Details**: claude.ai/settings/usage 링크
- **Settings**: 설정 창 열기
- **Quit**: 앱 종료

---

## ⚙️ 설정 (Settings)

### 설정 창 레이아웃

```
┌──────── Settings ────────┐
│                          │
│ 🔑 Authentication        │
│ ┌────────────────────┐   │
│ │ Session Key        │   │
│ │ sk-ant-sid01-...   │   │
│ └────────────────────┘   │
│ [Test Connection]        │
│                          │
│ 🎨 Display               │
│ Menu Bar Style:          │
│ ○ Percentage             │
│ ● Battery Bar            │
│ ○ Circular               │
│                          │
│ Show Icon: ☑             │
│                          │
│ 🔄 Refresh               │
│ Interval: [5] seconds    │
│ ────────────────────     │
│ Auto-refresh: ☑          │
│                          │
│ 🔔 Notifications         │
│ ☑ Alert at 75%           │
│ ☑ Alert at 90%           │
│ ☑ Alert at 95%           │
│                          │
│ 🌙 Power Saving          │
│ ☑ Reduce refresh when    │
│   on battery             │
│                          │
│     [Save]  [Cancel]     │
└──────────────────────────┘
```

### 설정 항목

#### Authentication
- **Session Key**: `sk-ant-sid01-...` 형식
- **Test Connection**: 유효성 검증 버튼
- **보안**: macOS Keychain에 저장

#### Display
- **Menu Bar Style**: 3가지 표시 모드
  - Percentage (67%)
  - Battery Bar (████▒▒▒▒)
  - Circular (◐)
- **Show Icon**: Claude 아이콘 표시 여부

#### Refresh
- **Interval**: 5-120초 (슬라이더)
- **Auto-refresh**: 자동 갱신 활성화

#### Notifications
- **임계값 알림**: 75%, 90%, 95%
- **macOS 시스템 알림** 사용

#### Power Saving
- **배터리 모드**: 갱신 간격 자동 조정 (30초)

---

## 🔧 기술 스택

### 아키텍처

```
┌─────────────────────────────────┐
│        App Layer                │
│   SwiftUI Views + AppState      │
└─────────────────────────────────┘
              ↓
┌─────────────────────────────────┐
│       Domain Layer              │
│   Models + Services (Actor)     │
└─────────────────────────────────┘
              ↓
┌─────────────────────────────────┐
│   Infrastructure Layer          │
│   API Client + Keychain         │
└─────────────────────────────────┘
```

### 주요 컴포넌트

#### 1. AppDelegate
```swift
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var showingSessionUsage = true
    
    // 메뉴바 관리
    // 클릭 핸들링
    // Popover 토글
}
```

#### 2. ClaudeAPIService
```swift
actor ClaudeAPIService {
    func fetchUsage() async throws -> ClaudeUsageResponse
    func fetchOrganizationID() async throws -> String
}
```

#### 3. Data Models
```swift
struct ClaudeUsageResponse: Codable {
    let fiveHour: UsageWindow
    let sevenDay: UsageWindow
    let sevenDayOpus: UsageWindow?
}

struct UsageWindow: Codable {
    let utilizationPercentage: Double
    let resetAt: String  // ISO 8601
}
```

#### 4. KeychainManager
```swift
class KeychainManager {
    func save(sessionKey: String)
    func load() -> String?
    func delete()
}
```

---

## 🔐 인증 및 API

### Session Key 추출

**브라우저에서 가져오기**:
1. claude.ai 로그인
2. 개발자 도구 (F12 또는 Cmd+Option+I)
3. Application → Cookies → https://claude.ai
4. `sessionKey` 복사 (sk-ant-sid01-...)

### API 엔드포인트

```http
GET https://claude.ai/api/organizations/{org_id}/usage
Cookie: sessionKey={session_key}
```

### 응답 예시

```json
{
  "fiveHour": {
    "utilizationPercentage": 67.5,
    "resetAt": "2025-02-11T15:30:00Z"
  },
  "sevenDay": {
    "utilizationPercentage": 45.2,
    "resetAt": "2025-02-15T00:00:00Z"
  },
  "sevenDayOpus": {
    "utilizationPercentage": 32.1,
    "resetAt": "2025-02-15T00:00:00Z"
  }
}
```

---

## 🎨 UI/UX 디테일

### 색상 시스템 (동적 그라데이션)

```swift
func getStatusColor(percentage: Double) -> Color {
    // 100% 도달 시 회색
    if percentage >= 100 {
        return Color.gray
    }

    // 0-100%: 초록(120°) → 빨강(0°)으로 선형 변환
    let hue = (120.0 - (percentage * 1.2)) / 360.0  // SwiftUI는 0-1 범위
    let saturation = 1.0
    let brightness = percentage > 50 ? 0.5 : 0.4  // 50% 이후 더 밝게

    return Color(hue: hue, saturation: saturation, brightness: brightness)
}

// 사용 예시
// 0%   → HSL(120°, 100%, 40%) = 진한 초록
// 25%  → HSL(90°, 100%, 40%)  = 연두
// 50%  → HSL(60°, 100%, 50%)  = 노란색
// 75%  → HSL(30°, 100%, 50%)  = 주황
// 90%  → HSL(12°, 100%, 50%)  = 빨강에 가까움
// 100% → Gray (#808080)       = 회색
```

### 시간 표시 형식

```swift
// ❌ 절대 시간
"Resets at 2025-02-11 15:30"

// ✅ 상대 시간 (추천)
"Resets in 2h 34m"
"Resets in 4d 12h"
"Resets in 45m"
```

### 애니메이션

```swift
// 값 변경 시 부드러운 전환
withAnimation(.easeInOut(duration: 0.2)) {
    updateMenuBar()
}

// 진행바 애니메이션
ProgressView(value: percentage)
    .animation(.easeInOut, value: percentage)
```

### 다크 모드 지원

- 자동 적응: `@Environment(\.colorScheme)`
- 아이콘: SF Symbols 사용 (자동 대응)

---

## ⌨️ 키보드 단축키

| 단축키 | 기능 |
|--------|------|
| `일반 클릭` | Popover 열기/닫기 |
| `Option+클릭` | 5시간 ↔ 주간 전환 |
| `⌘R` | 수동 새로고침 |
| `⌘,` | 설정 열기 |
| `⌘U` | Usage 페이지 열기 |
| `⌘Q` | 앱 종료 |

---

## 🔔 알림 시스템

### 알림 조건

```swift
// 임계값 도달 시 1회만 알림
if percentage >= 75 && !alerted75 {
    sendNotification(
        title: "Claude Usage Alert",
        body: "75% of your 5-hour session used"
    )
    alerted75 = true
}
```

### 알림 타입

1. **사용량 임계값**: 75%, 90%, 95%
2. **세션 리셋**: "Your 5-hour session has reset"
3. **주간 리셋**: "Your weekly limit has reset"
4. **API 오류**: "Failed to fetch usage data"

---

## 🛡️ 보안 및 프라이버시

### Session Key 보안

```swift
// ✅ Keychain에 저장
KeychainManager.save(sessionKey)

// ❌ UserDefaults 사용 금지
UserDefaults.standard.set(sessionKey, forKey: "key")
```

### 파일 권한

```bash
# ~/.claude-session-key (백업 저장소)
chmod 600 ~/.claude-session-key
```

### 데이터 저장

- **로컬 전용**: 모든 데이터는 기기에만 저장
- **텔레메트리 없음**: 사용 통계 수집 안 함
- **HTTPS만 사용**: API 통신 암호화

---

## 📁 프로젝트 구조

```
ClaudeUsageMenuBar/
├── App/
│   ├── ClaudeUsageApp.swift          # @main
│   └── AppDelegate.swift             # 메뉴바 관리
│
├── Views/
│   ├── PopoverView.swift             # 메인 Popover
│   ├── UsageSectionView.swift        # 사용량 섹션
│   ├── SettingsView.swift            # 설정 창
│   └── Components/
│       ├── ProgressBarView.swift     # 커스텀 진행바
│       └── BatteryIconView.swift     # 배터리 아이콘
│
├── Services/
│   ├── ClaudeAPIService.swift        # API 호출
│   ├── KeychainManager.swift         # Keychain 관리
│   └── NotificationManager.swift     # 알림 관리
│
├── Models/
│   ├── UsageModels.swift             # 데이터 모델
│   └── AppSettings.swift             # 설정 모델
│
├── Utilities/
│   ├── TimeFormatter.swift           # 시간 포맷팅
│   ├── ColorProvider.swift           # 색상 로직
│   └── IconGenerator.swift           # 커스텀 아이콘
│
└── Resources/
    ├── Assets.xcassets               # 아이콘, 이미지
    └── Info.plist
```

---

## 🚀 개발 단계

### Phase 1: 기본 기능 (MVP)
- [x] 메뉴바 아이콘 표시
- [x] API 연동 (5시간 세션 사용량)
- [x] Popover 기본 UI
- [x] 수동 새로고침

### Phase 2: 핵심 기능
- [ ] 주간 한도 표시
- [ ] Option+클릭 토글
- [ ] 3가지 표시 모드
- [ ] 색상 코딩

### Phase 3: 고급 기능
- [ ] 설정 창
- [ ] Keychain 연동
- [ ] 자동 새로고침
- [ ] 알림 시스템

### Phase 4: 완성도
- [ ] 다크 모드
- [ ] 애니메이션
- [ ] 에러 핸들링
- [ ] 배터리 절약 모드

---

## 🐛 에러 처리

### API 오류

```swift
enum APIError: Error {
    case invalidSessionKey      // 세션 키 만료
    case networkError          // 네트워크 연결 실패
    case parseError            // JSON 파싱 실패
    case rateLimited           // API 제한
}
```

### 사용자 피드백

```
[⚠️] Unable to fetch usage
     [Retry] [Check Settings]
```

### 로깅

```swift
// 개발 중에만 로깅
#if DEBUG
    print("API Response: \(data)")
#endif
```

---

## 📦 배포

### 빌드 설정

```swift
// Info.plist
LSUIElement = true  // Dock 아이콘 숨김
LSMinimumSystemVersion = 14.0  // macOS Sonoma 이상
```

### 서명 (선택사항)

개인 사용이므로 서명 없이 배포 가능
- 첫 실행: 우클릭 → 열기
- 또는: System Settings → Privacy & Security → "Open Anyway"

### GitHub Release

```bash
# 태그 생성
git tag v1.0.0
git push origin v1.0.0

# 빌드 파일 첨부
- ClaudeUsageMenuBar.app.zip
```

---

## 🔮 향후 개선 사항

### 기능 추가
- [ ] 사용량 히스토리 그래프
- [ ] 여러 계정 지원
- [ ] Export 기능 (CSV)
- [ ] Claude Code CLI 연동

### UX 개선
- [ ] 위젯 지원
- [ ] 단축키 커스터마이징
- [ ] 테마 커스터마이징

### 기술 개선
- [ ] SwiftData로 로컬 저장
- [ ] App Intents 지원
- [ ] Widgets (macOS 14+)

---

## 📚 참고 자료

### 오픈소스 참고
- [Claude Usage Tracker](https://github.com/hamed-elfayome/Claude-Usage-Tracker)
- [ClaudeBar](https://github.com/tddworks/ClaudeBar)

### Apple 문서
- [NSStatusBar](https://developer.apple.com/documentation/appkit/nsstatusbar)
- [NSPopover](https://developer.apple.com/documentation/appkit/nspopover)
- [Keychain Services](https://developer.apple.com/documentation/security/keychain_services)

### SwiftUI
- [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/macos)

---

## ⚖️ 라이선스

MIT License - 자유롭게 사용, 수정, 배포 가능

---

## 👤 작성자

개인 프로젝트 - macOS용 Claude 사용량 모니터링 앱

---

**마지막 업데이트**: 2025-02-11
**버전**: 1.0.0 (기획)
