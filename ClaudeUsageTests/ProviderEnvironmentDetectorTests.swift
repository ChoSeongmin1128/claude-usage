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

    func testAntigravityRelevantCredentialDependsOnConfiguredDataSource() {
        let appOnlySignals = AntigravityEnvironmentSignals(
            hasStateDirectory: true,
            appRunning: false,
            runningProcess: nil,
            hasAuthStatus: true,
            hasOAuthToken: false
        )
        let oauthSignals = AntigravityEnvironmentSignals(
            hasStateDirectory: false,
            appRunning: false,
            runningProcess: nil,
            hasAuthStatus: false,
            hasOAuthToken: false,
            oauthCredentialStatus: AntigravityOAuthCredentialStatus(
                hasCredential: true,
                email: "nathan@example.com",
                sourceDescription: "ClaudeUsage"
            )
        )

        XCTAssertTrue(appOnlySignals.hasCredentialRelevant(to: .localIDE))
        XCTAssertTrue(appOnlySignals.hasCredentialRelevant(to: .auto))
        XCTAssertFalse(appOnlySignals.hasCredentialRelevant(to: .googleOAuth))
        XCTAssertTrue(oauthSignals.hasCredentialRelevant(to: .googleOAuth))
        XCTAssertTrue(oauthSignals.hasCredentialRelevant(to: .auto))
        XCTAssertFalse(oauthSignals.hasCredentialRelevant(to: .localIDE))
    }

    func testAntigravitySetupPolicyTreatsRuntimeConnectionAsGoogleOAuthFallbackReady() {
        let runtimeSignals = AntigravityEnvironmentSignals(
            hasStateDirectory: true,
            appRunning: true,
            runningProcess: AntigravityProcessSnapshot(
                pid: 42,
                command: "language_server_macos --csrf_token token",
                csrfToken: "token",
                extensionPort: nil,
                extensionCsrfToken: nil,
                httpsServerPort: nil,
                cloudCodeEndpoint: "https://daily-cloudcode-pa.googleapis.com"
            ),
            hasAuthStatus: true,
            hasOAuthToken: false
        )
        let noRuntimeSignals = AntigravityEnvironmentSignals(
            hasStateDirectory: true,
            appRunning: false,
            runningProcess: nil,
            hasAuthStatus: true,
            hasOAuthToken: false
        )

        XCTAssertFalse(AntigravitySetupPolicy.requiresInteractiveSetup(
            dataSource: .googleOAuth,
            signals: runtimeSignals
        ))
        XCTAssertTrue(AntigravitySetupPolicy.requiresInteractiveSetup(
            dataSource: .googleOAuth,
            signals: noRuntimeSignals
        ))
    }

    func testInterpretAntigravityAcceptsCsrfOnlyRuntimeForReachability() {
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
                    httpsServerPort: nil,
                    cloudCodeEndpoint: nil
                ),
                hasAuthStatus: true,
                hasOAuthToken: true
            )
        )

        XCTAssertTrue(status.isDetected)
        XCTAssertEqual(status.credentialState, ProviderCredentialState.refreshable)
        XCTAssertTrue(status.runtimeReachability)
        XCTAssertTrue(status.canAttemptRefresh)
        XCTAssertTrue(status.summary.contains("연결 확인"))
        XCTAssertFalse(status.summary.contains("포트"))
    }

    func testInterpretAntigravityUsesOAuthCredentialAsRefreshReachabilityWithoutRuntimeConnection() {
        let status = ProviderEnvironmentDetector.interpretAntigravity(
            signals: AntigravityEnvironmentSignals(
                hasStateDirectory: false,
                appRunning: false,
                runningProcess: nil,
                hasAuthStatus: false,
                hasOAuthToken: false,
                oauthCredentialStatus: AntigravityOAuthCredentialStatus(
                    hasCredential: true,
                    email: "nathan@example.com",
                    sourceDescription: "ClaudeUsage"
                )
            )
        )

        XCTAssertTrue(status.isDetected)
        XCTAssertEqual(status.credentialState, .usable)
        XCTAssertFalse(status.runtimeReachability)
        XCTAssertTrue(status.canAttemptRefresh)
        XCTAssertEqual(status.summary, "Antigravity OAuth 연결 확인됨")
    }

    func testInterpretAntigravityOAuthWithCLISurfaceDoesNotClaimCLIUsageIncluded() {
        let status = ProviderEnvironmentDetector.interpretAntigravity(
            signals: AntigravityEnvironmentSignals(
                hasStateDirectory: false,
                hasCLIBinary: true,
                hasCLISettingsFile: true,
                appRunning: false,
                runningProcess: nil,
                hasAuthStatus: false,
                hasOAuthToken: false,
                oauthCredentialStatus: AntigravityOAuthCredentialStatus(
                    hasCredential: true,
                    email: "nathan@example.com",
                    sourceDescription: "ClaudeUsage"
                )
            )
        )

        XCTAssertTrue(status.isDetected)
        XCTAssertTrue(status.canAttemptRefresh)
        XCTAssertEqual(status.summary, "Antigravity OAuth 연결 확인됨 · CLI 감지")
        XCTAssertFalse(status.summary.contains("CLI 포함"))
        XCTAssertFalse(status.summary.contains("CLI 사용량 포함"))
    }

    func testInterpretAntigravityMarksCLIInstallAsDetectedButNeedsOAuth() {
        let status = ProviderEnvironmentDetector.interpretAntigravity(
            signals: AntigravityEnvironmentSignals(
                hasStateDirectory: false,
                hasCLIBinary: true,
                appRunning: false,
                runningProcess: nil,
                hasAuthStatus: false,
                hasOAuthToken: false
            )
        )

        XCTAssertTrue(status.isDetected)
        XCTAssertEqual(status.credentialState, .missing)
        XCTAssertFalse(status.runtimeReachability)
        XCTAssertFalse(status.canAttemptRefresh)
        XCTAssertEqual(status.summary, "Antigravity CLI 감지됨 · OAuth 연결 필요")
    }

    func testInterpretAntigravityMarksBrokenCLICommandAsRepairNeeded() {
        let status = ProviderEnvironmentDetector.interpretAntigravity(
            signals: AntigravityEnvironmentSignals(
                hasStateDirectory: false,
                cliBinaryStatus: .broken(path: "/opt/homebrew/bin/agy", target: "/Applications/Antigravity.app/missing"),
                appRunning: false,
                runningProcess: nil,
                hasAuthStatus: false,
                hasOAuthToken: false
            )
        )

        XCTAssertTrue(status.isDetected)
        XCTAssertEqual(status.credentialState, .missing)
        XCTAssertFalse(status.runtimeReachability)
        XCTAssertFalse(status.canAttemptRefresh)
        XCTAssertEqual(status.summary, "Antigravity CLI 복구 필요 · OAuth 연결 필요")
    }

    func testAntigravityCLIStatusMarksBrokenShellWrapperTarget() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeUsageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let missingTarget = directory.appendingPathComponent("missing-antigravity")
        let wrapper = directory.appendingPathComponent("agy")
        try "#!/bin/sh\nexec '\(missingTarget.path)' \"$@\"\n"
            .write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: wrapper.path
        )

        let status = ProviderEnvironmentDetector.antigravityCLIStatus(for: wrapper)

        XCTAssertEqual(status.kind, .broken)
        XCTAssertEqual(status.path, wrapper.path)
        XCTAssertEqual(status.brokenTarget, missingTarget.path)
    }

    func testAntigravityCLIStatusAcceptsShellWrapperWithRunnableTarget() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeUsageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = directory.appendingPathComponent("antigravity")
        try "#!/bin/sh\nexit 0\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: target.path
        )

        let wrapper = directory.appendingPathComponent("agy")
        try "#!/bin/sh\nexec '\(target.path)' \"$@\"\n"
            .write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: wrapper.path
        )

        let status = ProviderEnvironmentDetector.antigravityCLIStatus(for: wrapper)

        XCTAssertEqual(status.kind, .runnable)
        XCTAssertEqual(status.path, wrapper.path)
        XCTAssertNil(status.brokenTarget)
    }

    func testInterpretAntigravitySeparatesCLIStateFromAppState() {
        let status = ProviderEnvironmentDetector.interpretAntigravity(
            signals: AntigravityEnvironmentSignals(
                hasStateDirectory: false,
                hasCLIStateDirectory: true,
                appRunning: false,
                runningProcess: nil,
                hasAuthStatus: false,
                hasOAuthToken: false
            )
        )

        XCTAssertTrue(status.isDetected)
        XCTAssertEqual(status.credentialState, .missing)
        XCTAssertFalse(status.runtimeReachability)
        XCTAssertEqual(status.summary, "Antigravity CLI 감지됨 · OAuth 연결 필요")
    }

    func testInterpretAntigravityTreatsCLISettingsFileAsCLISurface() {
        let status = ProviderEnvironmentDetector.interpretAntigravity(
            signals: AntigravityEnvironmentSignals(
                hasStateDirectory: false,
                hasCLISettingsFile: true,
                appRunning: false,
                runningProcess: nil,
                hasAuthStatus: false,
                hasOAuthToken: false
            )
        )

        XCTAssertTrue(status.isDetected)
        XCTAssertEqual(status.credentialState, .missing)
        XCTAssertFalse(status.runtimeReachability)
        XCTAssertEqual(status.summary, "Antigravity CLI 감지됨 · OAuth 연결 필요")
    }
}
