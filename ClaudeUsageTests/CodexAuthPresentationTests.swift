import XCTest
@testable import ClaudeUsage

final class CodexAuthPresentationTests: XCTestCase {
    func testNotLoggedInTellsUserToRunCodexLoginInTerminal() {
        let presentation = CodexAuthPresentation.resolve(for: .notLoggedIn)

        XCTAssertEqual(presentation.command, "codex login")
        XCTAssertTrue(presentation.statusTitle.contains("터미널"))
        XCTAssertTrue(presentation.actionDetail?.contains("codex login") == true)
        XCTAssertTrue(presentation.actionDetail?.contains("다시 확인") == true)
    }

    func testExpiredTellsUserToRunCodexLoginAgain() {
        let presentation = CodexAuthPresentation.resolve(for: .expired)

        XCTAssertEqual(presentation.command, "codex login")
        XCTAssertTrue(presentation.statusBadgeTitle.contains("다시 로그인"))
        XCTAssertTrue(presentation.actionDetail?.contains("다시 실행") == true)
    }

    func testAuthenticatedDoesNotShowTerminalCommand() {
        let presentation = CodexAuthPresentation.resolve(for: .authenticated)

        XCTAssertNil(presentation.command)
        XCTAssertNil(presentation.actionDetail)
    }
}
