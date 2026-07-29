import Foundation

nonisolated struct AntigravityConnectionSettings: Codable, Equatable, Sendable {
    nonisolated static let currentSchemaVersion = 2

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

    static let `default` = AntigravityConnectionSettings(
        schemaVersion: currentSchemaVersion,
        managedSession: .default
    )

    var isCurrentAndValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && managedSession.isValid
    }
}
