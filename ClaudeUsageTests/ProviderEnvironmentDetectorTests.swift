import XCTest
@testable import ClaudeUsage

final class ProviderEnvironmentDetectorTests: XCTestCase {
    func testInterpretGeminiMarksRefreshOnlyOauthAsRefreshableAndReachable() {
        let status = ProviderEnvironmentDetector.interpretGemini(
            signals: GeminiEnvironmentSignals(
                hasBinary: true,
                authType: .oauthPersonal,
                credentialState: .refreshOnly
            )
        )

        XCTAssertTrue(status.isDetected)
        XCTAssertEqual(status.credentialState, .refreshable)
        XCTAssertTrue(status.runtimeReachability)
        XCTAssertEqual(status.summary, "Gemini CLI OAuth 감지 · 액세스 토큰은 갱신이 필요합니다")
    }

    func testInterpretGeminiTreatsApiKeyModeAsUnsupportedInteractiveSetup() {
        let status = ProviderEnvironmentDetector.interpretGemini(
            signals: GeminiEnvironmentSignals(
                hasBinary: true,
                authType: .apiKey,
                credentialState: .usable
            )
        )

        XCTAssertFalse(status.isDetected)
        XCTAssertEqual(status.credentialState, .missing)
        XCTAssertFalse(status.runtimeReachability)
        XCTAssertTrue(status.summary.contains("API 키"))
    }

    func testInterpretAntigravitySeparatesPersistedAuthFromRuntimeReachability() {
        let status = ProviderEnvironmentDetector.interpretAntigravity(
            signals: AntigravityEnvironmentSignals(
                hasStateDirectory: true,
                appRunning: false,
                runningProcess: nil,
                hasAuthStatus: true,
                hasOAuthToken: false
            )
        )

        XCTAssertTrue(status.isDetected)
        XCTAssertEqual(status.credentialState, .unknown)
        XCTAssertFalse(status.runtimeReachability)
        XCTAssertEqual(status.summary, "Antigravity 인증 상태 감지 · 앱을 실행하면 조회를 시작합니다")
    }

    func testInterpretAntigravityRequiresCsrfAndPortForReachability() {
        let status = ProviderEnvironmentDetector.interpretAntigravity(
            signals: AntigravityEnvironmentSignals(
                hasStateDirectory: true,
                appRunning: true,
                runningProcess: AntigravityProcessSnapshot(
                    pid: 42,
                    command: "language_server_macos --csrf_token token",
                    csrfToken: "token",
                    extensionPort: nil
                ),
                hasAuthStatus: true,
                hasOAuthToken: true
            )
        )

        XCTAssertTrue(status.isDetected)
        XCTAssertEqual(status.credentialState, .refreshable)
        XCTAssertFalse(status.runtimeReachability)
        XCTAssertTrue(status.summary.contains("연결 준비 중"))
    }
}
