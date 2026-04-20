import XCTest
@testable import ClaudeUsage

final class RuntimeProviderSettingsPresentationTests: XCTestCase {
    func testGeminiRefreshOnlyUsesRefreshingCredentialStage() {
        let presentation = RuntimeProviderSettingsPresentation.makeGemini(
            isEnabled: true,
            environmentStatus: ProviderEnvironmentStatus(
                isDetected: true,
                credentialState: ProviderCredentialState.refreshable,
                runtimeReachability: true,
                summary: "Gemini CLI OAuth 감지 · 액세스 토큰은 갱신이 필요합니다"
            ),
            signals: GeminiEnvironmentSignals(
                hasBinary: true,
                authType: .oauthPersonal,
                credentialState: .refreshOnly
            )
        )

        XCTAssertEqual(presentation.stage, .refreshingCredential)
        XCTAssertEqual(presentation.badgeTitle, "갱신 필요")
        XCTAssertEqual(presentation.summary, "로그인 정보를 새로 고치는 중입니다")
    }

    func testGeminiMissingBinaryDoesNotLookReadyEvenWhenCredentialExists() {
        let presentation = RuntimeProviderSettingsPresentation.makeGemini(
            isEnabled: true,
            environmentStatus: ProviderEnvironmentStatus(
                isDetected: true,
                credentialState: .usable,
                runtimeReachability: false,
                summary: "Gemini OAuth 자격 감지 · CLI 설치 경로를 확인하세요"
            ),
            signals: GeminiEnvironmentSignals(
                hasBinary: false,
                authType: .oauthPersonal,
                credentialState: .usable
            )
        )

        XCTAssertEqual(presentation.stage, .installRequired)
        XCTAssertEqual(presentation.badgeTitle, "설치 필요")
        XCTAssertTrue(presentation.primaryActionDetail.contains("Gemini"))
    }

    func testAntigravityPersistedAuthWithoutRunningAppStaysWaitingForApp() {
        let presentation = RuntimeProviderSettingsPresentation.makeAntigravity(
            isEnabled: true,
            environmentStatus: ProviderEnvironmentStatus(
                isDetected: true,
                credentialState: .unknown,
                runtimeReachability: false,
                summary: "Antigravity 인증 상태 감지 · 앱을 실행하면 조회를 시작합니다"
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
    }

    func testAntigravityRuntimeConnectionUsesProbingStage() {
        let presentation = RuntimeProviderSettingsPresentation.makeAntigravity(
            isEnabled: true,
            environmentStatus: ProviderEnvironmentStatus(
                isDetected: true,
                credentialState: ProviderCredentialState.refreshable,
                runtimeReachability: true,
                summary: "Antigravity quota 서버 감지 · 조회를 시도할 수 있습니다"
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
                    httpsServerPort: nil
                ),
                hasAuthStatus: true,
                hasOAuthToken: false
            )
        )

        XCTAssertEqual(presentation.stage, RuntimeProviderAuthStage.probingRuntime)
        XCTAssertEqual(presentation.badgeTitle, "연결 확인 중")
        XCTAssertTrue(presentation.primaryActionDetail.contains("사용량"))
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

    func testAppcastFailureShowsChannelHint() {
        let error = NSError(domain: "SUSparkleErrorDomain", code: 1002)

        let result = SparkleUpdateResultInterpreter.resolve(error: error, fallback: nil)

        guard case .error(let message) = result else {
            return XCTFail("Expected error result")
        }
        XCTAssertTrue(message.contains("staging appcast"))
    }
}
#endif
