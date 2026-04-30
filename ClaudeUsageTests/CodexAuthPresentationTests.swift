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
        XCTAssertTrue(presentation.statusTitle.contains("갱신하지 못했습니다"))
        XCTAssertTrue(presentation.actionDetail?.contains("다시 실행") == true)
    }

    func testAuthenticatedDoesNotShowTerminalCommand() {
        let presentation = CodexAuthPresentation.resolve(for: .authenticated)

        XCTAssertNil(presentation.command)
        XCTAssertNil(presentation.actionDetail)
    }

    func testExpiredTokenWithRefreshTokenBecomesAuthenticatedWhenRefreshSucceeds() async {
        let expiredToken = CodexAuthToken(
            accessToken: "expired",
            refreshToken: "refresh",
            expiresAt: Date(timeIntervalSinceNow: -60)
        )
        let refreshedToken = CodexAuthToken(
            accessToken: "fresh",
            refreshToken: "refresh",
            expiresAt: Date(timeIntervalSinceNow: 3600)
        )

        let status = await CodexAuthStatusResolver.resolve(
            isProviderEnabled: true,
            authJsonExists: true,
            token: expiredToken,
            isCodexInstalled: { false },
            refreshAccessToken: { refreshToken in
                XCTAssertEqual(refreshToken, "refresh")
                return refreshedToken
            }
        )

        XCTAssertEqual(status, .authenticated)
    }

    func testExpiredTokenWithRefreshTokenStaysExpiredWhenRefreshFails() async {
        let expiredToken = CodexAuthToken(
            accessToken: "expired",
            refreshToken: "refresh",
            expiresAt: Date(timeIntervalSinceNow: -60)
        )

        let status = await CodexAuthStatusResolver.resolve(
            isProviderEnabled: true,
            authJsonExists: true,
            token: expiredToken,
            isCodexInstalled: { false },
            refreshAccessToken: { _ in nil }
        )

        XCTAssertEqual(status, .expired)
    }

    func testExpiredTokenWithoutRefreshTokenDoesNotAttemptRefresh() async {
        let expiredToken = CodexAuthToken(
            accessToken: "expired",
            refreshToken: nil,
            expiresAt: Date(timeIntervalSinceNow: -60)
        )
        var refreshCalled = false

        let status = await CodexAuthStatusResolver.resolve(
            isProviderEnabled: true,
            authJsonExists: true,
            token: expiredToken,
            isCodexInstalled: { false },
            refreshAccessToken: { _ in
                refreshCalled = true
                return nil
            }
        )

        XCTAssertEqual(status, .expired)
        XCTAssertFalse(refreshCalled)
        XCTAssertFalse(expiredToken.isUsableOrRefreshable)
    }

    func testExpiredTokenWithRefreshTokenIsRefreshable() {
        let expiredToken = CodexAuthToken(
            accessToken: "expired",
            refreshToken: "refresh",
            expiresAt: Date(timeIntervalSinceNow: -60)
        )

        XCTAssertTrue(expiredToken.hasRefreshToken)
        XCTAssertTrue(expiredToken.isUsableOrRefreshable)
    }

    func testMissingAuthJsonUsesInstalledState() async {
        let status = await CodexAuthStatusResolver.resolve(
            isProviderEnabled: true,
            authJsonExists: false,
            token: nil,
            isCodexInstalled: { true },
            refreshAccessToken: { _ in nil }
        )

        XCTAssertEqual(status, .notLoggedIn)
    }
}
