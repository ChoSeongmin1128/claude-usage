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
