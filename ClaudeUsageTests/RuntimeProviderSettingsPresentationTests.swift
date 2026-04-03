import XCTest
@testable import ClaudeUsage

final class RuntimeProviderSettingsPresentationTests: XCTestCase {
    func testGeminiRefreshOnlyUsesRefreshingCredentialStage() {
        let presentation = RuntimeProviderSettingsPresentation.makeGemini(
            isEnabled: true,
            environmentStatus: ProviderEnvironmentStatus(
                isDetected: true,
                credentialState: .refreshable,
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
        XCTAssertEqual(presentation.summary, "토큰 갱신 후 연결 확인 중입니다")
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
        XCTAssertTrue(presentation.primaryActionDetail.contains("실행 파일"))
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
        XCTAssertTrue(presentation.summary.contains("앱 실행"))
    }

    func testAntigravityRuntimeConnectionUsesProbingStage() {
        let presentation = RuntimeProviderSettingsPresentation.makeAntigravity(
            isEnabled: true,
            environmentStatus: ProviderEnvironmentStatus(
                isDetected: true,
                credentialState: .refreshable,
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
                    extensionPort: 54377
                ),
                hasAuthStatus: true,
                hasOAuthToken: false
            )
        )

        XCTAssertEqual(presentation.stage, .probingRuntime)
        XCTAssertEqual(presentation.badgeTitle, "연결 확인 중")
        XCTAssertTrue(presentation.primaryActionDetail.contains("payload"))
    }
}
