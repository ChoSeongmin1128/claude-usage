import Foundation

nonisolated struct AntigravityConnectionSettings: Codable, Equatable, Sendable {
    nonisolated static let currentSchemaVersion = 4

    struct ManagedSessionPolicy: Codable, Equatable, Sendable {
        static let defaultIdleTimeoutSeconds = 180

        var idleTimeoutSeconds: Int

        static let `default` = ManagedSessionPolicy(
            idleTimeoutSeconds: defaultIdleTimeoutSeconds
        )

        var isValid: Bool {
            idleTimeoutSeconds > 0
        }
    }

    let schemaVersion: Int
    var managedSession: ManagedSessionPolicy
    var usageTarget: AntigravityUsageTarget

    init(
        schemaVersion: Int, managedSession: ManagedSessionPolicy,
        usageTarget: AntigravityUsageTarget = .cli
    ) {
        self.schemaVersion = schemaVersion
        self.managedSession = managedSession
        self.usageTarget = usageTarget
    }

    static let `default` = AntigravityConnectionSettings(
        schemaVersion: currentSchemaVersion,
        managedSession: .default
    )

    var isCurrentAndValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && managedSession.isValid
    }
}
