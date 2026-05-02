import XCTest
@testable import ClaudeUsage

final class ClaudeAccountSettingsPresentationTests: XCTestCase {
    func testWebSessionPresentationExplainsBrowserLoginSource() {
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

        XCTAssertEqual(presentation.title, "앱내 웹 로그인")
        XCTAssertEqual(presentation.identifierLine, "식별: work@example.com")
        XCTAssertEqual(presentation.sourceLine, "출처: 앱내 웹 로그인")
        XCTAssertEqual(presentation.organizationLine, "조직: Work Org")
        XCTAssertEqual(presentation.statusLine, "상태: 최근 조회 성공")
        XCTAssertEqual(presentation.systemImage, "globe")
    }

    func testChromeProfilePresentationUsesProfileAndOrganizationPreview() {
        let account = ClaudeAccount(
            id: "web",
            kind: .webSession,
            displayName: "Chrome Profile 2",
            identity: ClaudeAccountIdentity(organizationID: "org-company"),
            source: .chromeProfile,
            sourceDetail: "Profile 2",
            preferredOrganizationID: "org-company",
            lastValidationState: .verified
        )
        let organization = ClaudeAPIService.OrganizationSummary(id: "org-company", name: "Company")
        let preview = ClaudeAPIService.OrganizationPreview(
            organization: organization,
            fiveHourPercentage: 10,
            weeklyPercentage: 20,
            overageEnabled: true,
            overageUsed: 3,
            overageLimit: 100,
            usageErrorMessage: nil
        )

        let presentation = ClaudeAccountSettingsPresentation.resolve(
            account: account,
            organizations: [organization],
            previews: [organization.id: preview]
        )

        XCTAssertEqual(presentation.title, "Chrome 프로필 로그인")
        XCTAssertEqual(presentation.identifierLine, "식별: Chrome 프로필 Profile 2")
        XCTAssertEqual(presentation.sourceLine, "출처: Chrome 프로필 Profile 2")
        XCTAssertEqual(presentation.organizationLine, "조직: Company (org-company) · 추가 사용량 $3.00 / $100.00")
    }

    func testClaudeCodePresentationExplainsTerminalCliSource() {
        let account = ClaudeAccount(
            id: "cli",
            kind: .claudeCodeExternal,
            displayName: "max",
            source: .claudeCodeCLI,
            lastValidationState: .detected
        )

        let presentation = ClaudeAccountSettingsPresentation.resolve(account: account)

        XCTAssertEqual(presentation.title, "터미널 Claude Code 로그인")
        XCTAssertEqual(presentation.identifierLine, "식별: max")
        XCTAssertEqual(presentation.sourceLine, "출처: 터미널 Claude Code CLI")
        XCTAssertNil(presentation.organizationLine)
        XCTAssertEqual(presentation.statusLine, "상태: 감지됨")
        XCTAssertEqual(presentation.systemImage, "terminal")
    }

    func testGenericDisplayNameFallsBackToMeaningfulAccountLabel() {
        let browserAccount = ClaudeAccount(
            id: "web",
            kind: .webSession,
            displayName: "브라우저 계정"
        )
        let cliAccount = ClaudeAccount(
            id: "cli",
            kind: .claudeCodeExternal,
            displayName: "Claude Code 로그인"
        )

        XCTAssertEqual(
            ClaudeAccountSettingsPresentation.resolve(account: browserAccount).identifierLine,
            "식별: 저장된 브라우저 로그인"
        )
        XCTAssertEqual(
            ClaudeAccountSettingsPresentation.resolve(account: cliAccount).identifierLine,
            "식별: 현재 Claude Code CLI 로그인"
        )
    }
}
