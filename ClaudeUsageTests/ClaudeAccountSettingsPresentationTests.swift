import XCTest
@testable import ClaudeUsage

final class ClaudeAccountSettingsPresentationTests: XCTestCase {
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
        XCTAssertEqual(presentation.secondaryLine, "Work Org · 앱에서 로그인")
        XCTAssertEqual(presentation.sourceBadge, "앱 로그인")
        XCTAssertEqual(presentation.statusText, "최근 조회 성공")
        XCTAssertEqual(presentation.statusTone, .success)
        XCTAssertEqual(presentation.availableActions, [.use, .deleteWebSession])
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
        XCTAssertEqual(presentation.secondaryLine, "Glorang · Chrome Nathan")
        XCTAssertEqual(presentation.sourceBadge, "Chrome")
        XCTAssertEqual(presentation.statusText, "최근 조회 성공")
        XCTAssertEqual(presentation.availableActions, [.deleteWebSession])
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
        XCTAssertEqual(presentation.secondaryLine, "터미널 Claude Code")
        XCTAssertEqual(presentation.sourceBadge, "Claude Code")
        XCTAssertEqual(presentation.statusText, "확인 전")
        XCTAssertEqual(presentation.statusTone, .neutral)
        XCTAssertEqual(presentation.availableActions, [.use, .showClaudeCodeLoginGuidance])
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
        XCTAssertEqual(presentation.secondaryLine, "efa005dc... · 앱에서 로그인")
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
            presentation.sourceBadge,
            presentation.statusText,
        ]

        for text in userFacingTexts {
            XCTAssertFalse(text.contains("식별:"))
            XCTAssertFalse(text.contains("출처:"))
            XCTAssertFalse(text.contains("현재 사용 경로"))
            XCTAssertFalse(text.contains("감지됨"))
        }
    }
}
