import Foundation

// UserDefaults keys that only earlier releases wrote. A group with a
// replacement stays until the replacement exists, because the current import
// still reads it until then. `notificationPresets` is not listed: 2.5.x reads
// it as its own storage, so removing it would reset a downgrade's rules.
nonisolated enum RetiredAppDefaults {
    struct Group: Sendable {
        let keys: [String]
        let replacement: String?
    }

    static let groups: [Group] = [
        Group(
            keys: [
                "claudeSettingsLastTab", "codexSettingsLastTab",
                AppIdentifiers.defaultsKey("authPathHealth.v1"), AppIdentifiers.defaultsKey("cachedOrganizations.v1"),
                "initialRuntimeProviderDetectionCompleted", "suppressMoveToApplicationsAlert",
                "browserCookieAccessDeniedUntil", "geminiRefreshInterval", "statusItemUnplacedNoticeDate",
                "codexTimeFormat", AppIdentifiers.defaultsKey("timeUnitLanguage"),
                // 2.4.0부터 모든 서비스를 보여 주어 읽지 않는 노출 설정
                "additionalRuntimeProvidersEnabled",
                // 적응형 새로고침(2.8.0)이 대신하는 고정 주기 설정
                "refreshInterval", "usePerProviderRefreshIntervals", "claudeRefreshInterval",
                "codexRefreshInterval", "antigravityRefreshInterval", "reducedRefreshOnBattery",
                // 도달하지 않던 OAuth 자동 전환의 실행 표시
                AppIdentifiers.defaultsKey("oauthAwareMigrationVersion"),
                // 계정 귀속을 깨뜨릴 수 있어 폐기한 교차 계정 OAuth 우선 설정
                "claudePreferOAuth",
            ],
            replacement: nil),
        Group(
            keys: [
                "alertThresholds", "alert1Enabled", "alert2Enabled", "alert3Enabled",
                "alert1Threshold", "alert2Threshold", "alert3Threshold",
                "codexAlertThresholds", "codexAlertRemainingMode",
            ],
            replacement: NotificationThresholdStorage.key),
        Group(keys: ["showPercentage", "showDualPercentage"], replacement: "percentageDisplay"),
        Group(keys: ["showModelUsage", "showOverageUsage"], replacement: "popoverItemsV2"),
        Group(keys: ["claudePopoverPinned", "codexPopoverPinned"], replacement: "popoverPinned"),
        Group(keys: ["claudePopoverCompact", "codexPopoverCompact"], replacement: "popoverCompact"),
    ]

    static func remove(from defaults: UserDefaults) {
        for group in groups where group.replacement.map({ defaults.object(forKey: $0) != nil }) ?? true {
            group.keys.forEach(defaults.removeObject(forKey:))
        }
    }
}
