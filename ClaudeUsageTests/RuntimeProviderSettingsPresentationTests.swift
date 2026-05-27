import XCTest
@testable import ClaudeUsage

final class RuntimeProviderSettingsPresentationTests: XCTestCase {
    func testAntigravityPersistedAuthWithoutRunningAppStaysWaitingForApp() {
        let presentation = RuntimeProviderSettingsPresentation.makeAntigravity(
            isEnabled: true,
            environmentStatus: ProviderEnvironmentStatus(
                isDetected: true,
                credentialState: .unknown,
                runtimeReachability: false,
                summary: "Antigravity 앱을 실행하면 조회를 시작합니다"
            ),
            signals: AntigravityEnvironmentSignals(
                hasStateDirectory: true,
                appRunning: false,
                runningProcess: nil,
                hasAuthStatus: true,
                hasOAuthToken: false
            )
        )

        XCTAssertEqual(presentation.stage, .waitingForApp)
        XCTAssertEqual(presentation.badgeTitle, "앱 필요")
        XCTAssertTrue(presentation.summary.contains("열려 있지 않습니다"))
        XCTAssertEqual(presentation.availableAction, .openAntigravityApp)
    }

    func testAntigravityConnectedAccountUsesSimpleReadyPresentation() {
        let presentation = RuntimeProviderSettingsPresentation.makeAntigravity(
            isEnabled: true,
            environmentStatus: ProviderEnvironmentStatus(
                isDetected: true,
                credentialState: .refreshable,
                runtimeReachability: false,
                refreshReachability: true,
                summary: "Antigravity 계정 연결됨"
            ),
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

        XCTAssertEqual(presentation.stage, .probingRuntime)
        XCTAssertEqual(presentation.badgeTitle, "계정 연결")
        XCTAssertTrue(presentation.nextStepDetail.contains("사용량 수치"))
        XCTAssertFalse(presentation.nextStepDetail.contains("원격 quota API"))
        XCTAssertNil(presentation.availableAction)
    }

    func testAntigravityConnectedAccountWithCLISurfaceKeepsPrimaryPresentationSimple() {
        let presentation = RuntimeProviderSettingsPresentation.makeAntigravity(
            isEnabled: true,
            environmentStatus: ProviderEnvironmentStatus(
                isDetected: true,
                credentialState: .usable,
                runtimeReachability: false,
                refreshReachability: true,
                summary: "Antigravity 계정 연결됨"
            ),
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

        XCTAssertEqual(presentation.stage, .probingRuntime)
        XCTAssertEqual(presentation.badgeTitle, "계정 연결")
        XCTAssertTrue(presentation.summary.contains("사용량"))
        XCTAssertFalse(presentation.summary.contains("Antigravity 원격 quota"))
        XCTAssertFalse(presentation.summary.contains("CLI 포함"))
        XCTAssertFalse(presentation.summary.contains("CLI 사용량 포함"))
    }

    func testAntigravityGoogleOAuthModeUsesRuntimeConnectionWhenAvailable() {
        let presentation = RuntimeProviderSettingsPresentation.makeAntigravity(
            isEnabled: true,
            environmentStatus: ProviderEnvironmentStatus(
                isDetected: true,
                credentialState: .refreshable,
                runtimeReachability: true,
                summary: "Antigravity 연결 확인됨"
            ),
            signals: AntigravityEnvironmentSignals(
                hasStateDirectory: true,
                appRunning: true,
                runningProcess: AntigravityProcessSnapshot(
                    pid: 1234,
                    command: "language_server --csrf_token token",
                    csrfToken: "token",
                    extensionPort: nil,
                    extensionCsrfToken: nil,
                    httpsServerPort: nil,
                    cloudCodeEndpoint: "https://daily-cloudcode-pa.googleapis.com"
                ),
                hasAuthStatus: true,
                hasOAuthToken: false
            )
        )

        XCTAssertEqual(presentation.stage, .probingRuntime)
        XCTAssertEqual(presentation.badgeTitle, "연결 확인 중")
        XCTAssertTrue(presentation.summary.contains("앱 연결"))
    }

    func testAntigravityCLIInAutoModeUsesUsageSourceInsteadOfPromptingOAuth() {
        let presentation = RuntimeProviderSettingsPresentation.makeAntigravity(
            isEnabled: true,
            environmentStatus: ProviderEnvironmentStatus(
                isDetected: true,
                credentialState: .refreshable,
                runtimeReachability: false,
                refreshReachability: true,
                summary: "Antigravity 사용량 조회 준비"
            ),
            signals: AntigravityEnvironmentSignals(
                hasStateDirectory: false,
                hasCLIBinary: true,
                appRunning: false,
                runningProcess: nil,
                hasAuthStatus: false,
                hasOAuthToken: false
            )
        )

        XCTAssertEqual(presentation.stage, .probingRuntime)
        XCTAssertEqual(presentation.badgeTitle, "조회 준비")
        XCTAssertEqual(presentation.nextStepTitle, "사용량 조회")
        XCTAssertTrue(presentation.nextStepDetail.contains("CLI 로그인"))
        XCTAssertNil(presentation.availableAction)
    }

    func testAntigravityBrokenCLICommandPromptsRepairInsteadOfClaimingReadyCLI() {
        let presentation = RuntimeProviderSettingsPresentation.makeAntigravity(
            isEnabled: true,
            environmentStatus: ProviderEnvironmentStatus(
                isDetected: true,
                credentialState: .missing,
                runtimeReachability: false,
                summary: "Antigravity CLI 복구 필요 · OAuth 연결 필요"
            ),
            signals: AntigravityEnvironmentSignals(
                hasStateDirectory: false,
                cliBinaryStatus: .broken(
                    path: "/opt/homebrew/bin/agy",
                    target: "/Applications/Antigravity.app/Contents/Resources/app/bin/antigravity"
                ),
                appRunning: false,
                runningProcess: nil,
                hasAuthStatus: false,
                hasOAuthToken: false
            )
        )

        XCTAssertEqual(presentation.stage, .authRequired)
        XCTAssertEqual(presentation.badgeTitle, "CLI 복구")
        XCTAssertEqual(presentation.badgeTone, .red)
        XCTAssertEqual(presentation.nextStepTitle, "CLI 재설치")
        XCTAssertTrue(presentation.summary.contains("실행 대상"))
        XCTAssertTrue(presentation.nextStepDetail.contains("agy"))
        XCTAssertNil(presentation.availableAction)
    }

    func testAntigravityOAuthReadyWithBrokenCLIDoesNotClaimCLIIncluded() {
        let presentation = RuntimeProviderSettingsPresentation.makeAntigravity(
            isEnabled: true,
            environmentStatus: ProviderEnvironmentStatus(
                isDetected: true,
                credentialState: .usable,
                runtimeReachability: false,
                refreshReachability: true,
                summary: "Antigravity 계정 연결됨"
            ),
            signals: AntigravityEnvironmentSignals(
                hasStateDirectory: false,
                cliBinaryStatus: .broken(
                    path: "/opt/homebrew/bin/agy",
                    target: "/Applications/Antigravity.app/Contents/Resources/app/bin/antigravity"
                ),
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

        XCTAssertEqual(presentation.stage, .probingRuntime)
        XCTAssertEqual(presentation.badgeTitle, "계정 연결")
        XCTAssertTrue(presentation.summary.contains("CLI 명령은 복구가 필요"))
        XCTAssertFalse(presentation.summary.contains("CLI 포함"))
    }

    func testAntigravityCLIStateWithoutExecutablePromptsCLIConfirmation() {
        let presentation = RuntimeProviderSettingsPresentation.makeAntigravity(
            isEnabled: true,
            environmentStatus: ProviderEnvironmentStatus(
                isDetected: true,
                credentialState: .missing,
                runtimeReachability: false,
                summary: "Antigravity CLI 설정 확인 필요"
            ),
            signals: AntigravityEnvironmentSignals(
                hasStateDirectory: false,
                hasCLIStateDirectory: true,
                appRunning: false,
                runningProcess: nil,
                hasAuthStatus: false,
                hasOAuthToken: false
            )
        )

        XCTAssertEqual(presentation.stage, .authRequired)
        XCTAssertEqual(presentation.badgeTitle, "CLI 설정")
        XCTAssertEqual(presentation.nextStepTitle, "AGY CLI 확인")
        XCTAssertNil(presentation.availableAction)
    }

    func testAntigravityRuntimeConnectionUsesProbingStage() {
        let presentation = RuntimeProviderSettingsPresentation.makeAntigravity(
            isEnabled: true,
            environmentStatus: ProviderEnvironmentStatus(
                isDetected: true,
                credentialState: ProviderCredentialState.refreshable,
                runtimeReachability: true,
                summary: "Antigravity 연결 확인됨"
            ),
            signals: AntigravityEnvironmentSignals(
                hasStateDirectory: true,
                appRunning: true,
                runningProcess: AntigravityProcessSnapshot(
                    pid: 1234,
                    command: "/Applications/Antigravity.app/Contents/MacOS/language_server_macos_arm",
                    csrfToken: "token",
                    extensionPort: 54377,
                    extensionCsrfToken: nil,
                    httpsServerPort: nil,
                    cloudCodeEndpoint: nil
                ),
                hasAuthStatus: true,
                hasOAuthToken: false
            )
        )

        XCTAssertEqual(presentation.stage, RuntimeProviderAuthStage.probingRuntime)
        XCTAssertEqual(presentation.badgeTitle, "연결 확인 중")
        XCTAssertTrue(presentation.nextStepDetail.contains("사용량"))
        XCTAssertNil(presentation.availableAction)
    }
}

#if canImport(Sparkle)
final class SparkleUpdateResultInterpreterTests: XCTestCase {
    func testNoUpdateOnLatestVersionBecomesUpToDate() {
        let error = NSError(
            domain: "SUSparkleErrorDomain",
            code: 1001,
            userInfo: ["SUNoUpdateFoundReason": 1]
        )

        let result = SparkleUpdateResultInterpreter.resolve(error: error, fallback: nil)

        guard case .upToDate(let message) = result else {
            return XCTFail("Expected upToDate result")
        }
        XCTAssertEqual(message, "현재 설치본이 최신 버전입니다")
    }

    func testNoUpdateWhenAppIsNewerThanFeedStillBecomesUpToDate() {
        let error = NSError(
            domain: "SUSparkleErrorDomain",
            code: 1001,
            userInfo: ["SUNoUpdateFoundReason": 2]
        )

        let result = SparkleUpdateResultInterpreter.resolve(error: error, fallback: nil)

        guard case .upToDate(let message) = result else {
            return XCTFail("Expected upToDate result")
        }
        XCTAssertEqual(message, "현재 설치본이 업데이트 채널보다 새 버전입니다")
    }

    func testDiskImageExecutionShowsActionableError() {
        let error = NSError(domain: "SUSparkleErrorDomain", code: 1003)

        let result = SparkleUpdateResultInterpreter.resolve(error: error, fallback: nil)

        guard case .error(let message) = result else {
            return XCTFail("Expected error result")
        }
        XCTAssertTrue(message.contains("응용 프로그램 폴더"))
    }

    func testAppcastFailureShowsUserFacingRetryHint() {
        let error = NSError(domain: "SUSparkleErrorDomain", code: 1002)

        let result = SparkleUpdateResultInterpreter.resolve(error: error, fallback: nil)

        guard case .error(let message) = result else {
            return XCTFail("Expected error result")
        }
        XCTAssertTrue(message.contains("업데이트 정보를 확인하지 못했습니다"))
        XCTAssertFalse(message.contains("appcast"))
    }
}
#endif

final class PublicCopySanityTests: XCTestCase {
    func testNormalUserFacingCopyDoesNotExposeInternalImplementationTerms() {
        let antigravityStatus = ProviderEnvironmentDetector.interpretAntigravity(
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
        let claudeAccountPresentation = ClaudeAccountSettingsPresentation.resolve(
            account: ClaudeAccount(
                id: "web",
                kind: .webSession,
                displayName: "Chrome Nathan",
                identity: ClaudeAccountIdentity(organizationName: "Glorang"),
                source: .chromeProfile,
                sourceDetail: "Nathan (Profile 2) · nathan@glorang.com",
                lastValidationState: .detected
            )
        )

        assertNoInternalTerms(in: [
            antigravityStatus.summary,
            claudeAccountPresentation.primaryTitle,
            claudeAccountPresentation.secondaryLine ?? "",
            claudeAccountPresentation.statusText,
        ])
    }

    private func assertNoInternalTerms(in strings: [String], file: StaticString = #filePath, line: UInt = #line) {
        let blockedTerms = [
            "Sparkle",
            "appcast",
            "refresh token",
            "refresh_token",
            "액세스 토큰",
            "quota 서버",
            "포트",
            "실행 경로",
            "OAuth 자격",
            "엔진",
            "식별:",
            "출처:",
            "현재 사용 경로",
            "감지됨",
        ]

        for text in strings {
            for term in blockedTerms {
                XCTAssertFalse(
                    text.localizedCaseInsensitiveContains(term),
                    "Blocked term '\(term)' found in '\(text)'",
                    file: file,
                    line: line
                )
            }
        }
    }
}
