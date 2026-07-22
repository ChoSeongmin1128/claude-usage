import XCTest
@testable import ClaudeUsage

@MainActor
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
        XCTAssertEqual(presentation.secondaryLine, "Work Org")
        XCTAssertEqual(presentation.statusText, "최근 조회 성공")
        XCTAssertEqual(presentation.statusTone, .success)
        XCTAssertEqual(presentation.switchAction, .use)
        XCTAssertEqual(presentation.managementActions, [.deleteWebSession])
        XCTAssertEqual(presentation.systemImage, "globe")
        XCTAssertEqual(
            presentation.detailRows,
            [
                ClaudeAccountSettingsDetailRow(title: "조직", value: "Work Org"),
                ClaudeAccountSettingsDetailRow(title: "로그인 방식", value: "앱에서 로그인"),
                ClaudeAccountSettingsDetailRow(title: "조직 ID", value: "org-work"),
            ]
        )
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
        XCTAssertEqual(presentation.statusText, "최근 조회 성공")
        XCTAssertNil(presentation.switchAction)
        XCTAssertEqual(presentation.managementActions, [.deleteWebSession])
        XCTAssertEqual(
            presentation.detailRows,
            [
                ClaudeAccountSettingsDetailRow(title: "조직", value: "Glorang"),
                ClaudeAccountSettingsDetailRow(title: "Chrome 프로필", value: "Nathan (Profile 2)"),
                ClaudeAccountSettingsDetailRow(title: "조직 ID", value: "org-company"),
            ]
        )
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
        XCTAssertTrue(presentation.detailRows.contains(
            ClaudeAccountSettingsDetailRow(
                title: "조직",
                value: "joseongmin0127@gmail.com's Organization"
            )
        ))
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
        XCTAssertEqual(presentation.switchAction, .use)
        XCTAssertEqual(presentation.managementActions, [.showClaudeCodeLoginGuidance])
        XCTAssertEqual(presentation.systemImage, "terminal")
        XCTAssertEqual(
            presentation.detailRows,
            [ClaudeAccountSettingsDetailRow(title: "로그인 방식", value: "터미널 Claude Code")]
        )
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
        XCTAssertEqual(
            presentation.detailRows,
            [
                ClaudeAccountSettingsDetailRow(title: "조직", value: "efa005dc..."),
                ClaudeAccountSettingsDetailRow(title: "로그인 방식", value: "앱에서 로그인"),
            ]
        )
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
            presentation.statusText,
        ]

        for text in userFacingTexts {
            XCTAssertFalse(text.contains("식별:"))
            XCTAssertFalse(text.contains("출처:"))
            XCTAssertFalse(text.contains("현재 사용 경로"))
            XCTAssertFalse(text.contains("감지됨"))
            XCTAssertFalse(text.contains("Profile 2"))
        }

        XCTAssertTrue(presentation.detailRows.contains(
            ClaudeAccountSettingsDetailRow(title: "Chrome 프로필", value: "Nathan (Profile 2)")
        ))
    }
}
