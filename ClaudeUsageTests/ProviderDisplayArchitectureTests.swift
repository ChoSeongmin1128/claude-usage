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
            temporary?.message.contains("40분")
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
                    migrationStatus: nil,
                    repositoryRevision: 1,
                    accounts: [],
                    activeAccountID: nil,
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
            migrationStatus: nil,
            repositoryRevision: nil,
            accounts: [],
            activeAccountID: nil,
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
                    transport: .borrowedAGYRPC,
                    endpointOwner: .borrowed,
                    accountIdentity: nil,
                    capability:
                        .groupedQuotaSummary,
                    processIdentity: nil
                ),
            fetchedAt: now
        )
    }
}
