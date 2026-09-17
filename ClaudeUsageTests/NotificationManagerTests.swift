import XCTest
@testable import ClaudeUsage

@MainActor
final class NotificationManagerTests: XCTestCase {
    private var settingsSnapshot: AppSettings.Snapshot!
    private var deliverer: MockNotificationDeliverer!
    private var manager: NotificationManager!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        settingsSnapshot = AppSettings.shared.createSnapshot()
        deliverer = MockNotificationDeliverer()
        manager = NotificationManager(deliverer: deliverer)
        configureNotifications()
    }

    @MainActor
    override func tearDown() async throws {
        AppSettings.shared.restore(from: settingsSnapshot)
        manager = nil
        deliverer = nil
        settingsSnapshot = nil
        try await super.tearDown()
    }

    func testChangingDisplayBasisDoesNotMoveThresholdsOrResendAlerts() {
        checkClaude(percentage: 89, resetAt: nil)
        checkClaude(percentage: 91, resetAt: nil)
        XCTAssertEqual(deliverer.delivered.count, 1)
        AppSettings.shared.usageDisplayMode = .remaining
        checkClaude(percentage: 91, resetAt: nil)
        XCTAssertEqual(deliverer.delivered.count, 1)
        checkClaude(percentage: 96, resetAt: nil)
        XCTAssertEqual(deliverer.delivered.count, 2)
        XCTAssertTrue(deliverer.delivered.last?.body.contains("5%") == true)
        AppSettings.shared.usageDisplayMode = .used
        checkClaude(percentage: 96, resetAt: nil)
        XCTAssertEqual(deliverer.delivered.count, 2)
    }

    func testResetAtChangeDoesNotSendLegacyResetNotification() {
        checkClaude(
            percentage: 10,
            resetAt: "2026-04-25T10:00:00Z"
        )
        checkClaude(
            percentage: 10,
            resetAt: "2026-04-25T15:30:00Z"
        )

        XCTAssertTrue(deliverer.delivered.isEmpty)
        XCTAssertFalse(deliverer.delivered.contains { $0.title.contains("세션 리셋") })
    }

    func testThresholdNotificationUsesUsageTransition() {
        checkClaude(percentage: 84, resetAt: nil)
        checkClaude(percentage: 90, resetAt: nil)

        XCTAssertEqual(deliverer.delivered.map(\.title), ["Claude 사용량 주의"])
        XCTAssertEqual(deliverer.delivered.map(\.body), ["5시간의 90%를 사용했습니다"])
    }

    func testFirstCheckDoesNotSendThresholdNotificationEvenWhenAlreadyHigh() {
        checkClaude(percentage: 91, resetAt: nil)

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

        checkClaude(percentage: 70, resetAt: nil, claudePolicy: policy)
        checkClaude(percentage: 75, resetAt: nil, claudePolicy: policy)
        checkClaude(percentage: 90, resetAt: nil, claudePolicy: policy)

        XCTAssertEqual(deliverer.delivered.map(\.title), ["Claude 사용량 주의"])
        XCTAssertEqual(deliverer.delivered.map(\.body), ["5시간의 90%를 사용했습니다"])
    }

    func testCodexThresholdBehaviorIsPreserved() {
        checkCodex(
            percentage: 89,
            resetAt: nil
        )
        checkCodex(
            percentage: 96,
            resetAt: nil
        )

        XCTAssertEqual(
            deliverer.delivered.map(\.title),
            ["Codex 사용량 경고"]
        )
        XCTAssertEqual(
            deliverer.delivered.map(\.body),
            ["5시간의 95%를 사용했습니다"]
        )
    }

    func testCodexAccountChangeDoesNotReusePreviousThresholdHistory() {
        setCodexAccount("account-a")
        checkCodex(percentage: 89, resetAt: nil)
        setCodexAccount("account-b")
        checkCodex(percentage: 96, resetAt: nil)
        XCTAssertTrue(deliverer.delivered.isEmpty)
        setCodexAccount("account-b")
        checkCodex(percentage: 89, resetAt: nil)
        checkCodex(percentage: 96, resetAt: nil)
        XCTAssertEqual(deliverer.delivered.count, 1)
        setCodexAccount(nil)
        setCodexAccount("account-b")
        checkCodex(percentage: 96, resetAt: nil)
        XCTAssertEqual(deliverer.delivered.count, 1)
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
                "Gemini · 5시간의 90%를 사용했습니다",
                "Claude·GPT · 주간의 95%를 사용했습니다",
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
            "Gemini · 주간의 90%를 사용했습니다"
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

    func testAntigravityUnavailableLanePreservesHistoryUntilNumericQuotaReturns() {
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

        XCTAssertEqual(deliverer.delivered.count, 1)
    }

    func testAntigravityRemainingModeAggregatesDisplayedThresholds() {
        AppSettings.shared.usageDisplayMode = .remaining
        AppSettings.shared.notificationPresets = [
            NotificationPreset(
                id: "ten-remaining",
                threshold: 90
            ),
            NotificationPreset(
                id: "five-remaining",
                threshold: 95
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
                "Gemini · 5시간의 10%가 남았습니다",
                "Claude·GPT · 주간의 5%가 남았습니다",
            ].joined(separator: "\n")
        )
    }

    func testModelTargetsAreOptInAndDoNotAlertImmediatelyWhenSelected() throws {
        func usage(_ used: Double) -> ClaudeUsageResponse {
            .init(
                fiveHour: .init(utilization: 20, resetsAt: nil), sevenDay: nil,
                scopedLimits: [.init(kind: "weekly_scoped", percent: used, modelID: "fable", modelName: "Fable")])
        }
        manager.checkClaude(usage(20), accountID: "a", policy: nil)
        manager.checkClaude(usage(96), accountID: "a", policy: nil)
        XCTAssertTrue(deliverer.delivered.isEmpty)
        let model = try XCTUnwrap(manager.inventories[.claude]?.first { $0.scope == "model:fable" })
        AppSettings.shared.notificationTargets.setSelected(true, limit: model)
        manager.checkClaude(usage(96), accountID: "a", policy: nil)
        XCTAssertTrue(deliverer.delivered.isEmpty)
        manager.checkClaude(usage(20), accountID: "a", policy: nil)
        manager.checkClaude(usage(96), accountID: "a", policy: nil)
        XCTAssertEqual(deliverer.delivered.count, 1)
        XCTAssertTrue(deliverer.delivered[0].body.contains("Fable · 주간"))
        manager.checkClaude(usage(96), accountID: "b", policy: nil)
        XCTAssertEqual(deliverer.delivered.count, 1)
    }

    func testCodexAdditionalWindowsHaveIndependentSelectionsAndHistories() throws {
        func usage(_ short: Int, _ weekly: Int) throws -> CodexUsageResponse {
            try JSONDecoder().decode(
                CodexUsageResponse.self,
                from: Data(
                    """
                    {"additional_rate_limits":[{"metered_feature":"future-model","limit_name":"Future","rate_limit":{
                    "primary_window":{"used_percent":\(short),"limit_window_seconds":18000},
                    "secondary_window":{"used_percent":\(weekly),"limit_window_seconds":604800}}}]}
                    """.utf8))
        }
        manager.checkCodex(try usage(20, 20), accountID: "a")
        let limits = try XCTUnwrap(manager.inventories[.codex])
        XCTAssertEqual(limits.count, 2)
        XCTAssertTrue(limits.allSatisfy { !AppSettings.shared.notificationTargets.isSelected($0.id, provider: .codex) })
        for limit in limits { AppSettings.shared.notificationTargets.setSelected(true, limit: limit) }
        manager.checkCodex(try usage(20, 20), accountID: "a")
        manager.checkCodex(try usage(91, 96), accountID: "a")
        XCTAssertEqual(deliverer.delivered.count, 1)
        XCTAssertTrue(deliverer.delivered[0].body.contains("Future · 5시간"))
        XCTAssertTrue(deliverer.delivered[0].body.contains("Future · 주간"))
    }

    func testAntigravityPopoverVisibilityDoesNotChangeImportedNotificationSelection() throws {
        let id = AntigravityQuotaLaneID.geminiWeekly
        func snapshot(_ used: Double, hidden: Set<AntigravityQuotaLaneID>) -> AntigravityRuntimeSnapshot {
            makeAntigravitySnapshot(
                accountID: "a",
                lanes: [
                    makeAntigravityLane(id: id, scope: .gemini, cadence: .weekly, usedPercentage: used)
                ], hiddenLaneIDs: hidden)
        }
        manager.checkAntigravityThresholds(snapshot: snapshot(20, hidden: []))
        manager.checkAntigravityThresholds(snapshot: snapshot(96, hidden: [id]))
        XCTAssertEqual(deliverer.delivered.count, 1)
        XCTAssertEqual(manager.inventories[.antigravity]?.count, 1)
    }

    func testAntigravityInitiallyHiddenTargetRequiresExplicitSelection() {
        let id = AntigravityQuotaLaneID.geminiWeekly
        for (used, hidden) in [(20.0, Set([id])), (96.0, Set<AntigravityQuotaLaneID>())] {
            manager.checkAntigravityThresholds(
                snapshot: makeAntigravitySnapshot(
                    accountID: "a",
                    lanes: [
                        makeAntigravityLane(id: id, scope: .gemini, cadence: .weekly, usedPercentage: used)
                    ], hiddenLaneIDs: hidden))
        }
        XCTAssertEqual(manager.inventories[.antigravity]?.count, 1)
        XCTAssertTrue(deliverer.delivered.isEmpty)
    }

    func testMissingAccountCannotImportTargetsOrEmitNotifications() {
        let usage = ClaudeUsageResponse(fiveHour: .init(utilization: 96, resetsAt: nil), sevenDay: nil)
        manager.checkClaude(usage, accountID: nil, policy: nil)
        XCTAssertTrue(AppSettings.shared.notificationTargets.providers.isEmpty)
        XCTAssertTrue(manager.inventories[.claude]?.isEmpty ?? true)
        XCTAssertTrue(deliverer.delivered.isEmpty)
    }

    private var codexAccount: String? = "account-a"

    private func setCodexAccount(_ id: String?) {
        codexAccount = id
        manager.updateAccountBoundary(.codex, accountID: id)
    }

    private func checkClaude(percentage: Double, resetAt: String?, claudePolicy: ClaudeNotificationPolicy? = nil) {
        manager.checkClaude(
            ClaudeUsageResponse(fiveHour: .init(utilization: percentage, resetsAt: resetAt), sevenDay: nil),
            accountID: "account-a", policy: claudePolicy)
    }

    private func checkCodex(percentage: Double, resetAt: String?) {
        let data = Data(
            "{\"rate_limit\":{\"primary_window\":{\"used_percent\":\(percentage),\"limit_window_seconds\":18000}}}".utf8
        )
        let usage = try! JSONDecoder().decode(CodexUsageResponse.self, from: data)
        manager.checkCodex(usage, accountID: codexAccount)
    }

    private func makeAntigravitySnapshot(
        accountID rawAccountID: String,
        lanes: [AntigravityQuotaLane],
        notificationsEnabled: Bool = true,
        usesAmbientAccountBoundary: Bool = false,
        observedIdentity: ProviderAccountIdentity? = nil,
        hiddenLaneIDs: Set<AntigravityQuotaLaneID> = []
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
        displaySettings.standard.hiddenLaneIDs = hiddenLaneIDs
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
        settings.notificationTargets = .init()
        settings.notificationsEnabled = true
        settings.claudeAlertEnabled = true
        settings.alertFiveHourEnabled = true
        settings.alertWeeklyEnabled = true
        settings.codexAlertEnabled = true
        settings.usageDisplayMode = .used
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
