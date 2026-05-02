import XCTest
@testable import ClaudeUsage

final class ClaudeAccountSettingsPresentationTests: XCTestCase {
    func testWebSessionPresentationExplainsBrowserLoginSource() {
        let account = ClaudeAccount(
            id: "web",
            kind: .webSession,
            displayName: "브라우저 계정",
            identity: ClaudeAccountIdentity(email: "work@example.com", organizationName: "Work Org"),
            lastValidationState: .verified
        )

        let presentation = ClaudeAccountSettingsPresentation.resolve(account: account)

        XCTAssertEqual(presentation.title, "브라우저에서 가져온 로그인")
        XCTAssertEqual(presentation.accountLine, "계정: work@example.com · Work Org")
        XCTAssertEqual(presentation.detailLine, "Chrome 가져오기 또는 앱내 웹 로그인으로 저장한 로그인입니다")
        XCTAssertEqual(presentation.statusLine, "상태: 최근 조회 성공")
        XCTAssertEqual(presentation.systemImage, "globe")
    }

    func testClaudeCodePresentationExplainsTerminalCliSource() {
        let account = ClaudeAccount(
            id: "cli",
            kind: .claudeCodeExternal,
            displayName: "max",
            lastValidationState: .detected
        )

        let presentation = ClaudeAccountSettingsPresentation.resolve(account: account)

        XCTAssertEqual(presentation.title, "터미널 Claude Code 로그인")
        XCTAssertEqual(presentation.accountLine, "계정: max")
        XCTAssertEqual(presentation.detailLine, "터미널의 Claude Code 로그인 상태를 읽기만 합니다")
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
            ClaudeAccountSettingsPresentation.resolve(account: browserAccount).accountLine,
            "계정: 저장된 브라우저 로그인"
        )
        XCTAssertEqual(
            ClaudeAccountSettingsPresentation.resolve(account: cliAccount).accountLine,
            "계정: 현재 Claude Code CLI 로그인"
        )
    }
}
