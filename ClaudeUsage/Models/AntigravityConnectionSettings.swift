import Foundation

nonisolated struct AntigravityConnectionSettings: Codable, Equatable, Sendable {
    nonisolated static let currentSchemaVersion = 5

    let schemaVersion: Int
    var usageTarget: AntigravityUsageTarget

    init(schemaVersion: Int, usageTarget: AntigravityUsageTarget = .cli) {
        self.schemaVersion = schemaVersion
        self.usageTarget = usageTarget
    }

    static let `default` = AntigravityConnectionSettings(
        schemaVersion: currentSchemaVersion
    )

    var isCurrentAndValid: Bool {
        schemaVersion == Self.currentSchemaVersion
    }
}
