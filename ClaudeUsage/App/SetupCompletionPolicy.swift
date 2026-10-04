import Foundation

enum SetupCompletionPolicy {
    enum WizardStage: Equatable {
        case credential
        case verification
        case organization
        case complete
    }

    struct WizardProgress: Equatable {
        let hasReadyCredential: Bool
        let hasSuccessfulFetch: Bool
        let isOrganizationReady: Bool
        let isAutomaticOrganizationMode: Bool
        let organizationSummary: String?

        var stage: WizardStage {
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

    /// 브라우저 가져오기는 기본 브라우저를 먼저 보고 여러 브라우저를 찾으므로 특정 브라우저 설치와 관계없이 먼저 권한다.
    static func resolveCredentialStep(
        hasReadyCredential: Bool,
        shouldPreferManual: Bool = false
    ) -> SetupWizardView.Step {
        if hasReadyCredential {
            return .webLogin
        }
        if shouldPreferManual {
            return .manualSessionKey
        }
        return .browserImport
    }

    static func resolveWizardStep(
        progress: WizardProgress,
        credentialStepOverride: SetupWizardView.Step?
    ) -> SetupWizardView.Step {
        if progress.stage == .credential, let credentialStepOverride {
            return credentialStepOverride
        }

        switch progress.stage {
        case .credential:
            return resolveCredentialStep(hasReadyCredential: progress.hasReadyCredential)
        case .verification, .organization, .complete:
            return .webLogin
        }
    }

    static func resolvePresentation(
        hasReadyCredential: Bool,
        hasSuccessfulFetch: Bool,
        preferredOrganizationID: String,
        cachedMetadata: ClaudeProfileMetadata?,
        credentialStepOverride: SetupWizardView.Step? = nil
    ) -> ClaudeSetupPresentation {
        let progress = resolveWizardProgress(
            hasReadyCredential: hasReadyCredential,
            hasSuccessfulFetch: hasSuccessfulFetch,
            preferredOrganizationID: preferredOrganizationID,
            cachedMetadata: cachedMetadata
        )
        let credentialStep = resolveWizardStep(
            progress: progress,
            credentialStepOverride: credentialStepOverride
        )

        let primaryActionKind: ClaudeSetupPresentation.PrimaryActionKind

        switch progress.stage {
        case .credential:
            switch credentialStep {
            case .browserImport:
                primaryActionKind = .importFromBrowser
            case .webLogin:
                primaryActionKind = .openWebLogin
            case .manualSessionKey:
                primaryActionKind = .openAdvancedSettings
            }
        case .verification:
            primaryActionKind = .verifyFetch
        case .organization:
            primaryActionKind = progress.isAutomaticOrganizationMode ? .useAutomaticOrganization : .openOrganizations
        case .complete:
            primaryActionKind = .complete
        }

        return ClaudeSetupPresentation(
            progress: progress,
            credentialStep: credentialStep,
            shouldShowWizard: progress.stage != .complete,
            primaryActionKind: primaryActionKind,
            organizationSummary: progress.organizationSummary
        )
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

    static func resolveWizardProgress(
        hasReadyCredential: Bool,
        hasSuccessfulFetch: Bool,
        preferredOrganizationID: String,
        cachedMetadata: ClaudeProfileMetadata?
    ) -> WizardProgress {
        let organizationReady = hasSuccessfulFetch && isOrganizationReady(
            preferredOrganizationID: preferredOrganizationID,
            cachedMetadata: cachedMetadata
        )

        let preferredID = preferredOrganizationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let isAutomaticOrganizationMode = preferredID.isEmpty
        let organizationSummary: String?
        if !hasSuccessfulFetch || isAutomaticOrganizationMode {
            organizationSummary = nil
        } else if organizationReady {
            organizationSummary = "선택한 조직을 확인했습니다"
        } else {
            organizationSummary = "선택한 조직을 다시 확인하세요"
        }

        return WizardProgress(
            hasReadyCredential: hasReadyCredential,
            hasSuccessfulFetch: hasSuccessfulFetch,
            isOrganizationReady: organizationReady,
            isAutomaticOrganizationMode: isAutomaticOrganizationMode,
            organizationSummary: organizationSummary
        )
    }

    static func shouldMarkSetupComplete(
        hasSuccessfulFetch: Bool,
        preferredOrganizationID: String,
        cachedMetadata: ClaudeProfileMetadata?
    ) -> Bool {
        hasSuccessfulFetch && isOrganizationReady(
            preferredOrganizationID: preferredOrganizationID,
            cachedMetadata: cachedMetadata
        )
    }

}
