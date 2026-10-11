import Foundation

/// `AppSettings`가 값을 읽기 전에 도는 저장값 정리. 처음 정한 값을 고정하고, 이전 형식을 지금 키로 옮기고,
/// 잘못된 값을 바로잡는다. 이 단계가 끝나면 `AppSettings`는 읽기만 한다.
/// 더 읽지 않는 키 삭제(`RetiredAppDefaults`)는 각 저장소가 이전 키를 옮긴 뒤에 `AppSettings`가 마지막에 부른다.
enum AppSettingsMigration {
    static let usageDisplayModeKey = "usageDisplayMode"
    static let updateCheckIntervalKey = "updateCheckInterval"

    static func run(defaults: UserDefaults, isExistingInstall: Bool) {
        WhatsNewState.prepare(
            defaults: defaults, isExistingInstall: isExistingInstall,
            currentVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
        // 시간 형식 이전이 AGY 표시 설정을 읽으므로 AGY 설정 이전이 먼저 끝나야 한다.
        if defaults === UserDefaults.standard { _ = AntigravityApplicationBootstrap.prepareSettings() }
        pinUsageDisplayMode(defaults: defaults, isExistingInstall: isExistingInstall)
        pinResetCreditMenuBarModes(defaults: defaults, isExistingInstall: isExistingInstall)
        importNotificationRulesIfMissing(defaults: defaults)
        normalizeUpdateCheckInterval(defaults: defaults)
        unifyPopoverBehavior(defaults: defaults)
        TimeFormatUnification.migrate(defaults: defaults)
        let timeFormat = defaults.string(forKey: "timeFormat").flatMap(TimeFormatStyle.init(rawValue:)) ?? .h24
        defaults.set(timeFormat.rawValue, forKey: "timeFormat")
    }

    // MARK: - 처음 정한 값 고정

    /// 기존 사용자는 이전 기준, 새 사용자는 남은 양으로 시작한다. 저장해 두지 않으면 다음 실행부터 기존 설치로 판정된다.
    private static func pinUsageDisplayMode(defaults: UserDefaults, isExistingInstall: Bool) {
        let stored = defaults.string(forKey: usageDisplayModeKey).flatMap(UsageDisplayMode.init(rawValue:))
        let mode = stored ?? (isExistingInstall ? .legacy : .remaining)
        defaults.set(mode.rawValue, forKey: usageDisplayModeKey)
    }

    /// 기존 사용자는 끔, 새 사용자는 항상으로 시작한다. 같은 이유로 처음 정한 값을 저장한다.
    private static func pinResetCreditMenuBarModes(defaults: UserDefaults, isExistingInstall: Bool) {
        guard defaults.dictionary(forKey: AppSettings.resetCreditMenuBarKey) as? [String: String] == nil else { return }
        let initial = Dictionary(
            uniqueKeysWithValues: [AppProviderKind.claude, .codex].map {
                ($0.rawValue, (isExistingInstall ? ResetCreditMenuBarMode.off : .always).rawValue)
            })
        defaults.set(initial, forKey: AppSettings.resetCreditMenuBarKey)
    }

    // MARK: - 이전 형식 옮기기

    private static func importNotificationRulesIfMissing(defaults: UserDefaults) {
        guard NotificationThresholdStorage.load(from: defaults) == .missing else { return }
        NotificationThresholdStorage.save(legacyNotificationPresets(from: defaults), to: defaults)
    }

    /// 저장된 규칙을 읽는다. 새 버전이 쓴 형식처럼 읽지 못하면 저장값을 그대로 두고 이전 키에서 만든 규칙을 쓴다.
    static func notificationPresets(from defaults: UserDefaults) -> [NotificationPreset] {
        if case .presets(let presets) = NotificationThresholdStorage.load(from: defaults) { return presets }
        return legacyNotificationPresets(from: defaults)
    }

    private static func normalizeUpdateCheckInterval(defaults: UserDefaults) {
        guard let stored = defaults.string(forKey: updateCheckIntervalKey) else { return }
        let normalized = UpdateCheckInterval(rawValue: stored)?.normalizedForAutomaticChecks ?? .enforced
        if stored != normalized.rawValue { defaults.set(normalized.rawValue, forKey: updateCheckIntervalKey) }
    }

    /// 서비스별로 따로 있던 팝오버 고정, 간소화 설정을 하나로 합친다.
    private static func unifyPopoverBehavior(defaults: UserDefaults) {
        defaults.set(normalizedGlobalPopoverPinned(from: defaults), forKey: "popoverPinned")
        defaults.set(normalizedGlobalPopoverCompact(from: defaults), forKey: "popoverCompact")
    }

    static func normalizedGlobalPopoverPinned(from defaults: UserDefaults) -> Bool {
        (defaults.object(forKey: "popoverPinned") as? Bool)
            ?? (defaults.object(forKey: "claudePopoverPinned") as? Bool)
            ?? (defaults.object(forKey: "codexPopoverPinned") as? Bool)
            ?? (defaults.object(forKey: "\(AppProviderKind.antigravity.rawValue)PopoverPinned") as? Bool)
            ?? false
    }

    static func normalizedGlobalPopoverCompact(from defaults: UserDefaults) -> Bool {
        (defaults.object(forKey: "popoverCompact") as? Bool)
            ?? (defaults.object(forKey: "claudePopoverCompact") as? Bool)
            ?? (defaults.object(forKey: "codexPopoverCompact") as? Bool)
            ?? (defaults.object(forKey: "\(AppProviderKind.antigravity.rawValue)PopoverCompact") as? Bool)
            ?? false
    }

    /// `showPercentage`, `showDualPercentage`만 있던 버전의 값. 새 키는 사용자가 바꿀 때 처음 저장한다.
    static func percentageDisplay(from defaults: UserDefaults) -> PercentageDisplay {
        if let stored = defaults.string(forKey: "percentageDisplay") {
            return PercentageDisplay(rawValue: stored) ?? .fiveHour
        }
        guard defaults.object(forKey: "showPercentage") as? Bool ?? true else { return .none }
        return defaults.object(forKey: "showDualPercentage") as? Bool ?? false ? .dual : .fiveHour
    }

    // MARK: - 이전 알림 키

    private static func legacyNotificationPresets(from defaults: UserDefaults) -> [NotificationPreset] {
        let remainingMode = defaults.object(forKey: "alertRemainingMode") as? Bool ?? false
        return NotificationThresholdStorage.importLegacy(
            legacyStoredNotificationPresets(from: defaults, commonRemainingMode: remainingMode),
            remaining: remainingMode)
    }

    private static func legacyAlertThresholds(from defaults: UserDefaults) -> [Int] {
        if let saved = defaults.array(forKey: "alertThresholds") as? [Int], !saved.isEmpty {
            return saved
        }

        var migrated: [Int] = []
        let e1 = defaults.object(forKey: "alert1Enabled") as? Bool ?? true
        let e2 = defaults.object(forKey: "alert2Enabled") as? Bool ?? true
        let e3 = defaults.object(forKey: "alert3Enabled") as? Bool ?? true
        if e1 { migrated.append(defaults.object(forKey: "alert1Threshold") as? Int ?? 75) }
        if e2 { migrated.append(defaults.object(forKey: "alert2Threshold") as? Int ?? 90) }
        if e3 { migrated.append(defaults.object(forKey: "alert3Threshold") as? Int ?? 95) }
        return migrated.isEmpty ? [75, 90, 95] : migrated
    }

    private static func legacyStoredNotificationPresets(from defaults: UserDefaults, commonRemainingMode: Bool)
        -> [NotificationPreset]
    {
        if let data = defaults.data(forKey: "notificationPresets"),
            let decoded = try? JSONDecoder().decode([NotificationPreset].self, from: data),
            !decoded.isEmpty
        {
            return decoded
        }

        let claudeThresholds = legacyAlertThresholds(from: defaults)
        let codexThresholds = defaults.array(forKey: "codexAlertThresholds") as? [Int] ?? claudeThresholds
        let codexRemainingMode = defaults.object(forKey: "codexAlertRemainingMode") as? Bool ?? commonRemainingMode

        func actualUsageThresholds(_ values: [Int], remainingMode: Bool) -> [Int] {
            values.map { value in
                let normalized = max(1, min(value, 100))
                return remainingMode ? max(1, min(100 - normalized, 99)) : normalized
            }
        }

        func storedThreshold(from actualThreshold: Int) -> Int {
            if commonRemainingMode {
                return max(1, min(100 - actualThreshold, 99))
            }
            return max(1, min(actualThreshold, 100))
        }

        let merged = Set(
            actualUsageThresholds(claudeThresholds, remainingMode: commonRemainingMode)
                + actualUsageThresholds(codexThresholds, remainingMode: codexRemainingMode)
        )
        let resolved = merged.isEmpty ? [75, 90, 95] : merged.sorted()
        return resolved.map { NotificationPreset(threshold: storedThreshold(from: $0), isEnabled: true) }
    }
}
