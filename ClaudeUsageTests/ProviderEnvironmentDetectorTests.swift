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
        XCTAssertEqual(status.credentialState, ProviderCredentialState.refreshable)
        XCTAssertTrue(status.runtimeReachability)
        XCTAssertEqual(status.summary, "Gemini 로그인 정보를 갱신하고 있습니다")
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
        XCTAssertEqual(status.summary, "현재 로그인 방식은 지원하지 않습니다")
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
        XCTAssertEqual(status.summary, "Antigravity 앱을 실행하면 조회를 시작합니다")
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
                    extensionPort: nil,
                    extensionCsrfToken: nil,
                    httpsServerPort: nil
                ),
                hasAuthStatus: true,
                hasOAuthToken: true
            )
        )

        XCTAssertTrue(status.isDetected)
        XCTAssertEqual(status.credentialState, ProviderCredentialState.refreshable)
        XCTAssertFalse(status.runtimeReachability)
        XCTAssertTrue(status.summary.contains("연결 준비 중"))
        XCTAssertFalse(status.summary.contains("포트"))
    }
}
