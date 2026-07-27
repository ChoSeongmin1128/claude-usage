import Foundation

nonisolated struct AntigravityConnectionSettings: Codable, Equatable, Sendable {
    nonisolated static let currentSchemaVersion = 1

    enum SourcePolicy: String, Codable, CaseIterable, Sendable {
        case automatic
        case localSession = "local_session"
        case googleAccount = "google_account"
    }

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
    var sourcePolicy: SourcePolicy
    var allowManagedCLI: Bool
    var managedSession: ManagedSessionPolicy

    static let `default` = AntigravityConnectionSettings(
        schemaVersion: currentSchemaVersion,
        sourcePolicy: .automatic,
        allowManagedCLI: false,
        managedSession: .default
    )

    var isCurrentAndValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && managedSession.isValid
    }
}
