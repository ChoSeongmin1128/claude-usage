import Foundation

nonisolated protocol AntigravityRuntimeOwnershipResolving: Sendable {
    func csrfToken(for identity: AntigravityVerifiedProcessIdentity) async -> AntigravityCSRFToken?
    func ownership(
        for identity: AntigravityVerifiedProcessIdentity
    ) async -> AntigravityRuntimeOwnership
}

nonisolated struct AntigravityDefaultRuntimeOwnershipResolver:
    AntigravityRuntimeOwnershipResolving
{
    func csrfToken(for identity: AntigravityVerifiedProcessIdentity) async -> AntigravityCSRFToken? {
        nil
    }

    func ownership(
        for identity: AntigravityVerifiedProcessIdentity
    ) async -> AntigravityRuntimeOwnership {
        switch identity.executable.role {
        case .appLanguageServer:
            .external
        case .agyCLI:
            .borrowed
        }
    }
}
