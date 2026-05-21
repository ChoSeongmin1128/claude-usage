import XCTest
@testable import ClaudeUsage

final class RuntimeProviderSettingsPresentationTests: XCTestCase {
    func testAntigravityAutoSourceDetailShowsLastResolvedConcreteSource() {
        XCTAssertEqual(
            RuntimeProviderSettingsPresentation.antigravityResolvedSourceDetail(
                configuredSource: .auto,
                lastResolvedSource: .googleOAuth
            ),
            "최근 조회 경로: Google OAuth"
        )
        XCTAssertNil(RuntimeProviderSettingsPresentation.antigravityResolvedSourceDetail(
            configuredSource: .localIDE,
            lastResolvedSource: .googleOAuth
        ))
        XCTAssertNil(RuntimeProviderSettingsPresentation.antigravityResolvedSourceDetail(
            configuredSource: .auto,
            lastResolvedSource: nil
        ))
    }

    func testGeminiRefreshOnlyUsesRefreshingCredentialStage() {
        let presentation = RuntimeProviderSettingsPresentation.makeGemini(
            isEnabled: true,
            environmentStatus: ProviderEnvironmentStatus(
                isDetected: true,
                credentialState: ProviderCredentialState.refreshable,
                runtimeReachability: true,
                summary: "Gemini 로그인 정보를 갱신하고 있습니다"
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
                summary: "Gemini 설치를 확인해 주세요"
            ),
            signals: GeminiEnvironmentSignals(
                hasBinary: false,
                authType: .oauthPersonal,
                credentialState: .usable
            )
        )

        XCTAssertEqual(presentation.stage, .installRequired)
        XCTAssertEqual(presentation.badgeTitle, "설치 필요")
        XCTAssertTrue(presentation.nextStepDetail.contains("Gemini"))
        XCTAssertNil(presentation.availableAction)
    }

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

    func testAntigravityOAuthCredentialUsesRemoteReadyPresentationWhenDataSourceAllowsIt() {
        let presentation = RuntimeProviderSettingsPresentation.makeAntigravity(
            isEnabled: true,
            environmentStatus: ProviderEnvironmentStatus(
                isDetected: true,
                credentialState: .refreshable,
                runtimeReachability: false,
                refreshReachability: true,
                summary: "Antigravity OAuth 연결 확인됨"
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
            ),
            dataSource: .auto
        )

        XCTAssertEqual(presentation.stage, .probingRuntime)
        XCTAssertEqual(presentation.badgeTitle, "OAuth 연결")
        XCTAssertTrue(presentation.nextStepDetail.contains("원격 quota API"))
        XCTAssertNil(presentation.availableAction)
    }

    func testAntigravityOAuthCredentialWithCLISurfaceDoesNotClaimSeparateCLIUsageSource() {
        let presentation = RuntimeProviderSettingsPresentation.makeAntigravity(
            isEnabled: true,
            environmentStatus: ProviderEnvironmentStatus(
                isDetected: true,
                credentialState: .usable,
                runtimeReachability: false,
                refreshReachability: true,
                summary: "Antigravity OAuth 연결 확인됨 · CLI 감지"
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
            ),
            dataSource: .auto
        )

        XCTAssertEqual(presentation.stage, .probingRuntime)
        XCTAssertEqual(presentation.badgeTitle, "OAuth 연결")
        XCTAssertTrue(presentation.summary.contains("Antigravity 원격 quota"))
        XCTAssertFalse(presentation.summary.contains("CLI 포함"))
        XCTAssertFalse(presentation.summary.contains("CLI 사용량 포함"))
    }

    func testAntigravityGoogleOAuthModeIgnoresAppPersistedAuthAndPromptsOAuth() {
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
            ),
            dataSource: .googleOAuth
        )

        XCTAssertEqual(presentation.stage, .authRequired)
        XCTAssertEqual(presentation.badgeTitle, "OAuth 필요")
        XCTAssertEqual(presentation.nextStepTitle, "Google OAuth 연결")
        XCTAssertNil(presentation.availableAction)
    }

    func testAntigravityCLIRemoteModePromptsOAuthInsteadOfOpeningApp() {
        let presentation = RuntimeProviderSettingsPresentation.makeAntigravity(
            isEnabled: true,
            environmentStatus: ProviderEnvironmentStatus(
                isDetected: true,
                credentialState: .missing,
                runtimeReachability: false,
                summary: "Antigravity CLI 감지됨 · OAuth 연결 필요"
            ),
            signals: AntigravityEnvironmentSignals(
                hasStateDirectory: false,
                hasCLIBinary: true,
                appRunning: false,
                runningProcess: nil,
                hasAuthStatus: false,
                hasOAuthToken: false
            ),
            dataSource: .auto
        )

        XCTAssertEqual(presentation.stage, .authRequired)
        XCTAssertEqual(presentation.badgeTitle, "CLI 감지")
        XCTAssertEqual(presentation.nextStepTitle, "Google OAuth 연결")
        XCTAssertTrue(presentation.nextStepDetail.contains("원격 사용량"))
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
            ),
            dataSource: .auto
        )

        XCTAssertEqual(presentation.stage, .authRequired)
        XCTAssertEqual(presentation.badgeTitle, "CLI 복구")
        XCTAssertEqual(presentation.badgeTone, .red)
        XCTAssertEqual(presentation.nextStepTitle, "CLI 재설치 후 Google OAuth 연결")
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
                summary: "Antigravity OAuth 연결 확인됨"
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
            ),
            dataSource: .auto
        )

        XCTAssertEqual(presentation.stage, .probingRuntime)
        XCTAssertEqual(presentation.badgeTitle, "OAuth 연결")
        XCTAssertTrue(presentation.summary.contains("CLI 명령은 복구가 필요"))
        XCTAssertFalse(presentation.summary.contains("CLI 포함"))
    }

    func testAntigravityCLIStateRemoteModePromptsOAuthWithoutOpeningApp() {
        let presentation = RuntimeProviderSettingsPresentation.makeAntigravity(
            isEnabled: true,
            environmentStatus: ProviderEnvironmentStatus(
                isDetected: true,
                credentialState: .missing,
                runtimeReachability: false,
                summary: "Antigravity CLI 감지됨 · OAuth 연결 필요"
            ),
            signals: AntigravityEnvironmentSignals(
                hasStateDirectory: false,
                hasCLIStateDirectory: true,
                appRunning: false,
                runningProcess: nil,
                hasAuthStatus: false,
                hasOAuthToken: false
            ),
            dataSource: .auto
        )

        XCTAssertEqual(presentation.stage, .authRequired)
        XCTAssertEqual(presentation.badgeTitle, "CLI 설정")
        XCTAssertEqual(presentation.nextStepTitle, "Google OAuth 연결")
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
                    httpsServerPort: nil
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
        let geminiStatus = ProviderEnvironmentDetector.interpretGemini(
            signals: GeminiEnvironmentSignals(
                hasBinary: true,
                authType: .oauthPersonal,
                credentialState: .refreshOnly
            )
        )
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
                    httpsServerPort: nil
                ),
                hasAuthStatus: true,
                hasOAuthToken: true
            )
        )
        let geminiPresentation = RuntimeProviderSettingsPresentation.makeGemini(
            isEnabled: true,
            environmentStatus: geminiStatus,
            signals: GeminiEnvironmentSignals(
                hasBinary: false,
                authType: .oauthPersonal,
                credentialState: .usable
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
            geminiStatus.summary,
            antigravityStatus.summary,
            geminiPresentation.summary,
            geminiPresentation.nextStepTitle,
            geminiPresentation.nextStepDetail,
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
