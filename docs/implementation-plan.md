# Claude Usage Menu Bar - 구현 계획서

## 📋 프로젝트 정보

- **프로젝트명**: Claude Usage Menu Bar
- **타겟 플랫폼**: macOS 14.0+ (Sonoma)
- **개발 언어**: Swift 5.0+
- **UI 프레임워크**: SwiftUI
- **UI 언어**: 한글 (기술 용어 제외)
- **개발 방식**: 단계별 점진적 개발
- **최종 목표**: 완전 기능 구현 (설정 + 알림 포함)

---

## 🎯 개발 목표

### MVP 범위
- ✅ 메뉴바 실시간 사용량 표시 (3가지 모드)
- ✅ Popover 상세 정보 (5시간/주간/Sonnet)
- ✅ 동적 색상 그라데이션 시스템
- ✅ 설정 창 및 Keychain 연동
- ✅ 자동 새로고침 (5-120초)
- ✅ 알림 시스템 (임계값 경고)
- ✅ 키보드 단축키 지원

### 제외 사항 (향후 개선)
- 사용량 히스토리 그래프
- 여러 계정 지원
- CSV Export
- 위젯 지원

---

## 📅 개발 일정

### Phase 1: 기본 인프라 구축 (3-4일)
**목표**: API 연동과 메뉴바 기본 표시

#### 1.1 프로젝트 설정
- [ ] Xcode 프로젝트 생성
- [ ] Git 저장소 초기화
- [ ] 프로젝트 구조 설정
- [ ] Info.plist 설정 (`LSUIElement = true`)

#### 1.2 데이터 모델 구현
```swift
// Models/UsageModels.swift
struct ClaudeUsageResponse: Codable {
    let fiveHour: UsageWindow
    let sevenDay: UsageWindow
    let sevenDayOpus: UsageWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
    }
}

struct UsageWindow: Codable {
    let utilizationPercentage: Double
    let resetAt: String  // ISO 8601

    enum CodingKeys: String, CodingKey {
        case utilizationPercentage = "utilization_percentage"
        case resetAt = "reset_at"
    }
}
```

#### 1.3 API Service 구현
- [ ] ClaudeAPIService Actor 구현
- [ ] Organization ID 자동 추출 로직
- [ ] 사용량 데이터 파싱
- [ ] 에러 처리 (APIError enum)

```swift
// Services/ClaudeAPIService.swift
actor ClaudeAPIService {
    private let sessionKey: String

    func fetchOrganizationID() async throws -> String {
        // 구현
    }

    func fetchUsage(organizationID: String) async throws -> ClaudeUsageResponse {
        // 구현
    }
}
```

#### 1.4 메뉴바 기본 표시
- [ ] AppDelegate 구성
- [ ] NSStatusBar 연동
- [ ] 기본 아이콘 표시
- [ ] 퍼센트 텍스트 표시

**완료 조건**:
- ✅ API에서 사용량 데이터를 성공적으로 받아옴
- ✅ 메뉴바에 "67%" 형태로 표시됨
- ✅ 에러 발생 시 "⚠️" 표시

---

### Phase 2: UI 구현 (4-5일)
**목표**: Popover와 3가지 표시 모드 구현

#### 2.1 동적 색상 시스템
```swift
// Utilities/ColorProvider.swift
func getStatusColor(percentage: Double) -> Color {
    if percentage >= 100 {
        return Color.gray
    }

    let hue = (120.0 - (percentage * 1.2)) / 360.0
    let saturation = 1.0
    let brightness = percentage > 50 ? 0.5 : 0.4

    return Color(hue: hue, saturation: saturation, brightness: brightness)
}
```

#### 2.2 메뉴바 표시 모드
- [ ] **모드 1**: 퍼센트 (`67%`)
- [ ] **모드 2**: 배터리바 (`████████▒▒▒▒`)
- [ ] **모드 3**: 원형 로딩 (`◐`)
- [ ] 동적 색상 적용

#### 2.3 Popover 인터페이스
```
┌────────────────────────────────────┐
│  메뉴 표시: [5시간] [주간]    [🔄] │
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │
│                                    │
│  📊 5시간 세션                67%  │
│  ████████████▒▒▒▒                 │
│  2시간 34분 후 리셋               │
│  ────────────────────────────────  │
│                                    │
│  📅 주간 한도 (전체 모델)     45%  │
│  ████████▒▒▒▒▒▒▒▒                 │
│  4일 12시간 후 리셋               │
│  ────────────────────────────────  │
│                                    │
│  🎯 Sonnet (주간)             32%  │
│  ██████▒▒▒▒▒▒▒▒▒▒                 │
│  4일 12시간 후 리셋               │
│  ────────────────────────────────  │
│                                    │
│  [사용량 상세 보기 →]             │
│  [⚙️ 설정]              [종료]    │
└────────────────────────────────────┘
```

- [ ] UsageSectionView 컴포넌트
- [ ] ProgressBarView (동적 색상 적용)
- [ ] TimeFormatter (상대 시간 표시)
- [ ] Segmented Control (5시간/주간 전환)

#### 2.4 Option+클릭 토글
- [ ] 클릭 이벤트 핸들링
- [ ] Option 키 감지
- [ ] 메뉴바 텍스트 전환 애니메이션

**완료 조건**:
- ✅ 3가지 표시 모드 전환 가능
- ✅ 퍼센트에 따라 색상이 동적으로 변함
- ✅ Popover 클릭 시 정상 표시
- ✅ 상대 시간 정확하게 계산됨

---

### Phase 3: 설정 및 인증 (3-4일)
**목표**: 사용자 설정 관리 및 보안 강화

#### 3.1 Keychain 연동
```swift
// Services/KeychainManager.swift
class KeychainManager {
    private let service = "com.yourname.claude-usage-menubar"
    private let account = "claude-session-key"

    func save(_ sessionKey: String) throws {
        // SecItemAdd 구현
    }

    func load() throws -> String? {
        // SecItemCopyMatching 구현
    }

    func delete() throws {
        // SecItemDelete 구현
    }
}
```

#### 3.2 설정 창 UI
```
┌──────── 설정 ────────┐
│                      │
│ 🔑 인증              │
│ ┌──────────────────┐ │
│ │ 세션 키          │ │
│ │ sk-ant-sid01-... │ │
│ └──────────────────┘ │
│ [연결 테스트]        │
│                      │
│ 🎨 디스플레이        │
│ 메뉴바 스타일:       │
│ ○ 퍼센트            │
│ ● 배터리바          │
│ ○ 원형              │
│                      │
│ 아이콘 표시: ☑       │
│                      │
│ 🔄 새로고침          │
│ 간격: [5] 초         │
│ ────────────────     │
│ 자동 새로고침: ☑     │
│                      │
│ 🔔 알림              │
│ ☑ 75% 알림           │
│ ☑ 90% 알림           │
│ ☑ 95% 알림           │
│                      │
│ 🌙 절전 모드         │
│ ☑ 배터리 사용 시     │
│   새로고침 감소      │
│                      │
│   [저장]  [취소]     │
└──────────────────────┘
```

#### 3.3 AppSettings 모델
```swift
// Models/AppSettings.swift
struct AppSettings: Codable {
    var menuBarStyle: MenuBarStyle = .batteryBar
    var showIcon: Bool = true
    var refreshInterval: TimeInterval = 5
    var autoRefresh: Bool = true
    var alertAt75: Bool = true
    var alertAt90: Bool = true
    var alertAt95: Bool = true
    var reducedRefreshOnBattery: Bool = true
}

enum MenuBarStyle: String, Codable {
    case percentage = "percentage"
    case batteryBar = "battery_bar"
    case circular = "circular"
}
```

#### 3.4 설정 저장
- [ ] UserDefaults 연동
- [ ] 설정 변경 시 실시간 반영
- [ ] 유효성 검증

**완료 조건**:
- ✅ Session Key가 Keychain에 안전하게 저장됨
- ✅ 설정 변경 시 즉시 UI에 반영됨
- ✅ 연결 테스트 버튼이 정상 작동
- ✅ 앱 재시작 후 설정 유지됨

---

### Phase 4: 자동화 및 알림 (2-3일)
**목표**: 자동 새로고침과 임계값 알림

#### 4.1 자동 새로고침
```swift
// Services/RefreshService.swift
actor RefreshService {
    private var timer: Timer?
    private var interval: TimeInterval

    func start() {
        timer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: true
        ) { [weak self] _ in
            Task {
                await self?.refresh()
            }
        }
    }

    func stop() {
        timer?.invalidate()
    }

    private func refresh() async {
        // API 호출 및 UI 업데이트
    }
}
```

#### 4.2 배터리 모드 감지
```swift
// Utilities/PowerMonitor.swift
class PowerMonitor: ObservableObject {
    @Published var isOnBattery: Bool = false

    init() {
        // IOPSNotificationCreateRunLoopSource 사용
    }
}
```

#### 4.3 알림 시스템
```swift
// Services/NotificationManager.swift
class NotificationManager {
    private var alerted75 = false
    private var alerted90 = false
    private var alerted95 = false

    func checkThreshold(percentage: Double) {
        if percentage >= 95 && !alerted95 {
            sendNotification(
                title: "Claude 사용량 경고",
                body: "5시간 세션의 95%를 사용했습니다"
            )
            alerted95 = true
        } else if percentage >= 90 && !alerted90 {
            sendNotification(
                title: "Claude 사용량 주의",
                body: "5시간 세션의 90%를 사용했습니다"
            )
            alerted90 = true
        } else if percentage >= 75 && !alerted75 {
            sendNotification(
                title: "Claude 사용량 안내",
                body: "5시간 세션의 75%를 사용했습니다"
            )
            alerted75 = true
        }
    }

    func reset() {
        alerted75 = false
        alerted90 = false
        alerted95 = false
    }
}
```

#### 4.4 알림 권한
- [ ] UNUserNotificationCenter 권한 요청
- [ ] 앱 최초 실행 시 권한 안내
- [ ] 설정에서 알림 on/off 가능

**완료 조건**:
- ✅ 설정한 간격대로 자동 새로고침됨
- ✅ 배터리 사용 시 간격이 30초로 변경됨
- ✅ 임계값 도달 시 알림이 정확히 1회만 표시됨
- ✅ 세션 리셋 시 알림 플래그 초기화됨

---

### Phase 5: 키보드 단축키 및 UX 개선 (2일)
**목표**: 사용성 향상

#### 5.1 키보드 단축키
```swift
// App/AppDelegate.swift
func setupKeyboardShortcuts() {
    // ⌘R: 수동 새로고침
    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "r" {
            self.refreshUsage()
            return nil
        }
        return event
    }

    // ⌘,: 설정 열기
    // ⌘U: Usage 페이지 열기
    // ⌘Q: 앱 종료
}
```

#### 5.2 애니메이션
```swift
// 값 변경 시 부드러운 전환
withAnimation(.easeInOut(duration: 0.2)) {
    updateMenuBar()
}

// 진행바 애니메이션
ProgressView(value: percentage)
    .animation(.easeInOut, value: percentage)
```

#### 5.3 툴팁
```swift
statusItem.button?.toolTip = """
5시간 세션: 67%
(Option+클릭하여 주간 한도 보기)
"""
```

#### 5.4 다크 모드 지원
- [ ] @Environment(\.colorScheme) 사용
- [ ] SF Symbols 자동 대응
- [ ] 색상 시스템 라이트/다크 모드 최적화

**완료 조건**:
- ✅ 모든 키보드 단축키 작동
- ✅ UI 전환이 부드럽게 애니메이션됨
- ✅ 라이트/다크 모드 자동 전환
- ✅ 툴팁이 정확한 정보 표시

---

### Phase 6: 에러 처리 및 안정화 (2-3일)
**목표**: 프로덕션 품질 확보

#### 6.1 에러 타입 정의
```swift
// Models/APIError.swift
enum APIError: Error, LocalizedError {
    case invalidSessionKey
    case networkError(Error)
    case parseError
    case rateLimited
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidSessionKey:
            return "세션 키가 유효하지 않습니다. 설정에서 확인해주세요."
        case .networkError(let error):
            return "네트워크 연결 실패: \(error.localizedDescription)"
        case .parseError:
            return "응답 데이터 파싱 실패"
        case .rateLimited:
            return "API 요청 제한에 도달했습니다. 잠시 후 다시 시도해주세요."
        case .serverError(let code):
            return "서버 오류 (코드: \(code))"
        }
    }
}
```

#### 6.2 에러 UI
```swift
// Views/ErrorView.swift
struct ErrorView: View {
    let error: APIError
    let retryAction: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundColor(.orange)

            Text("데이터를 가져올 수 없습니다")
                .font(.headline)

            Text(error.errorDescription ?? "알 수 없는 오류")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            HStack {
                Button("다시 시도") {
                    retryAction()
                }
                .buttonStyle(.borderedProminent)

                Button("설정 확인") {
                    // 설정 창 열기
                }
            }
        }
        .padding()
    }
}
```

#### 6.3 로깅 시스템
```swift
// Utilities/Logger.swift
enum LogLevel {
    case debug, info, warning, error
}

struct Logger {
    static func log(_ message: String, level: LogLevel = .info) {
        #if DEBUG
        let emoji = switch level {
            case .debug: "🔍"
            case .info: "ℹ️"
            case .warning: "⚠️"
            case .error: "❌"
        }
        print("\(emoji) [\(level)] \(message)")
        #endif
    }
}
```

#### 6.4 재시도 로직
```swift
func fetchWithRetry(maxAttempts: Int = 3) async throws -> ClaudeUsageResponse {
    var lastError: Error?

    for attempt in 1...maxAttempts {
        do {
            return try await fetchUsage()
        } catch {
            lastError = error
            if attempt < maxAttempts {
                try await Task.sleep(nanoseconds: UInt64(attempt * 1_000_000_000))
            }
        }
    }

    throw lastError ?? APIError.networkError(NSError())
}
```

**완료 조건**:
- ✅ 모든 에러 케이스에 적절한 메시지 표시
- ✅ 네트워크 오류 시 자동 재시도
- ✅ 사용자에게 명확한 액션 제공
- ✅ 개발 중 로깅으로 디버깅 용이

---

### Phase 7: 테스트 및 배포 (2-3일)
**목표**: QA 및 최종 릴리스

#### 7.1 수동 테스트 체크리스트

**기본 기능**
- [ ] 메뉴바 아이콘 정상 표시
- [ ] 퍼센트 정확하게 표시됨
- [ ] 3가지 표시 모드 전환 확인
- [ ] 동적 색상이 올바르게 변함

**Popover**
- [ ] 클릭 시 Popover 열림
- [ ] 5시간/주간 전환 정상 작동
- [ ] 상대 시간 정확하게 계산
- [ ] 진행바 색상 일치

**Option+클릭**
- [ ] 메뉴바 표시 전환 확인
- [ ] 애니메이션 부드러움

**설정**
- [ ] Session Key 저장/로드
- [ ] 연결 테스트 작동
- [ ] 설정 변경 즉시 반영
- [ ] 앱 재시작 후 설정 유지

**자동 새로고침**
- [ ] 설정한 간격대로 갱신
- [ ] 배터리 모드 감지
- [ ] 배터리 사용 시 간격 변경

**알림**
- [ ] 75% 알림 1회만 표시
- [ ] 90% 알림 1회만 표시
- [ ] 95% 알림 1회만 표시
- [ ] 세션 리셋 후 알림 플래그 초기화

**키보드 단축키**
- [ ] ⌘R: 새로고침
- [ ] ⌘,: 설정 열기
- [ ] ⌘U: Usage 페이지
- [ ] ⌘Q: 앱 종료

**다크 모드**
- [ ] 라이트 모드 정상 표시
- [ ] 다크 모드 정상 표시
- [ ] 자동 전환 확인

**에러 처리**
- [ ] 잘못된 Session Key 처리
- [ ] 네트워크 오류 처리
- [ ] API 제한 처리
- [ ] 재시도 로직 작동

#### 7.2 엣지 케이스 테스트
- [ ] Session Key 없이 앱 실행
- [ ] 인터넷 연결 없음
- [ ] API 응답 지연 (타임아웃)
- [ ] 100% 사용 시 회색 표시
- [ ] 세션 리셋 시점 전후
- [ ] 배터리 모드 전환

#### 7.3 성능 테스트
- [ ] CPU 사용률 모니터링
- [ ] 메모리 누수 확인
- [ ] 장시간 실행 안정성

#### 7.4 빌드 및 배포
```bash
# Release 빌드
xcodebuild -scheme ClaudeUsageMenuBar \
  -configuration Release \
  -archivePath build/ClaudeUsageMenuBar.xcarchive \
  archive

# 앱 번들 생성
xcodebuild -exportArchive \
  -archivePath build/ClaudeUsageMenuBar.xcarchive \
  -exportPath build \
  -exportOptionsPlist ExportOptions.plist

# ZIP 압축
cd build
zip -r ClaudeUsageMenuBar.app.zip ClaudeUsageMenuBar.app
```

#### 7.5 GitHub Release
- [ ] Git 태그 생성 (`v1.0.0`)
- [ ] Release Notes 작성
- [ ] 빌드 파일 업로드
- [ ] README 업데이트

**완료 조건**:
- ✅ 모든 테스트 항목 통과
- ✅ 알려진 버그 없음
- ✅ 릴리스 빌드 생성됨
- ✅ GitHub에 배포됨

---

## 🌐 한글 UI 문구 정리

### 메뉴바
- 일반 클릭 툴팁: `"5시간 세션: 67%\n(Option+클릭하여 주간 한도 보기)"`
- Option+클릭 툴팁: `"주간 한도: 45%\n(Option+클릭하여 5시간 세션 보기)"`
- 에러 표시: `"⚠️ 데이터 오류"`

### Popover
- Segmented Control: `["5시간", "주간"]`
- 섹션 제목:
  - `"📊 5시간 세션"`
  - `"📅 주간 한도 (전체 모델)"`
  - `"🎯 Sonnet (주간)"`
- 리셋 시간: `"{시간} 후 리셋"` (예: "2시간 34분 후 리셋")
- 버튼:
  - `"사용량 상세 보기 →"`
  - `"⚙️ 설정"`
  - `"종료"`

### 설정 창
- 창 제목: `"설정"`
- 섹션:
  - `"🔑 인증"`
  - `"🎨 디스플레이"`
  - `"🔄 새로고침"`
  - `"🔔 알림"`
  - `"🌙 절전 모드"`
- 필드:
  - `"세션 키"` (placeholder: `"sk-ant-sid01-..."`)
  - `"연결 테스트"`
  - `"메뉴바 스타일:"`
    - `"퍼센트"`
    - `"배터리바"`
    - `"원형"`
  - `"아이콘 표시"`
  - `"간격: {숫자} 초"`
  - `"자동 새로고침"`
  - `"75% 알림"`, `"90% 알림"`, `"95% 알림"`
  - `"배터리 사용 시 새로고침 감소"`
- 버튼:
  - `"저장"`
  - `"취소"`

### 알림
- 75%: `"Claude 사용량 안내"` / `"5시간 세션의 75%를 사용했습니다"`
- 90%: `"Claude 사용량 주의"` / `"5시간 세션의 90%를 사용했습니다"`
- 95%: `"Claude 사용량 경고"` / `"5시간 세션의 95%를 사용했습니다"`
- 리셋: `"Claude 세션 리셋"` / `"5시간 세션이 리셋되었습니다"`
- 에러: `"Claude 사용량 오류"` / `"데이터를 가져올 수 없습니다"`

### 에러 메시지
- `"세션 키가 유효하지 않습니다. 설정에서 확인해주세요."`
- `"네트워크 연결 실패: {오류 내용}"`
- `"응답 데이터 파싱 실패"`
- `"API 요청 제한에 도달했습니다. 잠시 후 다시 시도해주세요."`
- `"서버 오류 (코드: {코드})"`
- `"데이터를 가져올 수 없습니다"`
- `"다시 시도"`
- `"설정 확인"`

### 시간 포맷
```swift
// TimeFormatter.swift
func formatRelativeTime(resetAt: String) -> String {
    // "2시간 34분 후 리셋"
    // "45분 후 리셋"
    // "4일 12시간 후 리셋"
    // "곧 리셋"
}
```

---

## 🏗️ 프로젝트 구조

```
ClaudeUsageMenuBar/
├── App/
│   ├── ClaudeUsageApp.swift          # @main
│   └── AppDelegate.swift             # 메뉴바, 이벤트 관리
│
├── Views/
│   ├── PopoverView.swift             # 메인 Popover UI
│   ├── UsageSectionView.swift        # 사용량 섹션 컴포넌트
│   ├── SettingsView.swift            # 설정 창
│   ├── ErrorView.swift               # 에러 표시 UI
│   └── Components/
│       ├── ProgressBarView.swift     # 동적 색상 진행바
│       ├── BatteryIconView.swift     # 배터리 아이콘
│       └── CircularProgressView.swift # 원형 인디케이터
│
├── Services/
│   ├── ClaudeAPIService.swift        # API 호출 Actor
│   ├── KeychainManager.swift         # Keychain 관리
│   ├── NotificationManager.swift     # 알림 관리
│   └── RefreshService.swift          # 자동 새로고침 Actor
│
├── Models/
│   ├── UsageModels.swift             # API 응답 모델
│   ├── AppSettings.swift             # 설정 모델
│   └── APIError.swift                # 에러 타입
│
├── Utilities/
│   ├── TimeFormatter.swift           # 상대 시간 포맷
│   ├── ColorProvider.swift           # 동적 색상 계산
│   ├── IconGenerator.swift           # 메뉴바 아이콘 생성
│   ├── PowerMonitor.swift            # 배터리 상태 감지
│   └── Logger.swift                  # 로깅 유틸
│
└── Resources/
    ├── Assets.xcassets               # 아이콘, 이미지
    ├── Info.plist
    └── ExportOptions.plist           # 배포 옵션
```

---

## 🔧 기술 스택 상세

### 핵심 프레임워크
- **SwiftUI**: UI 구성
- **AppKit**: NSStatusBar, NSPopover
- **Combine**: 비동기 데이터 바인딩
- **Concurrency**: Actor, async/await

### 시스템 API
- **Security.framework**: Keychain Services
- **UserNotifications.framework**: macOS 알림
- **IOKit**: 배터리 상태 모니터링

### 네트워킹
- **URLSession**: API 호출
- **JSONDecoder**: 응답 파싱

### 데이터 저장
- **Keychain**: Session Key (보안)
- **UserDefaults**: 설정 (비민감 데이터)

---

## 📊 개발 체크리스트

### Phase 1: 기본 인프라 ✅
- [ ] 프로젝트 설정
- [ ] 데이터 모델
- [ ] API Service
- [ ] 메뉴바 기본 표시

### Phase 2: UI 구현 ⏳
- [ ] 동적 색상 시스템
- [ ] 메뉴바 표시 모드 (3종)
- [ ] Popover 인터페이스
- [ ] Option+클릭 토글

### Phase 3: 설정 및 인증 ⏳
- [ ] Keychain 연동
- [ ] 설정 창 UI
- [ ] AppSettings 모델
- [ ] 설정 저장/로드

### Phase 4: 자동화 및 알림 ⏳
- [ ] 자동 새로고침
- [ ] 배터리 모드 감지
- [ ] 알림 시스템
- [ ] 알림 권한

### Phase 5: UX 개선 ⏳
- [ ] 키보드 단축키
- [ ] 애니메이션
- [ ] 툴팁
- [ ] 다크 모드

### Phase 6: 안정화 ⏳
- [ ] 에러 처리
- [ ] 에러 UI
- [ ] 로깅 시스템
- [ ] 재시도 로직

### Phase 7: 배포 ⏳
- [ ] 수동 테스트
- [ ] 엣지 케이스
- [ ] 성능 테스트
- [ ] GitHub Release

---

## 🎯 성공 지표

### 기능 완성도
- ✅ 모든 Phase 1-7 완료
- ✅ 테스트 체크리스트 100% 통과

### 품질
- CPU 사용률 < 1% (idle)
- 메모리 사용 < 50MB
- API 응답 시간 < 2초
- 알림 정확도 100%

### 사용성
- 앱 실행 후 10초 이내 첫 데이터 표시
- 설정 변경 즉시 반영
- 에러 발생 시 명확한 가이드

---

## 📝 다음 단계

### 즉시 시작 가능
1. **Xcode 프로젝트 생성**
   ```bash
   # 새 macOS 앱 프로젝트 생성
   # Bundle ID: com.yourname.claude-usage-menubar
   # Interface: SwiftUI
   # Language: Swift
   ```

2. **Git 초기화**
   ```bash
   git init
   git add .
   git commit -m "Initial commit: Project structure"
   ```

3. **Phase 1 시작**
   - UsageModels.swift 작성
   - ClaudeAPIService.swift 스켈레톤 구현
   - 테스트 API 호출

### 필요한 정보
- [ ] Session Key 준비 (claude.ai에서 추출)
- [ ] Organization ID 확인
- [ ] Xcode 15.0+ 설치 확인
- [ ] macOS 14.0+ 테스트 환경

---

## 📚 참고 문서

### Apple 공식 문서
- [NSStatusBar](https://developer.apple.com/documentation/appkit/nsstatusbar)
- [NSPopover](https://developer.apple.com/documentation/appkit/nspopover)
- [Keychain Services](https://developer.apple.com/documentation/security/keychain_services)
- [UserNotifications](https://developer.apple.com/documentation/usernotifications)

### 커뮤니티
- [Claude Usage Tracker](https://github.com/hamed-elfayome/Claude-Usage-Tracker)
- [ClaudeBar](https://github.com/tddworks/ClaudeBar)

---

**작성일**: 2026-02-11
**버전**: 1.0.0
**상태**: 구현 준비 완료 ✅
