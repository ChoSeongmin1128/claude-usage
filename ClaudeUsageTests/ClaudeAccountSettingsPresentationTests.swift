import XCTest
@testable import ClaudeUsage

@MainActor
final class ClaudeAccountSettingsPresentationTests: XCTestCase {
    func testClaudeCodeHeaderShowsSourceAndOrganization() {
        let account = ClaudeAccount(
            id: "cli", kind: .claudeCodeExternal, displayName: "CLI",
            identity: .init(email: "same@example.com", organizationName: "Workspace", organizationID: "org-work"),
            source: .claudeCodeCLI, lastValidationState: .verified)
        let presentation = ClaudeAccountSettingsPresentation.resolve(account: account, isActive: true)
        XCTAssertEqual(presentation.sourceLabel, "Claude Code")
        XCTAssertEqual(presentation.secondaryLine, "Workspace")
    }

    func testClaudeCodeCredentialIssueReplacesStaleVerifiedStatus() {
        let account = ClaudeAccount(
            id: "cli", kind: .claudeCodeExternal, displayName: "CLI",
            identity: .init(organizationID: "org-work"),
            source: .claudeCodeCLI, lastValidationState: .verified)

        let verified = ClaudeAccountSettingsPresentation.resolve(account: account, isActive: true)
        let reconnect = ClaudeAccountSettingsPresentation.resolve(
            account: account, isActive: true, claudeCodeCredentialIssue: .reconnectRequired)
        let relogin = ClaudeAccountSettingsPresentation.resolve(
            account: account, isActive: true, claudeCodeCredentialIssue: .reauthenticationRequired)

        XCTAssertEqual(verified.statusText, "연결됨")
        XCTAssertEqual(reconnect.statusText, "다시 연결 필요")
        XCTAssertEqual(reconnect.statusTone, .warning)
        XCTAssertEqual(relogin.statusText, "Claude Code 로그인 필요")
    }

    func testHealthSnapshotUsesCurrentStoreMetadataForSameActiveAccount() {
        let staleAccount = ClaudeAccount(
            id: ClaudeAccountStore.claudeCodeExternalAccountID,
            kind: .claudeCodeExternal,
            displayName: "efa005dc-8c5f-4fd2-ab83-af6e4d063690",
            identity: ClaudeAccountIdentity(
                organizationID: "efa005dc-8c5f-4fd2-ab83-af6e4d063690"
            )
        )
        let currentAccount = ClaudeAccount(
            id: staleAccount.id,
            kind: .claudeCodeExternal,
            displayName: "team",
            identity: ClaudeAccountIdentity(planLabel: "team")
        )
        let currentState = ClaudeAccountState(
            accounts: [currentAccount],
            activeAccountID: currentAccount.id
        )

        let resolved = ClaudeAccountSnapshotPresentationPolicy.resolve(
            snapshotActiveAccountID: staleAccount.id,
            currentState: currentState
        )

        XCTAssertEqual(resolved, currentState)
        XCTAssertEqual(resolved?.activeAccount?.displayName, "team")
    }

    func testHealthSnapshotRejectsDifferentActiveAccountGeneration() {
        let currentState = ClaudeAccountState(
            accounts: [],
            activeAccountID: "web-current"
        )

        XCTAssertNil(ClaudeAccountSnapshotPresentationPolicy.resolve(
            snapshotActiveAccountID: "web-previous",
            currentState: currentState
        ))
    }

    func testWebSessionPresentationUsesHumanAccountLabel() {
        let account = ClaudeAccount(
            id: "web",
            kind: .webSession,
            displayName: "브라우저 계정",
            identity: ClaudeAccountIdentity(
                email: "work@example.com",
                organizationName: "Work Org",
                organizationID: "org-work"
            ),
            source: .embeddedWebLogin,
            lastValidationState: .verified
        )

        let presentation = ClaudeAccountSettingsPresentation.resolve(account: account)

        XCTAssertEqual(presentation.primaryTitle, "work@example.com")
        XCTAssertEqual(presentation.secondaryLine, "Work Org")
        XCTAssertEqual(presentation.statusText, "연결됨")
        XCTAssertEqual(presentation.statusTone, .success)
        XCTAssertEqual(presentation.systemImage, "globe")
    }

    func testChromeProfilePresentationPrefersReadableProfileEmailAndOrganizationName() {
        let account = ClaudeAccount(
            id: "web",
            kind: .webSession,
            displayName: "Chrome Nathan",
            identity: ClaudeAccountIdentity(organizationID: "org-company"),
            source: .chromeProfile,
            sourceDetail: "Nathan (Profile 2) · nathan@glorang.com",
            preferredOrganizationID: "org-company",
            lastValidationState: .verified
        )
        let organization = ClaudeAPIService.OrganizationSummary(id: "org-company", name: "Glorang")

        let presentation = ClaudeAccountSettingsPresentation.resolve(
            account: account,
            isActive: true,
            organizations: [organization]
        )

        XCTAssertEqual(presentation.primaryTitle, "Chrome Nathan · nathan@glorang.com")
        XCTAssertEqual(presentation.secondaryLine, "Glorang")
        XCTAssertEqual(presentation.statusText, "연결됨")
    }

    func testInactiveAccountDoesNotUseActiveAccountOrganizationLookup() {
        let account = ClaudeAccount(
            id: "personal-web",
            kind: .webSession,
            displayName: "Chrome 성민",
            identity: ClaudeAccountIdentity(
                email: "joseongmin0127@gmail.com",
                organizationName: "joseongmin0127@gmail.com's Organization",
                organizationID: "org-personal"
            ),
            source: .chromeProfile,
            sourceDetail: "성민 · joseongmin0127@gmail.com",
            preferredOrganizationID: "org-personal",
            lastValidationState: .verified
        )
        let activeAccountOrganization = ClaudeAPIService.OrganizationSummary(
            id: "org-personal",
            name: "Glorang"
        )

        let presentation = ClaudeAccountSettingsPresentation.resolve(
            account: account,
            isActive: false,
            organizations: [activeAccountOrganization]
        )

        XCTAssertEqual(presentation.secondaryLine, "joseongmin0127@gmail.com's Organization")
        XCTAssertEqual(presentation.sourceLabel, "Chrome")
    }

    func testClaudeCodePresentationIsReadOnlyCliCandidate() {
        let account = ClaudeAccount(
            id: "cli",
            kind: .claudeCodeExternal,
            displayName: "max",
            source: .claudeCodeCLI,
            lastValidationState: .detected
        )

        let presentation = ClaudeAccountSettingsPresentation.resolve(account: account)

        XCTAssertEqual(presentation.primaryTitle, "max")
        XCTAssertNil(presentation.secondaryLine)
        XCTAssertEqual(presentation.statusText, "확인 전")
        XCTAssertEqual(presentation.statusTone, .neutral)
        XCTAssertEqual(presentation.systemImage, "terminal")
    }

    func testOrganizationIDIsShortenedWhenNameIsUnavailable() {
        let account = ClaudeAccount(
            id: "web",
            kind: .webSession,
            displayName: "브라우저 계정",
            identity: ClaudeAccountIdentity(organizationID: "efa005dc-8c5f-4fd2-ab83-af6e4d063690"),
            source: .embeddedWebLogin
        )

        let presentation = ClaudeAccountSettingsPresentation.resolve(account: account)

        XCTAssertEqual(presentation.primaryTitle, "저장된 Claude 계정")
        XCTAssertEqual(presentation.secondaryLine, "efa005dc...")
    }

    func testDefaultAccountPresentationDoesNotExposeDiagnosticLabels() {
        let account = ClaudeAccount(
            id: "web",
            kind: .webSession,
            displayName: "Chrome Nathan",
            identity: ClaudeAccountIdentity(organizationName: "Glorang"),
            source: .chromeProfile,
            sourceDetail: "Nathan (Profile 2) · nathan@glorang.com",
            lastValidationState: .detected
        )

        let presentation = ClaudeAccountSettingsPresentation.resolve(account: account)
        let userFacingTexts = [
            presentation.primaryTitle,
            presentation.secondaryLine ?? "",
            presentation.sourceLabel ?? "",
            presentation.statusText,
        ]

        for text in userFacingTexts {
            XCTAssertFalse(text.contains("식별:"))
            XCTAssertFalse(text.contains("출처:"))
            XCTAssertFalse(text.contains("현재 사용 경로"))
            XCTAssertFalse(text.contains("감지됨"))
            XCTAssertFalse(text.contains("Profile 2"))
        }
    }
}
