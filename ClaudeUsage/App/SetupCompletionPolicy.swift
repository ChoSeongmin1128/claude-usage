import Foundation

enum SetupCompletionPolicy {
    enum SetupStage: Equatable {
        case credential
        case verification
        case organization
        case complete
    }

    struct SetupProgress: Equatable {
        let hasReadyCredential: Bool
        let hasSuccessfulFetch: Bool
        let isOrganizationReady: Bool

        var stage: SetupStage {
            if !hasReadyCredential {
                return .credential
            }
            if !hasSuccessfulFetch {
                return .verification
            }
            if !isOrganizationReady {
                return .organization
            }
            return .complete
        }
    }

    static func isOrganizationReady(
        preferredOrganizationID: String,
        cachedMetadata: ClaudeProfileMetadata?
    ) -> Bool {
        let preferredID = preferredOrganizationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preferredID.isEmpty else { return true }
        return cachedMetadata?.organizationUUID == preferredID
    }

    static func hasReadyCredential(
        sessionCredentialAvailable: Bool,
        oauthCredentialAvailable: Bool
    ) -> Bool {
        sessionCredentialAvailable || oauthCredentialAvailable
    }

    @MainActor
    static func notificationPolicy(from metadata: ClaudeProfileMetadata?) -> ClaudeNotificationPolicy? {
        metadata.map(ClaudeNotificationPolicy.init(metadata:))
    }

    static func messagesFallbackPolicy(from settings: AppSettings) -> ClaudeMessagesHeaderFallbackPolicy {
        switch settings.claudeMessagesFallbackPolicy {
        case .off:
            return .init(isEnabled: false, allowAutomaticFallback: false, minimumUsagePercent: 20)
        case .manual:
            return .init(
                isEnabled: true,
                allowAutomaticFallback: false,
                minimumUsagePercent: Double(settings.claudeMessagesFallbackAutoDisableBelowPercent)
            )
        case .automatic:
            return .init(
                isEnabled: true,
                allowAutomaticFallback: true,
                minimumUsagePercent: Double(settings.claudeMessagesFallbackAutoDisableBelowPercent)
            )
        }
    }

    static func resolveProgress(
        hasReadyCredential: Bool,
        hasSuccessfulFetch: Bool,
        preferredOrganizationID: String,
        cachedMetadata: ClaudeProfileMetadata?
    ) -> SetupProgress {
        SetupProgress(
            hasReadyCredential: hasReadyCredential,
            hasSuccessfulFetch: hasSuccessfulFetch,
            isOrganizationReady: hasSuccessfulFetch
                && isOrganizationReady(
                    preferredOrganizationID: preferredOrganizationID,
                    cachedMetadata: cachedMetadata
                )
        )
    }
}
