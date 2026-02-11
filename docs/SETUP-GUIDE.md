# ClaudeUsage Phase 1 - 설정 가이드

## 📋 생성된 파일 목록

```
/Users/seongmin/Personal/claude-usage/
├── App/
│   ├── ClaudeUsageApp.swift       ✅ 생성됨
│   └── AppDelegate.swift          ✅ 생성됨
├── Models/
│   ├── UsageModels.swift          ✅ 생성됨
│   └── APIError.swift             ✅ 생성됨
├── Services/
│   └── ClaudeAPIService.swift     ✅ 생성됨
└── Utilities/
    └── Logger.swift               ✅ 생성됨
```

---

## 🚀 Xcode 프로젝트 설정 (단계별)

### 1단계: Xcode 프로젝트 생성

1. **Xcode 실행**
2. **File → New → Project** (또는 `⌘⇧N`)
3. **macOS → App** 선택
4. **Next** 클릭
5. 다음 정보 입력:
   - **Product Name**: `ClaudeUsage`
   - **Team**: `None` (개인 사용)
   - **Organization Identifier**: `com.yourname` (원하는 이름)
   - **Bundle Identifier**: 자동 생성됨 (예: `com.yourname.ClaudeUsage`)
   - **Interface**: `SwiftUI` ✅
   - **Language**: `Swift` ✅
   - **Storage**: `None` 선택
   - **Include Tests**: 체크 해제 ❌
6. **Next** 클릭
7. **저장 위치 선택**:
   ```
   /Users/seongmin/Personal/claude-usage/
   ```
   ⚠️ **중요**: 현재 디렉토리의 **상위 폴더**를 선택한 후,
   하단의 "Create Git repository" 체크 해제
8. **Create** 클릭

→ Xcode가 `ClaudeUsage` 프로젝트를 생성합니다.

---

### 2단계: 기존 파일 삭제 및 소스 파일 추가

Xcode가 자동으로 생성한 파일들을 삭제하고, 우리가 만든 파일들을 추가합니다.

#### 2.1 자동 생성된 파일 삭제

**Project Navigator**에서 다음 파일들을 삭제:
1. `ClaudeUsageApp.swift` (자동 생성된 것)
2. `ContentView.swift`
3. `Assets.xcassets` (일단 삭제, 필요하면 나중에 추가)

**삭제 방법**: 파일 우클릭 → Delete → **Move to Trash** 선택

#### 2.2 우리 소스 파일 추가

**Project Navigator**에서 프로젝트 루트 우클릭 → **Add Files to "ClaudeUsage"...**

다음 **폴더 전체**를 드래그 앤 드롭으로 추가:
```
☑️ App/
☑️ Models/
☑️ Services/
☑️ Utilities/
```

**옵션 설정**:
- ✅ **Copy items if needed** 체크
- ✅ **Create groups** 선택
- ✅ **Add to targets**: ClaudeUsage 체크

**Add** 클릭

---

### 3단계: Info.plist 설정

Xcode 14+에서는 Info.plist 파일이 자동으로 생성되지 않을 수 있습니다.

#### 방법 1: Target Settings에서 설정 (추천)

1. **Project Navigator**에서 프로젝트 아이콘 클릭
2. **TARGETS → ClaudeUsage** 선택
3. **Info** 탭 클릭
4. **Custom macOS Application Target Properties** 섹션에서:
   - 빈 공간 우클릭 → **Add Row**
   - Key: `Application is agent (UIElement)` 입력 (자동완성됨)
     - 또는 `LSUIElement` 입력
   - Type: `Boolean`
   - Value: `YES` ✅

#### 방법 2: Info.plist 파일 직접 추가

1. **File → New → File**
2. **Resource → Property List** 선택
3. 파일명: `Info.plist`
4. 다음 내용 추가:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
```

5. **Project → TARGETS → Build Settings** → **Info.plist File**에 경로 설정:
   ```
   ClaudeUsage/Info.plist
   ```

---

### 4단계: Session Key 설정

⚠️ **중요**: API 호출을 위해 Session Key가 필요합니다.

1. **Services/ClaudeAPIService.swift** 열기
2. 21번째 줄 찾기:
   ```swift
   private let sessionKey = "YOUR_SESSION_KEY_HERE"
   ```
3. `YOUR_SESSION_KEY_HERE`를 실제 Session Key로 교체

#### Session Key 가져오기

1. **브라우저에서 claude.ai 로그인**
2. **개발자 도구 열기**:
   - Chrome/Edge: `F12` 또는 `Cmd+Option+I`
   - Safari: `Cmd+Option+C`
3. **Application (또는 Storage) 탭** 선택
4. 좌측 메뉴: **Cookies → https://claude.ai**
5. **sessionKey** 항목 찾기
6. Value 복사 (형식: `sk-ant-sid01-...`)
7. ClaudeAPIService.swift에 붙여넣기:
   ```swift
   private let sessionKey = "sk-ant-sid01-abcdef12345..."
   ```

⚠️ **보안 주의**:
- Session Key는 **절대 Git에 커밋하지 마세요**
- `.gitignore`에 다음 추가:
  ```
  # Session Key가 포함된 파일
  Services/ClaudeAPIService.swift
  ```
- Phase 3에서 Keychain으로 이동 예정

---

### 5단계: 빌드 및 실행

1. **타겟 선택**: 상단 바에서 `ClaudeUsage` → **My Mac** 선택
2. **빌드**: `⌘B`
   - 에러 없이 빌드되어야 함
3. **실행**: `⌘R`

---

## ✅ 동작 확인

### 1. 앱 실행 확인

- ✅ Dock에 아이콘이 **표시되지 않음** (LSUIElement 설정 덕분)
- ✅ 우상단 메뉴바에 `...` 표시됨

### 2. API 연동 확인

약 5초 후:
- ✅ `...` → `67%` (실제 사용량으로 변경)
- ✅ 마우스 오버 시 툴팁: "5시간 세션: 67%"

### 3. Xcode Console 로그 확인

**View → Debug Area → Show Debug Area** (`⌘⇧Y`)

정상적인 로그:
```
ℹ️ [16:30:45.123] [INFO] ClaudeUsage 앱 시작
ℹ️ [16:30:45.125] [INFO] ✅ 메뉴바 아이템 생성 완료
ℹ️ [16:30:45.127] [INFO] ✅ 자동 갱신 타이머 시작 (5초)
ℹ️ [16:30:45.130] [INFO] 사용량 데이터 요청 시작
ℹ️ [16:30:45.500] [INFO] Organization ID 가져오기 시작
ℹ️ [16:30:46.200] [INFO] ✅ Organization ID 추출 성공: uuid-xxx
ℹ️ [16:30:46.800] [INFO] ✅ 사용량 데이터 수신 성공: 67.5%
ℹ️ [16:30:46.810] [INFO] 메뉴바 업데이트: 67%
```

### 4. 에러 처리 확인

**잘못된 Session Key 테스트**:
1. Session Key를 `"invalid-key"`로 변경
2. 앱 재실행
3. 확인:
   - ✅ 메뉴바에 `⚠️` 표시
   - ✅ 툴팁: "세션 키가 유효하지 않습니다..."
   - ✅ Console: `❌ [ERROR] HTTP 에러: 401`

---

## 🐛 문제 해결

### 빌드 에러: "Cannot find type 'ClaudeUsageResponse' in scope"

**원인**: 파일이 타겟에 포함되지 않음

**해결**:
1. **Project Navigator**에서 에러가 발생한 파일 선택
2. 우측 **File Inspector** (`⌘⌥1`)
3. **Target Membership** 섹션에서 `ClaudeUsage` 체크

### 메뉴바에 아무것도 표시되지 않음

**원인**: LSUIElement 설정 문제

**해결**:
1. Info.plist에서 `LSUIElement = YES` 확인
2. 앱을 완전히 종료하고 재실행
3. 또는 `⌘Q`로 종료 후 다시 `⌘R`

### "⚠️"만 계속 표시됨

**원인**: Session Key 오류

**해결**:
1. Console 로그 확인
2. Session Key가 올바른지 확인
3. claude.ai에서 다시 로그인 후 Session Key 재추출

### Dock에 아이콘이 계속 표시됨

**원인**: LSUIElement 설정이 적용되지 않음

**해결**:
1. **Clean Build Folder**: `⌘⇧K`
2. **Product → Clean Build Folder**
3. 앱 재실행

---

## 🎯 Phase 1 완료 체크리스트

- [ ] Xcode 프로젝트 생성됨
- [ ] 6개 Swift 파일이 타겟에 포함됨
- [ ] Info.plist에 `LSUIElement = YES` 설정됨
- [ ] Session Key가 올바르게 입력됨
- [ ] 빌드 에러 없이 실행됨
- [ ] Dock에 아이콘이 표시되지 않음
- [ ] 메뉴바에 사용량 퍼센트 표시됨
- [ ] 5초마다 자동 갱신됨
- [ ] Console 로그에 정상 메시지 출력됨

---

## 📱 사용 방법

### 기본 기능
- **메뉴바 확인**: 우상단에 실시간 사용량 표시
- **툴팁 보기**: 마우스 오버 시 상세 정보
- **수동 갱신**: 메뉴바 아이콘 클릭
- **자동 갱신**: 5초마다 자동 업데이트

### 앱 종료
- `⌘Q` 또는 Activity Monitor에서 종료

### 로그인 항목 추가 (자동 실행)
1. **System Settings → General → Login Items**
2. **+** 버튼 클릭
3. `ClaudeUsage.app` 추가

---

## 🔜 다음 단계 (Phase 2)

Phase 1 완료 후:
1. ✅ API 연동 검증 완료
2. ✅ 메뉴바 표시 확인
3. → **Phase 2 시작**: Popover UI 구현

Phase 2에서 추가될 기능:
- 📊 Popover 상세 정보 표시
- 🎨 3가지 표시 모드 (퍼센트, 배터리바, 원형)
- 🌈 동적 색상 그라데이션
- ⌥ Option+클릭 토글

---

**작성일**: 2026-02-11
**Phase**: 1 of 7
**상태**: 설정 가이드 완료 ✅
