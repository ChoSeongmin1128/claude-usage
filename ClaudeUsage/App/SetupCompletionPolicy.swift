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
        oauthCredentialAvailable: Bool,
        storedSessionKey: String?
    ) -> Bool {
        sessionCredentialAvailable
            || oauthCredentialAvailable
            || !(storedSessionKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            return "직접 선택 사용 중 · 아직 계정 확인 전"
        }

        if cachedOrganizationID == preferredID {
            return "직접 선택 사용 중 · 저장된 계정과 일치"
        }

        return "직접 선택 사용 중 · 저장된 계정과 다름"
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
            organizationSummary = "첫 성공 조회 후 organization 상태를 확인합니다"
        } else if isAutomaticOrganizationMode {
            organizationSummary = "자동 선택 모드로 바로 사용할 수 있습니다"
        } else if organizationReady {
            organizationSummary = "선택한 organization이 검증되었습니다"
        } else {
            organizationSummary = "선택한 organization을 설정에서 다시 확인해야 합니다"
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
