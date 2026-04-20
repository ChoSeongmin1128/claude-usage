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
        let organizationSummary: String

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

    static func resolveCredentialStep(
        hasReadyCredential: Bool,
        hasChromeApp: Bool,
        shouldPreferManual: Bool = false
    ) -> SetupWizardView.Step {
        if hasReadyCredential {
            return .webLogin
        }
        if shouldPreferManual {
            return .manualSessionKey
        }
        if !hasChromeApp {
            return .webLogin
        }
        return .chromeImport
    }

    static func resolveWizardStep(
        progress: WizardProgress,
        hasChromeApp: Bool,
        credentialStepOverride: SetupWizardView.Step?
    ) -> SetupWizardView.Step {
        if progress.stage == .credential, let credentialStepOverride {
            return credentialStepOverride
        }

        switch progress.stage {
        case .credential:
            return resolveCredentialStep(
                hasReadyCredential: progress.hasReadyCredential,
                hasChromeApp: hasChromeApp
            )
        case .verification, .organization, .complete:
            return .webLogin
        }
    }

    static func resolvePresentation(
        hasReadyCredential: Bool,
        hasSuccessfulFetch: Bool,
        preferredOrganizationID: String,
        cachedMetadata: ClaudeProfileMetadata?,
        hasChromeApp: Bool,
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
            hasChromeApp: hasChromeApp,
            credentialStepOverride: credentialStepOverride
        )

        let landingSettingsTab: ProviderSettingsTab
        let primaryActionKind: ClaudeSetupPresentation.PrimaryActionKind

        switch progress.stage {
        case .credential:
            landingSettingsTab = .overview
            switch credentialStep {
            case .chromeImport:
                primaryActionKind = .openChrome
            case .webLogin:
                primaryActionKind = .openWebLogin
            case .manualSessionKey:
                primaryActionKind = .openAdvancedSettings
            }
        case .verification:
            landingSettingsTab = .overview
            primaryActionKind = .verifyFetch
        case .organization:
            landingSettingsTab = .overview
            primaryActionKind = progress.isAutomaticOrganizationMode ? .useAutomaticOrganization : .openOrganizations
        case .complete:
            landingSettingsTab = .overview
            primaryActionKind = .complete
        }

        return ClaudeSetupPresentation(
            progress: progress,
            credentialStep: credentialStep,
            shouldShowWizard: progress.stage != .complete,
            landingSettingsTab: landingSettingsTab,
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

    static func shouldMarkCompleteAfterSuccessfulClaudeRefresh(
        preferredOrganizationID: String,
        cachedMetadata: ClaudeProfileMetadata?
    ) -> Bool {
        isOrganizationReady(
            preferredOrganizationID: preferredOrganizationID,
            cachedMetadata: cachedMetadata
        )
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

    static func organizationStatusSummary(
        preferredOrganizationID: String,
        cachedMetadata: ClaudeProfileMetadata?
    ) -> String {
        let preferredID = preferredOrganizationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preferredID.isEmpty else {
            return "자동 선택 사용 중"
        }

        guard let cachedOrganizationID = cachedMetadata?.organizationUUID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cachedOrganizationID.isEmpty else {
            return "직접 선택 사용 중 · 아직 확인 전"
        }

        if cachedOrganizationID == preferredID {
            return "직접 선택 사용 중 · 확인됨"
        }

        return "직접 선택 사용 중 · 다시 확인 필요"
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
        let organizationSummary: String
        if !hasSuccessfulFetch {
            organizationSummary = "먼저 사용량 확인이 끝나면 조직 상태를 확인합니다"
        } else if isAutomaticOrganizationMode {
            organizationSummary = "자동 선택으로 바로 사용할 수 있습니다"
        } else if organizationReady {
            organizationSummary = "선택한 조직이 확인되었습니다"
        } else {
            organizationSummary = "선택한 조직을 다시 확인해 주세요"
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

    static func shouldShowSetupFlow(
        hasReadyCredential: Bool,
        hasSuccessfulFetch: Bool,
        preferredOrganizationID: String,
        cachedMetadata: ClaudeProfileMetadata?
    ) -> Bool {
        let progress = resolveWizardProgress(
            hasReadyCredential: hasReadyCredential,
            hasSuccessfulFetch: hasSuccessfulFetch,
            preferredOrganizationID: preferredOrganizationID,
            cachedMetadata: cachedMetadata
        )
        return progress.stage != .complete
    }
}
