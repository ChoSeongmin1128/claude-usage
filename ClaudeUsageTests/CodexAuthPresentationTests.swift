import XCTest
@testable import ClaudeUsage

@MainActor
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

    func testExplicitlyExpiredTokenIsExpired() {
        // expires_at 가 응답에 명시되어 있고 그 시각이 과거 → 만료 판정.
        // [A] 신정책: expiresAtIsExplicit=true 일 때만 만료를 판단한다.
        let expiredToken = CodexAuthToken(
            accessToken: "expired",
            refreshToken: "refresh",
            expiresAt: Date(timeIntervalSinceNow: -60),
            expiresAtIsExplicit: true
        )

        let status = CodexAuthStatusResolver.resolve(
            isProviderEnabled: true,
            authJsonExists: true,
            token: expiredToken,
            isCodexInstalled: { false }
        )

        // [C] status 조회는 read-only — refresh 시도하지 않고 .expired 그대로 노출.
        XCTAssertEqual(status, .expired)
    }

    func testInferredExpiryWithoutExplicitFieldIsTreatedAsAlive() {
        // 사용자 환경의 ~/.codex/auth.json 에는 `tokens.expires_at` 가 없는 경우가 흔하다.
        // 우리가 last_refresh+8일 같은 휴리스틱으로 만료를 추정해 refresh 호출하면
        // OAuth refresh_token rotation 으로 reused 에러가 발생한다.
        // [A] expiresAtIsExplicit=false 면 isExpired=false 로 간주 → status .authenticated.
        let inferredToken = CodexAuthToken(
            accessToken: "may-still-be-alive",
            refreshToken: "refresh",
            expiresAt: nil,
            expiresAtIsExplicit: false
        )

        let status = CodexAuthStatusResolver.resolve(
            isProviderEnabled: true,
            authJsonExists: true,
            token: inferredToken,
            isCodexInstalled: { false }
        )

        XCTAssertEqual(status, .authenticated)
    }

    func testExpiredTokenWithRefreshTokenIsRefreshable() {
        let expiredToken = CodexAuthToken(
            accessToken: "expired",
            refreshToken: "refresh",
            expiresAt: Date(timeIntervalSinceNow: -60),
            expiresAtIsExplicit: true
        )

        XCTAssertTrue(expiredToken.hasRefreshToken)
        XCTAssertTrue(expiredToken.isUsableOrRefreshable)
    }

    func testMissingAuthJsonUsesInstalledState() {
        let status = CodexAuthStatusResolver.resolve(
            isProviderEnabled: true,
            authJsonExists: false,
            token: nil,
            isCodexInstalled: { true }
        )

        XCTAssertEqual(status, .notLoggedIn)
    }
}
