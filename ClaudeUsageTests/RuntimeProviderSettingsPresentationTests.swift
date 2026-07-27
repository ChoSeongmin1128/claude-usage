import XCTest
@testable import ClaudeUsage

final class RuntimeProviderSettingsPresentationTests: XCTestCase {
    func testDisabledServiceDoesNotExposeRuntimeState() {
        let presentation = RuntimeProviderSettingsPresentation.makeAntigravity(
            isEnabled: false,
            state: AntigravityPresentationFixture.state(
                presentation: .ready(
                    AntigravityPresentationFixture.quotaSnapshot
                )
            )
        )

        XCTAssertEqual(presentation.stage, .disabled)
        XCTAssertEqual(presentation.badgeTitle, "비활성")
        XCTAssertEqual(presentation.availableAction, .enableService)
    }

    func testMissingTypedStateShowsDeterministicBootstrapPresentation() {
        let presentation = RuntimeProviderSettingsPresentation.makeAntigravity(
            isEnabled: true,
            state: nil
        )

        XCTAssertEqual(presentation.stage, .probingRuntime)
        XCTAssertEqual(presentation.badgeTitle, "준비 중")
        XCTAssertTrue(presentation.summary.contains("불러오는 중"))
        XCTAssertNil(presentation.availableAction)
    }

    func testBusyTypedStateTakesPriorityOverPreviousContent() {
        let presentation = RuntimeProviderSettingsPresentation.makeAntigravity(
            isEnabled: true,
            state: AntigravityPresentationFixture.state(
                activity: .changingAccount,
                presentation: .ready(
                    AntigravityPresentationFixture.quotaSnapshot
                )
            )
        )

        XCTAssertEqual(presentation.stage, .probingRuntime)
        XCTAssertEqual(presentation.badgeTitle, "확인 중")
        XCTAssertTrue(presentation.summary.contains("계정과 조회 방식"))
    }

    func testReadyTypedStateShowsObservedLaneCount() {
        let presentation = RuntimeProviderSettingsPresentation.makeAntigravity(
            isEnabled: true,
            state: AntigravityPresentationFixture.state(
                presentation: .ready(
                    AntigravityPresentationFixture.quotaSnapshot
                ),
                quotaPresentation: .content(
                    AntigravityPresentationFixture.quotaPresentation
                )
            )
        )

        XCTAssertEqual(presentation.stage, .probingRuntime)
        XCTAssertEqual(presentation.badgeTitle, "연결됨")
        XCTAssertEqual(presentation.summary, "1개 사용 한도를 확인했습니다")
        XCTAssertNil(presentation.availableAction)
    }

    func testPartialTypedStateExplainsThatUnsupportedValuesAreNotEstimated() {
        let state = AntigravityPresentationFixture.state(
            presentation: .partial(
                AntigravityPresentationFixture.quotaSnapshot,
                issues: [
                    AntigravityQuotaDecodeIssue(
                        kind: .missingRemainingFraction,
                        upstreamGroupID: "gemini",
                        groupLabel: "Gemini",
                        upstreamBucketID: "weekly"
                    )
                ]
            )
        )
        let presentation = RuntimeProviderSettingsPresentation.makeAntigravity(
            isEnabled: true,
            state: state
        )

        XCTAssertEqual(presentation.stage, .probingRuntime)
        XCTAssertEqual(presentation.badgeTitle, "일부 확인")
        XCTAssertEqual(presentation.badgeTone, .orange)
        XCTAssertTrue(presentation.nextStepDetail.contains("추정하지 않습니다"))
    }

    func testStaleTypedStateKeepsLastVerifiedResultExplicit() {
        let presentation = RuntimeProviderSettingsPresentation.makeAntigravity(
            isEnabled: true,
            state: AntigravityPresentationFixture.state(
                presentation: .stale(
                    AntigravityPresentationFixture.quotaSnapshot,
                    failure: .transportUnavailable(.localApp)
                )
            )
        )

        XCTAssertEqual(presentation.stage, .waitingForApp)
        XCTAssertEqual(presentation.badgeTitle, "이전 결과")
        XCTAssertTrue(presentation.summary.contains("마지막 검증 결과"))
    }

    func testMissingSelectedOAuthAccountRequestsAccountWithoutOpeningApp() {
        let presentation = RuntimeProviderSettingsPresentation.makeAntigravity(
            isEnabled: true,
            state: AntigravityPresentationFixture.state(
                presentation: .setupRequired(
                    .noSelectedOAuthAccount
                )
            )
        )

        XCTAssertEqual(presentation.stage, .authRequired)
        XCTAssertEqual(presentation.badgeTitle, "계정 필요")
        XCTAssertEqual(presentation.nextStepTitle, "Google 계정 연결")
        XCTAssertNil(presentation.availableAction)
    }

    func testMissingAmbientSessionOffersToOpenAntigravity() {
        let presentation = RuntimeProviderSettingsPresentation.makeAntigravity(
            isEnabled: true,
            state: AntigravityPresentationFixture.state(
                presentation: .setupRequired(
                    .noAmbientLocalSession
                )
            )
        )

        XCTAssertEqual(presentation.stage, .waitingForApp)
        XCTAssertEqual(presentation.badgeTitle, "앱 필요")
        XCTAssertEqual(presentation.availableAction, .openAntigravityApp)
    }

    func testAccountMismatchDoesNotExposeNumbersOrRecoveryShortcut() {
        let presentation = RuntimeProviderSettingsPresentation.makeAntigravity(
            isEnabled: true,
            state: AntigravityPresentationFixture.state(
                presentation: .accountMismatch(
                    expected: ProviderAccountIdentity(
                        stableAccountID: "expected",
                        email: "expected@example.com"
                    ),
                    received: ProviderAccountIdentity(
                        stableAccountID: "other",
                        email: "other@example.com"
                    )
                ),
                quotaPresentation: .unavailable(
                    .accountMismatch(
                        expected: ProviderAccountIdentity(
                            stableAccountID: "expected"
                        ),
                        received: ProviderAccountIdentity(
                            stableAccountID: "other"
                        )
                    )
                )
            )
        )

        XCTAssertEqual(presentation.stage, .authRequired)
        XCTAssertEqual(presentation.badgeTitle, "계정 불일치")
        XCTAssertTrue(presentation.summary.contains("표시하지 않았습니다"))
        XCTAssertNil(presentation.availableAction)
    }

    func testIdentityOnlyStateExplainsNumericQuotaAbsence() {
        let identityOnly =
            AntigravityPresentationState
                .identityOnly(
                    AntigravityIdentityOnlyUsage(
                        identity:
                            ProviderAccountIdentity(
                                stableAccountID:
                                    "subject-1",
                                email:
                                    "nathan@example.com"
                            ),
                        plan: "Pro",
                        provenance:
                            AntigravityPresentationFixture
                                .provenance,
                        fetchedAt:
                            AntigravityPresentationFixture
                                .now
                    )
                )
        let presentation =
            RuntimeProviderSettingsPresentation
                .makeAntigravity(
                    isEnabled: true,
                    state:
                        AntigravityPresentationFixture
                            .state(
                                presentation:
                                    identityOnly
                            )
                )

        XCTAssertEqual(
            presentation.stage,
            .probingRuntime
        )
        XCTAssertEqual(
            presentation.badgeTitle,
            "수치 없음"
        )
        XCTAssertTrue(
            presentation.summary
                .contains("수치형 사용 한도")
        )
    }

    func testAuthenticationFailureAndTransportFailureUseDifferentStages() {
        let authentication =
            RuntimeProviderSettingsPresentation
                .makeAntigravity(
                    isEnabled: true,
                    state:
                        AntigravityPresentationFixture
                            .state(
                                presentation:
                                    .failed(
                                        .authenticationRequired(
                                            .googleOAuth
                                        )
                                    )
                            )
                )
        let transport =
            RuntimeProviderSettingsPresentation
                .makeAntigravity(
                    isEnabled: true,
                    state:
                        AntigravityPresentationFixture
                            .state(
                                presentation:
                                    .failed(
                                        .transportUnavailable(
                                            .localApp
                                        )
                                    )
                            )
                )

        XCTAssertEqual(
            authentication.stage,
            .authRequired
        )
        XCTAssertEqual(
            authentication.badgeTitle,
            "인증 필요"
        )
        XCTAssertEqual(
            transport.stage,
            .probingRuntime
        )
        XCTAssertEqual(
            transport.badgeTitle,
            "조회 실패"
        )
    }

    func testControllerDisabledStateRemainsBootstrapStateWhileServiceIsEnabled() {
        let presentation =
            RuntimeProviderSettingsPresentation
                .makeAntigravity(
                    isEnabled: true,
                    state:
                        AntigravityPresentationFixture
                            .state(
                                presentation:
                                    .disabled
                            )
                )

        XCTAssertEqual(
            presentation.stage,
            .probingRuntime
        )
        XCTAssertEqual(
            presentation.badgeTitle,
            "준비 중"
        )
        XCTAssertNil(presentation.availableAction)
    }
}

private enum AntigravityPresentationFixture {
    static let now = Date(
        timeIntervalSince1970: 1_900_000_000
    )

    static let provenance =
        AntigravityQuotaProvenance(
            transport: .googleOAuth,
            endpointOwner: .external,
            accountIdentity:
                ProviderAccountIdentity(
                    stableAccountID: "subject-1",
                    email: "nathan@example.com"
                ),
            capability: .groupedQuotaSummary,
            processIdentity: nil
        )

    static let quotaSnapshot =
        AntigravityQuotaSnapshot(
            identity:
                ProviderAccountIdentity(
                    stableAccountID: "subject-1",
                    email: "nathan@example.com"
                ),
            plan: "Pro",
            lanes: [
                AntigravityQuotaLane(
                    id: .geminiWeekly,
                    upstreamGroupID: "gemini",
                    upstreamBucketID: "weekly",
                    scope: .gemini,
                    cadence: .weekly,
                    remainingFraction: 0.4,
                    resetAt:
                        now.addingTimeInterval(
                            86_400
                        ),
                    resetDescription: nil,
                    availability: .available
                )
            ],
            decodeIssues: [],
            provenance: provenance,
            fetchedAt: now
        )

    static let quotaPresentation =
        AntigravityQuotaPresentationMapper.map(
            snapshot: quotaSnapshot,
            settings: .default,
            now: now,
            locale:
                Locale(identifier: "ko_KR"),
            timeZone:
                TimeZone(secondsFromGMT: 0)!
        )

    static func state(
        activity:
            AntigravitySettingsViewState
                .Activity = .idle,
        presentation: AntigravityPresentationState,
        quotaPresentation:
            AntigravityQuotaPresentationMappingResult?
                = nil
    ) -> AntigravitySettingsViewState {
        AntigravitySettingsViewState(
            activity: activity,
            accounts: [],
            activeAccountID: nil,
            connection: .default,
            display: .default,
            migrationStatus: nil,
            presentation: presentation,
            quotaPresentation:
                quotaPresentation
                    ?? AntigravityQuotaPresentationMapper
                        .map(
                            state: presentation,
                            settings: .default,
                            now: now,
                            locale:
                                Locale(
                                    identifier: "ko_KR"
                                ),
                            timeZone:
                                TimeZone(
                                    secondsFromGMT: 0
                                )!
                        ),
            managedRuntimeAvailability:
                .unavailable,
            repositoryRevision: 1,
            notice: nil
        )
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
        let antigravityStatus =
            RuntimeProviderSettingsPresentation
                .makeAntigravity(
                    isEnabled: true,
                    state:
                        AntigravityPresentationFixture
                            .state(
                                presentation:
                                    .ready(
                                        AntigravityPresentationFixture
                                            .quotaSnapshot
                                    ),
                                quotaPresentation:
                                    .content(
                                        AntigravityPresentationFixture
                                            .quotaPresentation
                                    )
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
            antigravityStatus.nextStepTitle,
            antigravityStatus.nextStepDetail,
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
