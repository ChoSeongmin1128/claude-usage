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
                "ClaudeUsage.authPathHealth.v1", "ClaudeUsage.cachedOrganizations.v1",
                "initialRuntimeProviderDetectionCompleted", "suppressMoveToApplicationsAlert",
                "browserCookieAccessDeniedUntil", "geminiRefreshInterval", "statusItemUnplacedNoticeDate",
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
