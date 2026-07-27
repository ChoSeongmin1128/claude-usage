import XCTest
@testable import ClaudeUsage

final class ProviderEnvironmentDetectorTests: XCTestCase {
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

    /// runtime 연결이 있거나 앱/CLI 자격 흔적이 있으면 대화형 초기 설정을
    /// 요구하지 않는다. 둘 다 없을 때만 요구한다.
    func testAntigravityInteractiveSetupFollowsRuntimeConnectionAndCredentialTrace() {
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

        let bareSignals = AntigravityEnvironmentSignals(
            hasStateDirectory: false,
            appRunning: false,
            runningProcess: nil,
            hasAuthStatus: false,
            hasOAuthToken: false
        )

        XCTAssertFalse(runtimeSignals.requiresInteractiveSetup)
        XCTAssertFalse(noRuntimeSignals.requiresInteractiveSetup)
        XCTAssertTrue(bareSignals.requiresInteractiveSetup)
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
        XCTAssertEqual(status.summary, "Antigravity 계정 연결됨")
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
        XCTAssertEqual(status.summary, "Antigravity 계정 연결됨")
        XCTAssertFalse(status.summary.contains("CLI 포함"))
        XCTAssertFalse(status.summary.contains("CLI 사용량 포함"))
    }

    func testInterpretAntigravityMarksRunnableCLIAsRefreshable() {
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
        XCTAssertEqual(status.credentialState, .refreshable)
        XCTAssertFalse(status.runtimeReachability)
        XCTAssertTrue(status.canAttemptRefresh)
        XCTAssertEqual(status.summary, "Antigravity 사용량 조회 준비")
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
        XCTAssertEqual(status.summary, "Antigravity CLI 복구 필요")
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

    func testAntigravityCLIStatusMarksBrokenSymlinkedShellWrapperTarget() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeUsageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let missingTarget = directory.appendingPathComponent("missing-antigravity")
        let wrapper = directory.appendingPathComponent("agy.wrapper.sh")
        try "#!/bin/sh\nexec '\(missingTarget.path)' \"$@\"\n"
            .write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: wrapper.path
        )

        let symlink = directory.appendingPathComponent("agy")
        try FileManager.default.createSymbolicLink(atPath: symlink.path, withDestinationPath: wrapper.path)

        let status = ProviderEnvironmentDetector.antigravityCLIStatus(for: symlink)

        XCTAssertEqual(status.kind, .broken)
        XCTAssertEqual(status.path, symlink.path)
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
        XCTAssertEqual(status.summary, "Antigravity CLI 설정 확인 필요")
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
        XCTAssertEqual(status.summary, "Antigravity CLI 설정 확인 필요")
    }
}
