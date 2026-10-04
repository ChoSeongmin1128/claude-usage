import Foundation

enum AppMotionMode: String, CaseIterable, Sendable {
    case instant, smooth, custom

    var title: String {
        switch self {
        case .instant: return "즉시"
        case .smooth: return "부드러움"
        case .custom: return "사용자 설정"
        }
    }
}

enum AppMotionCategory: String, CaseIterable, Sendable {
    case popoverPresentation, popoverResize, navigation, disclosure, itemChanges, usageValue

    var title: String {
        switch self {
        case .popoverPresentation: return "팝오버 열기·닫기"
        case .popoverResize: return "팝오버 크기 전환"
        case .navigation: return "설정 탭·시작하기 단계 전환"
        case .disclosure: return "상세 항목 접기·펼치기"
        case .itemChanges: return "표시 항목 이동·숨기기"
        case .usageValue: return "사용량 막대 갱신"
        }
    }
}

struct AppMotionPreferences: Equatable, Sendable {
    var mode: AppMotionMode = .instant
    var enabledCategories: Set<AppMotionCategory> = []

    func allows(_ category: AppMotionCategory, reduceMotion: Bool) -> Bool {
        guard !reduceMotion else { return false }
        switch mode {
        case .instant: return false
        case .smooth: return true
        case .custom: return enabledCategories.contains(category)
        }
    }

    static func load(from defaults: UserDefaults) -> Self {
        let value: Self
        if let stored = defaults.dictionary(forKey: "motionPreferences"),
            let rawMode = stored["mode"] as? String, let mode = AppMotionMode(rawValue: rawMode)
        {
            value = Self(
                mode: mode,
                enabledCategories: Set(
                    (stored["enabled"] as? [String] ?? []).compactMap(AppMotionCategory.init(rawValue:))))
        } else if defaults.string(forKey: "popoverTransitionStyle") == "smooth" {
            value = Self(mode: .custom, enabledCategories: [.popoverPresentation, .popoverResize])
        } else {
            value = Self()
        }
        value.persist(to: defaults)
        defaults.removeObject(forKey: "popoverTransitionStyle")
        return value
    }

    func persist(to defaults: UserDefaults) {
        defaults.set(
            ["mode": mode.rawValue, "enabled": enabledCategories.map(\.rawValue).sorted()], forKey: "motionPreferences")
    }
}

/// 시스템 "동작 줄이기"의 위치. macOS 26부터 손쉬운 사용 > 동작으로 옮겨졌다.
nonisolated enum SystemReduceMotionSetting {
    static func location(for version: OperatingSystemVersion) -> String {
        version.majorVersion >= 26 ? "손쉬운 사용 > 동작" : "손쉬운 사용 > 디스플레이"
    }

    // 모르는 앵커는 손쉬운 사용 첫 화면으로 열리므로 안내 문구에 위치를 함께 적는다.
    static func url(for version: OperatingSystemVersion) -> URL? {
        URL(
            string: version.majorVersion >= 26
                ? "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?Motion"
                : "x-apple.systempreferences:com.apple.preference.universalaccess?Seeing_Display")
    }
}
