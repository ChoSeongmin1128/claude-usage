import XCTest
@testable import ClaudeUsage

@MainActor
final class ProviderDisplayArchitectureTests:
    XCTestCase
{
    func testProviderExternalActionsUseVerifiedDestinations() {
        XCTAssertEqual(
            AppProviderKind.claude.descriptor.externalActions
                .map(\.destination.absoluteString),
            [
                "https://claude.ai/settings/usage",
                "https://status.claude.com/",
            ]
        )
        XCTAssertEqual(
            AppProviderKind.codex.descriptor.externalActions
                .map(\.destination.absoluteString),
            [
                "https://chatgpt.com/codex/settings/usage",
                "https://status.openai.com/",
            ]
        )
        XCTAssertTrue(
            AppProviderKind.antigravity.descriptor.externalActions
                .isEmpty
        )
    }

    func testCatalogPreferencesPersistVisibilityAndOrderForClaudeAndCodex() throws {
        let suite =
            "ProviderDisplayArchitectureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suite)
        )
        defer {
            defaults.removePersistentDomain(
                forName: suite
            )
        }

        var first: AppSettings? =
            AppSettings(defaults: defaults)
        first?.setPopoverItems(
            [
                .init(
                    id: "weeklyLimit",
                    visible: false
                ),
                .init(
                    id: "currentSession",
                    visible: true
                ),
            ],
            for: .claude
        )
        first?.setCompactPopoverItems(
            [
                .init(
                    id: "codexCredits",
                    visible: true
                ),
                .init(
                    id: "codexPrimary",
                    visible: false
                ),
            ],
            for: .codex
        )
        first = nil

        let reloaded = AppSettings(
            defaults: defaults
        )
        XCTAssertEqual(
            reloaded.popoverItems(for: .claude)
                .prefix(2)
                .map(\.id),
            ["weeklyLimit", "currentSession"]
        )
        XCTAssertFalse(
            reloaded.popoverItems(for: .claude)[0]
                .visible
        )
        XCTAssertEqual(
            reloaded
                .compactPopoverItems(for: .codex)
                .prefix(2)
                .map(\.id),
            ["codexCredits", "codexPrimary"]
        )
        XCTAssertTrue(
            reloaded
                .compactPopoverItems(for: .codex)[0]
                .visible
        )
    }

    func testCatalogAdapterProducesProviderAgnosticEditorModel() throws {
        let suite =
            "CatalogDisplayAdapterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suite)
        )
        defer {
            defaults.removePersistentDomain(
                forName: suite
            )
        }
        let settings = AppSettings(
            defaults: defaults
        )

        let model = try XCTUnwrap(
            CatalogDisplayAdapter.editorModel(
                service: .claude,
                surface: .standard,
                settings: settings,
                unavailableItemIDs:
                    ["weeklyLimit"]
            )
        )

        XCTAssertEqual(model.surface, .standard)
        XCTAssertTrue(model.supportsReordering)
        XCTAssertFalse(model.showsGroupHeadings)
        XCTAssertEqual(
            model.items.first {
                $0.id == "weeklyLimit"
            }?.isAvailable,
            false
        )
        XCTAssertNil(
            CatalogDisplayAdapter.editorModel(
                service: .antigravity,
                surface: .standard,
                settings: settings
            )
        )
    }

    func testCodexPersonalProjectionKeepsCreditsAndStoredPreferencesOnBothSurfaces() throws {
        try withCodexSettings { settings, defaults in
            let catalog = CodexItemCatalog()
            let usage = try codexFixture(plan: "pro")
            let full = [
                PopoverItemConfig(id: "codexSpendLimit", visible: false),
                PopoverItemConfig(id: "codexCredits", visible: false),
                PopoverItemConfig(id: "codexSecondary", visible: true),
                PopoverItemConfig(id: "codexPrimary", visible: false),
                PopoverItemConfig(id: "codexModelLimits", visible: true),
                PopoverItemConfig(id: "codexResetCredits", visible: true),
            ]
            let compact = Array(full.reversed())
            settings.setPopoverItems(full, for: .codex)
            settings.separateCompactConfig = true
            settings.setCompactPopoverItems(compact, for: .codex)
            let fullData = defaults.data(forKey: "popoverItemsV2")
            let compactData = defaults.data(forKey: "compactPopoverItemsV2")

            for surface in ProviderDisplaySurface.allCases {
                let stored = surface == .compact ? compact : full
                let projected = catalog.settingsItems(from: stored, usage: usage)
                let editor = try XCTUnwrap(
                    CatalogDisplayAdapter.editorModel(
                        service: .codex, surface: surface, settings: settings, codexUsage: usage))
                XCTAssertEqual(
                    projected.map(\.id),
                    stored.filter {
                        ["codexSecondary", "codexCredits"].contains($0.id)
                    }.map(\.id))
                XCTAssertEqual(editor.items.map(\.id), projected.map(\.id))
                XCTAssertEqual(editor.items.first { $0.id == "codexCredits" }?.isVisible, false)
                XCTAssertFalse(editor.items.contains { $0.id == "codexSpendLimit" })
            }
            XCTAssertEqual(catalog.displayName(for: "codexSpendLimit"), "월 사용 한도")
            XCTAssertEqual(catalog.displayName(for: "codexCredits"), "크레딧 잔액")
            XCTAssertTrue(catalog.supportedIDs.contains("codexSpendLimit"))
            XCTAssertTrue(catalog.defaultItems.contains { $0.id == "codexSpendLimit" })
            XCTAssertEqual(defaults.data(forKey: "popoverItemsV2"), fullData)
            XCTAssertEqual(defaults.data(forKey: "compactPopoverItemsV2"), compactData)
            let reloaded = AppSettings(defaults: defaults, hasExistingAccountStorage: false)
            XCTAssertEqual(reloaded.popoverItems(for: .codex), full)
            XCTAssertEqual(reloaded.compactPopoverItems(for: .codex), compact)
        }
    }

    func testCodexMonthlyProjectionRequiresWorkspaceQuotaAndRejectsPersonalConflicts() throws {
        try withCodexSettings { settings, _ in
            let catalog = CodexItemCatalog()
            let spend = #"{"individual_limit":{"limit":"1000","used":"750","used_percent":75}}"#
            for plan in ["business", "unrecognized-workspace"] {
                let usage = try codexFixture(plan: plan, spendControl: spend)
                XCTAssertTrue(
                    catalog.settingsItems(from: catalog.defaultItems, usage: usage)
                        .contains { $0.id == "codexSpendLimit" })
                let rows = LimitSettingsTable.rows(
                    service: .codex, popoverItems: catalog.settingsItems(from: catalog.defaultItems, usage: usage),
                    limits: UsageLimitCatalog.codex(usage), displayName: catalog.displayName(for:), codexUsage: usage)
                XCTAssertTrue(rows.contains { $0.id == "codexSpendLimit" && $0.title == "월 사용 한도" })
            }
            let conflictingPersonal = try codexFixture(plan: "pro", spendControl: spend)
            XCTAssertFalse(
                catalog.settingsItems(from: catalog.defaultItems, usage: conflictingPersonal)
                    .contains { $0.id == "codexSpendLimit" })
            let context = UsageItemContext(
                density: .standard, settings: settings, claudeUsage: nil, claudeOverage: nil,
                claudeAccounts: [], activeClaudeAccountID: nil,
                codexUsage: conflictingPersonal, codexError: nil)
            XCTAssertNil(catalog.section(for: "codexSpendLimit", context: context))
            let unreadableMonthly = try codexFixture(
                plan: "business", spendControl: #"{"individual_limit":{"used_percent":"unknown"}}"#)
            XCTAssertFalse(
                catalog.settingsItems(from: catalog.defaultItems, usage: unreadableMonthly)
                    .contains { $0.id == "codexSpendLimit" })
            var zeroCredits = try codexFixture(plan: "pro", creditsBalance: "0", hasCredits: false)
            zeroCredits.resetCredits = .init(credits: [], availableCountField: 0)
            let zeroItems = catalog.settingsItems(from: catalog.defaultItems, usage: zeroCredits)
            XCTAssertTrue(zeroItems.contains { $0.id == "codexCredits" })
            XCTAssertTrue(zeroItems.contains { $0.id == "codexResetCredits" })
            let zeroContext = UsageItemContext(
                density: .standard, settings: settings, claudeUsage: nil, claudeOverage: nil,
                claudeAccounts: [], activeClaudeAccountID: nil, codexUsage: zeroCredits, codexError: nil)
            XCTAssertNil(catalog.section(for: "codexResetCredits", context: zeroContext))
        }
    }

    func testCodexSupportKeepsLastGoodDuringErrorsAndReturnsToUnknownWhenPayloadClears() throws {
        let catalog = CodexItemCatalog()
        var state = RuntimeProviderState(isLoading: true)
        let unknown = catalog.defaultItems.filter { $0.id != "codexSpendLimit" }.map(\.id)
        XCTAssertEqual(catalog.settingsItems(from: catalog.defaultItems, usage: state.codexUsage).map(\.id), unknown)
        state.recordAttempt(error: .networkError("fixture unavailable"))
        XCTAssertEqual(catalog.settingsItems(from: catalog.defaultItems, usage: state.codexUsage).map(\.id), unknown)

        let business = try codexFixture(
            plan: "business", spendControl: #"{"individual_limit":{"used_percent":40}}"#)
        state = RuntimeProviderState(payload: .codex(business))
        let supported = catalog.settingsItems(from: catalog.defaultItems, usage: state.codexUsage).map(\.id)
        XCTAssertTrue(supported.contains("codexSpendLimit"))
        XCTAssertFalse(supported.contains("codexPrimary"))
        state.recordAttempt(error: .networkError("temporary refresh failure"))
        XCTAssertNotNil(state.error)
        XCTAssertEqual(catalog.settingsItems(from: catalog.defaultItems, usage: state.codexUsage).map(\.id), supported)

        state = RuntimeProviderState(isLoading: true)
        XCTAssertEqual(catalog.settingsItems(from: catalog.defaultItems, usage: state.codexUsage).map(\.id), unknown)
        state.payload = .codex(try codexFixture(plan: "pro"))
        XCTAssertEqual(
            catalog.settingsItems(from: catalog.defaultItems, usage: state.codexUsage).map(\.id),
            ["codexSecondary", "codexCredits"])
    }

    func testCodexProjectedReorderingPreservesUnsupportedSlotsAndVisibilityAcrossRelaunch() throws {
        try withCodexSettings { settings, defaults in
            let usage = try codexFixture(plan: "pro")
            let catalog = CodexItemCatalog()
            let items = [
                PopoverItemConfig(id: "codexSecondary", visible: false),
                PopoverItemConfig(id: "codexSpendLimit", visible: false),
                PopoverItemConfig(id: "codexCredits", visible: true),
                PopoverItemConfig(id: "codexPrimary", visible: false),
                PopoverItemConfig(id: "codexModelLimits", visible: true),
                PopoverItemConfig(id: "codexResetCredits", visible: false),
            ]
            settings.setPopoverItems(items, for: .codex)
            settings.separateCompactConfig = true
            let compact = Array(items.reversed())
            settings.setCompactPopoverItems(compact, for: .codex)
            let projectedIDs = catalog.settingsItems(from: items, usage: usage).map(\.id)
            let moved = CatalogDisplayAdapter.moveItems(
                items, sourceID: "codexSecondary", offset: 1, projectedIDs: projectedIDs)
            XCTAssertEqual(
                moved.map(\.id),
                [
                    "codexCredits", "codexSpendLimit", "codexSecondary",
                    "codexPrimary", "codexModelLimits", "codexResetCredits",
                ])
            let dragged = CatalogDisplayAdapter.moveItems(
                items, sourceID: "codexSecondary", targetID: "codexCredits", projectedIDs: projectedIDs)
            XCTAssertEqual(dragged, moved)
            for index in [1, 3, 4, 5] { XCTAssertEqual(moved[index], items[index]) }
            for item in items { XCTAssertEqual(moved.first { $0.id == item.id }?.visible, item.visible) }
            settings.setPopoverItems(moved, for: .codex)
            let reloaded = AppSettings(defaults: defaults, hasExistingAccountStorage: false)
            XCTAssertEqual(reloaded.popoverItems(for: .codex), moved)
            XCTAssertEqual(reloaded.compactPopoverItems(for: .codex), compact)
            let reverse = CatalogDisplayAdapter.moveItems(
                moved, sourceID: "codexSecondary", offset: -1, projectedIDs: ["codexCredits", "codexSecondary"])
            XCTAssertEqual(reverse, items)
        }
    }

    private func withCodexSettings(_ body: (AppSettings, UserDefaults) throws -> Void) throws {
        let suite = "ProviderDisplayArchitectureTests.codex.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(AppSettings(defaults: defaults, hasExistingAccountStorage: false), defaults)
    }

    private func codexFixture(
        plan: String, spendControl: String = "{}", creditsBalance: String = "125.50", hasCredits: Bool = true
    ) throws -> CodexUsageResponse {
        try JSONDecoder().decode(
            CodexUsageResponse.self,
            from: Data(
                """
                {"account_id":"codex-fixture","plan_type":"\(plan)",
                 "rate_limit":{"primary_window":{"used_percent":12,"limit_window_seconds":604800},
                               "secondary_window":null},
                 "spend_control":\(spendControl),
                 "credits":{"has_credits":\(hasCredits),"unlimited":false,"balance":"\(creditsBalance)"}}
                """.utf8))
    }

    func testCatalogStatusAdapterKeepsProviderSpecificRecoveryActions() {
        let codex = CatalogPopoverPresentationAdapter
            .statusSummary(
                phase: .error,
                error: .codexReauthRequired(
                    reason: "invalid_grant"
                ),
                service: .codex
            )
        XCTAssertEqual(
            codex?.action,
            .openSettings
        )
        XCTAssertTrue(
            codex?.actionIsProminent == true
        )

        let temporary =
            CatalogPopoverPresentationAdapter
                .statusSummary(
                    phase: .error,
                    error: .rateLimited(
                        retryAfter: 2_400
                    ),
                    service: .claude
                )
        XCTAssertEqual(temporary?.action, .retry)
        XCTAssertTrue(
            temporary?.message?.contains("40분")
                == true
        )
    }

    func testAntigravityStatusAdapterSeparatesSettingsAndRetryFailures() {
        let blocked =
            AntigravityPopoverPresentationAdapter
                .statusSummary(
                    for: makeRuntimeSnapshot(
                        readiness:
                            .blocked(
                                .typedSettings
                            ),
                        presentation:
                            .disabled
                    )
                )
        XCTAssertEqual(
            blocked.action,
            .openSettings
        )
        XCTAssertEqual(blocked.tone, .critical)

        let temporary =
            AntigravityPopoverPresentationAdapter
                .statusSummary(
                    for: makeRuntimeSnapshot(
                        readiness: .ready,
                        presentation:
                            .failed(
                                .deadlineExceeded(
                                    .googleOAuth
                                )
                            )
                    )
                )
        XCTAssertEqual(temporary.action, .retry)
        XCTAssertEqual(temporary.tone, .warning)
    }

    func testCompactRowCountSupportsOneThroughSixDynamicLanes() {
        let viewModel = PopoverViewModel()

        for count in 1...6 {
            let quota = makeQuotaSnapshot(
                laneCount: count
            )
            let presentation =
                AntigravityQuotaPresentationMapper
                    .map(
                        snapshot: quota,
                        settings: .default,
                        now: quota.fetchedAt,
                        timeZone:
                            TimeZone(
                                secondsFromGMT: 0
                            )!
                    )
            viewModel.antigravityRuntimeSnapshot =
                AntigravityRuntimeSnapshot(
                    readiness: .ready,
                    settings:
                        AntigravitySettingsSnapshot(
                            connection: .default,
                            display: .default
                        ),
                    presentationState:
                        .ready(quota),
                    quotaPresentation:
                        .content(presentation),
                    managedRuntimeAvailability:
                        .available(
                            displayPath: "agy"
                        ),
                    lastAttemptAt: nil,
                    lastSuccessfulAt: nil
                )

            XCTAssertEqual(
                viewModel.compactContentRowCount(
                    for: .antigravity,
                    catalogSections: []
                ),
                count
            )
        }
    }

    private func makeRuntimeSnapshot(
        readiness: AntigravityRuntimeReadiness,
        presentation:
            AntigravityPresentationState
    ) -> AntigravityRuntimeSnapshot {
        AntigravityRuntimeSnapshot(
            readiness: readiness,
            settings: AntigravitySettingsSnapshot(
                connection: .default,
                display: .default
            ),
            presentationState: presentation,
            quotaPresentation:
                .unavailable(presentation),
            managedRuntimeAvailability:
                .available(displayPath: "agy"),
            lastAttemptAt: nil,
            lastSuccessfulAt: nil
        )
    }

    private func makeQuotaSnapshot(
        laneCount: Int
    ) -> AntigravityQuotaSnapshot {
        let now = Date(
            timeIntervalSince1970: 1_800_000_000
        )
        return AntigravityQuotaSnapshot(
            identity: nil,
            plan: nil,
            lanes: (0..<laneCount).map { index in
                AntigravityQuotaLane(
                    id: AntigravityQuotaLaneID(
                        rawValue:
                            "dynamic.lane.\(index)"
                    ),
                    upstreamGroupID: "dynamic",
                    upstreamBucketID:
                        "lane-\(index)",
                    scope: .unknown(
                        id: "dynamic",
                        label: "Dynamic"
                    ),
                    cadence: .unknown(
                        rawValue: "lane-\(index)"
                    ),
                    remainingFraction:
                        Double(index + 1)
                            / Double(laneCount + 1),
                    resetAt: nil,
                    resetDescription: nil,
                    availability: .available
                )
            },
            decodeIssues: [],
            provenance:
                AntigravityQuotaProvenance(
                    transport: .cliUsageReport,
                    endpointOwner: .managed,
                    accountIdentity: nil,
                    capability:
                        .groupedQuotaSummary,
                    processIdentity: nil
                ),
            fetchedAt: now
        )
    }
}
