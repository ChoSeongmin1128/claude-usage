# ClaudeUsage

macOS 메뉴바에서 Claude.ai 사용량을 실시간으로 모니터링하는 네이티브 앱

## 🚀 빠른 시작

**Phase 1 설정을 시작하려면 [SETUP-GUIDE.md](docs/SETUP-GUIDE.md)를 참고하세요.**

## 📋 프로젝트 상태

### ✅ 완료된 작업
- [x] 프로젝트 기획 및 스펙 작성
- [x] Phase 1 소스 코드 생성
  - [x] Models (UsageModels.swift, APIError.swift)
  - [x] Services (ClaudeAPIService.swift)
  - [x] Utilities (Logger.swift)
  - [x] App (ClaudeUsageApp.swift, AppDelegate.swift)

### 📝 다음 단계
1. ⏳ Xcode 프로젝트 생성 (사용자 작업)
2. ⏳ Session Key 설정
3. ⏳ 빌드 및 실행 확인

## 📁 프로젝트 구조

```
claude-usage/
├── App/                          # 앱 진입점 및 메뉴바 관리
├── Models/                       # 데이터 모델
├── Services/                     # API 호출 서비스
├── Utilities/                    # 유틸리티 함수
├── docs/                         # 📚 문서
│   ├── SETUP-GUIDE.md           # 🔥 설정 가이드 (시작하기)
│   ├── claude-usage-menubar-spec.md      # 상세 스펙
│   └── implementation-plan.md            # 구현 계획서
└── README.md                     # 👈 지금 보고 있는 파일
```

## 📚 문서

- **[설정 가이드](docs/SETUP-GUIDE.md)** - Xcode 프로젝트 생성 및 실행 방법
- **[상세 스펙](docs/claude-usage-menubar-spec.md)** - 전체 기능 명세
- **[구현 계획](docs/implementation-plan.md)** - Phase 1-7 개발 계획

## 🎯 주요 기능 (Phase 1)

- ✅ 메뉴바에 실시간 사용량 표시
- ✅ Claude.ai API 연동
- ✅ 5초마다 자동 갱신
- ✅ 에러 처리 및 재시도

## 🔜 향후 계획

- [ ] Phase 2: Popover UI + 3가지 표시 모드
- [ ] Phase 3: 설정 창 + Keychain
- [ ] Phase 4: 알림 시스템
- [ ] Phase 5: 키보드 단축키
- [ ] Phase 6: 에러 처리 강화
- [ ] Phase 7: 테스트 및 배포

## 🛠 기술 스택

- **언어**: Swift 5.0+
- **플랫폼**: macOS 14.0+ (Sonoma)
- **UI**: SwiftUI + AppKit
- **아키텍처**: Actor-based concurrency

## 📝 라이선스

MIT License - 자유롭게 사용, 수정, 배포 가능

---

**현재 Phase**: 1 of 7
**상태**: 소스 코드 생성 완료 ✅ → Xcode 설정 대기 중 ⏳
