import XCTest
@testable import ClaudeUsage

@MainActor
final class NotificationManagerTests: XCTestCase {
    private var settingsSnapshot: AppSettings.Snapshot!
    private var deliverer: MockNotificationDeliverer!
    private var manager: NotificationManager!

    override func setUp() {
        super.setUp()
        settingsSnapshot = AppSettings.shared.createSnapshot()
        deliverer = MockNotificationDeliverer()
        manager = NotificationManager(deliverer: deliverer)
        configureNotifications()
    }

    override func tearDown() {
        AppSettings.shared.restore(from: settingsSnapshot)
        manager = nil
        deliverer = nil
        settingsSnapshot = nil
        super.tearDown()
    }

    func testResetAtChangeDoesNotSendLegacyResetNotification() {
        manager.checkThreshold(
            session: .fiveHour,
            percentage: 10,
            resetAt: "2026-04-25T10:00:00Z"
        )
        manager.checkThreshold(
            session: .fiveHour,
            percentage: 10,
            resetAt: "2026-04-25T15:30:00Z"
        )

        XCTAssertTrue(deliverer.delivered.isEmpty)
        XCTAssertFalse(deliverer.delivered.contains { $0.title.contains("세션 리셋") })
    }

    func testThresholdNotificationUsesUsageTransition() {
        manager.checkThreshold(session: .fiveHour, percentage: 84, resetAt: nil)
        manager.checkThreshold(session: .fiveHour, percentage: 90, resetAt: nil)

        XCTAssertEqual(deliverer.delivered.map(\.title), ["Claude 사용량 주의"])
        XCTAssertEqual(deliverer.delivered.map(\.body), ["현재 세션의 90%를 사용했습니다"])
    }

    func testFirstCheckDoesNotSendThresholdNotificationEvenWhenAlreadyHigh() {
        manager.checkThreshold(session: .fiveHour, percentage: 91, resetAt: nil)

        XCTAssertTrue(deliverer.delivered.isEmpty)
    }

    func testClaudeLowUrgencySuppressionStillApplies() {
        AppSettings.shared.notificationPresets = [
            NotificationPreset(id: "seventy-five", threshold: 75),
            NotificationPreset(id: "ninety", threshold: 90),
        ]
        let policy = ClaudeNotificationPolicy(
            metadata: ClaudeProfileMetadata(
                subscriptionType: "team",
                hasExtraUsageEnabled: true,
                billingType: "organization",
                lastUpdatedAt: Date()
            )
        )

        manager.checkThreshold(session: .fiveHour, percentage: 70, resetAt: nil, claudePolicy: policy)
        manager.checkThreshold(session: .fiveHour, percentage: 75, resetAt: nil, claudePolicy: policy)
        manager.checkThreshold(session: .fiveHour, percentage: 90, resetAt: nil, claudePolicy: policy)

        XCTAssertEqual(deliverer.delivered.map(\.title), ["Claude 사용량 주의"])
        XCTAssertEqual(deliverer.delivered.map(\.body), ["현재 세션의 90%를 사용했습니다"])
    }

    func testCodexThresholdBehaviorIsPreserved() {
        manager.checkThreshold(
            session: .codexPrimary,
            percentage: 89,
            resetAt: nil
        )
        manager.checkThreshold(
            session: .codexPrimary,
            percentage: 96,
            resetAt: nil
        )

        XCTAssertEqual(
            deliverer.delivered.map(\.title),
            ["Codex 사용량 경고"]
        )
        XCTAssertEqual(
            deliverer.delivered.map(\.body),
            ["현재 세션의 95%를 사용했습니다"]
        )
    }

    func testAntigravityAggregatesAllCrossingsIntoOneNotification() {
        manager.checkAntigravityThresholds(
            snapshot: makeAntigravitySnapshot(
                accountID: "account-a",
                lanes: [
                    makeAntigravityLane(
                        id: .geminiFiveHour,
                        scope: .gemini,
                        cadence: .fiveHour,
                        usedPercentage: 89
                    ),
                    makeAntigravityLane(
                        id: .thirdPartyWeekly,
                        scope: .thirdPartyModels,
                        cadence: .weekly,
                        usedPercentage: 89
                    ),
                ]
            )
        )
        manager.checkAntigravityThresholds(
            snapshot: makeAntigravitySnapshot(
                accountID: "account-a",
                lanes: [
                    makeAntigravityLane(
                        id: .geminiFiveHour,
                        scope: .gemini,
                        cadence: .fiveHour,
                        usedPercentage: 91
                    ),
                    makeAntigravityLane(
                        id: .thirdPartyWeekly,
                        scope: .thirdPartyModels,
                        cadence: .weekly,
                        usedPercentage: 96
                    ),
                ]
            )
        )

        XCTAssertEqual(deliverer.delivered.count, 1)
        XCTAssertEqual(
            deliverer.delivered.first?.title,
            "Antigravity 사용량 경고"
        )
        XCTAssertEqual(
            deliverer.delivered.first?.body,
            [
                "Gemini · 5시간: 90% 사용",
                "Claude·GPT · 주간: 95% 사용",
            ].joined(separator: "\n")
        )
    }

    func testAntigravityTracksDynamicLanesByStableLaneID() {
        let dynamicLaneID = AntigravityQuotaLaneID(
            rawValue: "workspace.experimental"
        )
        manager.checkAntigravityThresholds(
            snapshot: makeAntigravitySnapshot(
                accountID: "account-a",
                lanes: [
                    makeAntigravityLane(
                        id: dynamicLaneID,
                        scope: .unknown(
                            id: "experimental",
                            label: "실험 모델"
                        ),
                        cadence: .unknown(rawValue: "일간"),
                        usedPercentage: 89
                    ),
                    makeAntigravityLane(
                        id: .geminiWeekly,
                        scope: .gemini,
                        cadence: .weekly,
                        usedPercentage: 20
                    ),
                ]
            )
        )
        manager.checkAntigravityThresholds(
            snapshot: makeAntigravitySnapshot(
                accountID: "account-a",
                lanes: [
                    makeAntigravityLane(
                        id: .geminiWeekly,
                        scope: .gemini,
                        cadence: .weekly,
                        usedPercentage: 91
                    ),
                    makeAntigravityLane(
                        id: dynamicLaneID,
                        scope: .unknown(
                            id: "experimental",
                            label: "실험 모델"
                        ),
                        cadence: .unknown(rawValue: "일간"),
                        usedPercentage: 89
                    ),
                ]
            )
        )

        XCTAssertEqual(deliverer.delivered.count, 1)
        XCTAssertEqual(
            deliverer.delivered.first?.body,
            "Gemini · 주간: 90% 사용"
        )
        XCTAssertFalse(
            deliverer.delivered.first?.body.contains(
                dynamicLaneID.rawValue
            ) == true
        )
    }

    func testAntigravityAccountBoundaryResetsEveryLaneTracker() {
        manager.checkAntigravityThresholds(
            snapshot: makeAntigravitySnapshot(
                accountID: "account-a",
                lanes: [
                    makeAntigravityLane(
                        id: .geminiFiveHour,
                        scope: .gemini,
                        cadence: .fiveHour,
                        usedPercentage: 89
                    )
                ]
            )
        )
        manager.checkAntigravityThresholds(
            snapshot: makeAntigravitySnapshot(
                accountID: "account-a",
                lanes: [
                    makeAntigravityLane(
                        id: .geminiFiveHour,
                        scope: .gemini,
                        cadence: .fiveHour,
                        usedPercentage: 96
                    )
                ]
            )
        )

        manager.checkAntigravityThresholds(
            snapshot: makeAntigravitySnapshot(
                accountID: "account-b",
                lanes: [
                    makeAntigravityLane(
                        id: .geminiFiveHour,
                        scope: .gemini,
                        cadence: .fiveHour,
                        usedPercentage: 96
                    )
                ]
            )
        )

        XCTAssertEqual(deliverer.delivered.count, 1)

        manager.checkAntigravityThresholds(
            snapshot: makeAntigravitySnapshot(
                accountID: "account-b",
                lanes: [
                    makeAntigravityLane(
                        id: .geminiFiveHour,
                        scope: .gemini,
                        cadence: .fiveHour,
                        usedPercentage: 80
                    )
                ]
            )
        )
        manager.checkAntigravityThresholds(
            snapshot: makeAntigravitySnapshot(
                accountID: "account-b",
                lanes: [
                    makeAntigravityLane(
                        id: .geminiFiveHour,
                        scope: .gemini,
                        cadence: .fiveHour,
                        usedPercentage: 96
                    )
                ]
            )
        )

        XCTAssertEqual(deliverer.delivered.count, 2)
    }

    func testAntigravityLocalSessionUsesObservedAccountBoundary() {
        let localAccountA = ProviderAccountIdentity(
            stableAccountID: "local-account-a",
            email: "local-a@example.com"
        )
        let localAccountB = ProviderAccountIdentity(
            stableAccountID: "local-account-b",
            email: "local-b@example.com"
        )

        manager.checkAntigravityThresholds(
            snapshot: makeAntigravitySnapshot(
                accountID: "stored-account",
                lanes: [
                    makeAntigravityLane(
                        id: .geminiFiveHour,
                        scope: .gemini,
                        cadence: .fiveHour,
                        usedPercentage: 89
                    )
                ],
                usesAmbientAccountBoundary: true,
                observedIdentity: localAccountA
            )
        )
        manager.checkAntigravityThresholds(
            snapshot: makeAntigravitySnapshot(
                accountID: "stored-account",
                lanes: [
                    makeAntigravityLane(
                        id: .geminiFiveHour,
                        scope: .gemini,
                        cadence: .fiveHour,
                        usedPercentage: 96
                    )
                ],
                usesAmbientAccountBoundary: true,
                observedIdentity: localAccountB
            )
        )

        XCTAssertTrue(deliverer.delivered.isEmpty)

        manager.checkAntigravityThresholds(
            snapshot: makeAntigravitySnapshot(
                accountID: "stored-account",
                lanes: [
                    makeAntigravityLane(
                        id: .geminiFiveHour,
                        scope: .gemini,
                        cadence: .fiveHour,
                        usedPercentage: 80
                    )
                ],
                usesAmbientAccountBoundary: true,
                observedIdentity: localAccountB
            )
        )
        manager.checkAntigravityThresholds(
            snapshot: makeAntigravitySnapshot(
                accountID: "stored-account",
                lanes: [
                    makeAntigravityLane(
                        id: .geminiFiveHour,
                        scope: .gemini,
                        cadence: .fiveHour,
                        usedPercentage: 96
                    )
                ],
                usesAmbientAccountBoundary: true,
                observedIdentity: localAccountB
            )
        )

        XCTAssertEqual(deliverer.delivered.count, 1)
    }

    func testAntigravityUnavailableLaneDoesNotRetainTracker() {
        manager.checkAntigravityThresholds(
            snapshot: makeAntigravitySnapshot(
                accountID: "account-a",
                lanes: [
                    makeAntigravityLane(
                        id: .geminiFiveHour,
                        scope: .gemini,
                        cadence: .fiveHour,
                        usedPercentage: 89
                    )
                ]
            )
        )
        manager.checkAntigravityThresholds(
            snapshot: makeAntigravitySnapshot(
                accountID: "account-a",
                lanes: [
                    makeAntigravityLane(
                        id: .geminiFiveHour,
                        scope: .gemini,
                        cadence: .fiveHour,
                        usedPercentage: nil,
                        availability: .disabled
                    )
                ]
            )
        )
        manager.checkAntigravityThresholds(
            snapshot: makeAntigravitySnapshot(
                accountID: "account-a",
                lanes: [
                    makeAntigravityLane(
                        id: .geminiFiveHour,
                        scope: .gemini,
                        cadence: .fiveHour,
                        usedPercentage: 96
                    )
                ]
            )
        )

        XCTAssertTrue(deliverer.delivered.isEmpty)
    }

    func testAntigravityRemainingModeAggregatesDisplayedThresholds() {
        AppSettings.shared.alertRemainingMode = true
        AppSettings.shared.notificationPresets = [
            NotificationPreset(
                id: "ten-remaining",
                threshold: 10
            ),
            NotificationPreset(
                id: "five-remaining",
                threshold: 5
            ),
        ]

        manager.checkAntigravityThresholds(
            snapshot: makeAntigravitySnapshot(
                accountID: "account-a",
                lanes: [
                    makeAntigravityLane(
                        id: .geminiFiveHour,
                        scope: .gemini,
                        cadence: .fiveHour,
                        usedPercentage: 89
                    ),
                    makeAntigravityLane(
                        id: .thirdPartyWeekly,
                        scope: .thirdPartyModels,
                        cadence: .weekly,
                        usedPercentage: 89
                    ),
                ]
            )
        )
        manager.checkAntigravityThresholds(
            snapshot: makeAntigravitySnapshot(
                accountID: "account-a",
                lanes: [
                    makeAntigravityLane(
                        id: .geminiFiveHour,
                        scope: .gemini,
                        cadence: .fiveHour,
                        usedPercentage: 91
                    ),
                    makeAntigravityLane(
                        id: .thirdPartyWeekly,
                        scope: .thirdPartyModels,
                        cadence: .weekly,
                        usedPercentage: 96
                    ),
                ]
            )
        )

        XCTAssertEqual(deliverer.delivered.count, 1)
        XCTAssertEqual(
            deliverer.delivered.first?.title,
            "Antigravity 잔여 한도 경고"
        )
        XCTAssertEqual(
            deliverer.delivered.first?.body,
            [
                "Gemini · 5시간: 10% 남음",
                "Claude·GPT · 주간: 5% 남음",
            ].joined(separator: "\n")
        )
    }

    func testAntigravityLegacyOrdinalSessionsNoLongerDeliver() {
        manager.checkThreshold(
            session: .antigravityPrimary,
            percentage: 89,
            resetAt: nil
        )
        manager.checkThreshold(
            session: .antigravityPrimary,
            percentage: 96,
            resetAt: nil
        )

        XCTAssertTrue(deliverer.delivered.isEmpty)
    }

    private func makeAntigravitySnapshot(
        accountID rawAccountID: String,
        lanes: [AntigravityQuotaLane],
        notificationsEnabled: Bool = true,
        usesAmbientAccountBoundary: Bool = false,
        observedIdentity: ProviderAccountIdentity? = nil
    ) -> AntigravityRuntimeSnapshot {
        let accountID = AntigravityAccountID(
            rawValue: rawAccountID
        )
        let repositoryIdentity = ProviderAccountIdentity(
            stableAccountID: rawAccountID,
            email: "\(rawAccountID)@example.com"
        )
        let quotaIdentity =
            observedIdentity ?? repositoryIdentity
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let quotaSnapshot = AntigravityQuotaSnapshot(
            identity: quotaIdentity,
            plan: "test",
            lanes: lanes,
            decodeIssues: [],
            provenance: AntigravityQuotaProvenance(
                transport: .localAppRPC,
                endpointOwner: .external,
                accountIdentity: quotaIdentity,
                capability: .groupedQuotaSummary,
                processIdentity: nil
            ),
            fetchedAt: fetchedAt
        )
        var displaySettings = AntigravityDisplaySettings.default
        displaySettings.notifications.isEnabled = notificationsEnabled
        let presentation = AntigravityQuotaPresentationMapper.map(
            snapshot: quotaSnapshot,
            settings: displaySettings,
            now: fetchedAt,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        return AntigravityRuntimeSnapshot(
            readiness: .ready,
            migrationStatus: nil,
            repositoryRevision: 1,
            accounts: [
                AntigravityRuntimeAccountSummary(
                    id: accountID,
                    label: rawAccountID,
                    identity: repositoryIdentity,
                    isActive: true
                )
            ],
            activeAccountID:
                usesAmbientAccountBoundary
                    ? nil
                    : accountID,
            settings: AntigravitySettingsSnapshot(
                connection: .default,
                display: displaySettings
            ),
            presentationState: .ready(quotaSnapshot),
            quotaPresentation: .content(presentation),
            managedRuntimeAvailability: .available(
                displayPath: "~/.local/bin/agy"
            ),
            lastAttemptAt: fetchedAt,
            lastSuccessfulAt: fetchedAt
        )
    }

    private func makeAntigravityLane(
        id: AntigravityQuotaLaneID,
        scope: AntigravityQuotaScope,
        cadence: AntigravityQuotaCadence,
        usedPercentage: Double?,
        availability: AntigravityQuotaAvailability = .available
    ) -> AntigravityQuotaLane {
        AntigravityQuotaLane(
            id: id,
            upstreamGroupID: "group.\(id.rawValue)",
            upstreamBucketID: "bucket.\(id.rawValue)",
            scope: scope,
            cadence: cadence,
            remainingFraction: usedPercentage.map {
                1 - ($0 / 100)
            },
            resetAt: nil,
            resetDescription: nil,
            availability: availability
        )
    }

    private func configureNotifications() {
        let settings = AppSettings.shared
        settings.notificationsEnabled = true
        settings.claudeAlertEnabled = true
        settings.alertFiveHourEnabled = true
        settings.alertWeeklyEnabled = true
        settings.codexAlertEnabled = true
        settings.alertRemainingMode = false
        settings.notificationPresets = [
            NotificationPreset(id: "ninety", threshold: 90),
            NotificationPreset(id: "ninety-five", threshold: 95),
        ]
    }
}

private final class MockNotificationDeliverer: NotificationDelivering {
    private(set) var delivered: [(title: String, body: String)] = []

    func requestPermission() {}

    func deliver(title: String, body: String) {
        delivered.append((title: title, body: body))
    }
}
