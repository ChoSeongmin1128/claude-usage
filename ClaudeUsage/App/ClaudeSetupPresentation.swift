import Foundation

struct ClaudeSetupPresentation: Equatable, Sendable {
    enum LandingSettingsTab: String, Sendable {
        case auth
        case status
        case organizations
    }

    enum PrimaryActionKind: Sendable {
        case openChrome
        case openWebLogin
        case openAdvancedSettings
        case verifyFetch
        case openOrganizations
        case useAutomaticOrganization
        case complete
    }

    let progress: SetupCompletionPolicy.WizardProgress
    let credentialStep: SetupWizardView.Step
    let shouldShowWizard: Bool
    let landingSettingsTab: LandingSettingsTab
    let primaryActionKind: PrimaryActionKind
    let organizationSummary: String
}
