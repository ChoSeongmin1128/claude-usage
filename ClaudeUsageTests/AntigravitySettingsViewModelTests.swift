import Foundation
import XCTest
@testable import ClaudeUsage

@MainActor
final class AntigravitySettingsViewModelTests:
    XCTestCase
{
    func testLateSnapshotCannotOverwriteANewerPublication() async {
        var connection = AntigravityConnectionSettings.default
        connection.usageTarget = .cli
        var initial = Self.snapshot(connection: connection, revision: 10)
        let controller = AntigravitySettingsRuntimeControllerDouble(snapshot: initial)
        let viewModel = AntigravitySettingsViewModel(runtimeController: controller)
        await viewModel.load()
        connection.usageTarget = .app
        let newer = Self.snapshot(connection: connection, revision: 12)
        await controller.publish(newer)
        await waitUntil { viewModel.state.publicationRevision == 12 }
        initial.publicationRevision = 11
        await controller.publish(initial)
        _ = await viewModel.refresh()
        XCTAssertEqual(viewModel.state.usageTarget, .app)
        XCTAssertEqual(viewModel.state.publicationRevision, 12)
        viewModel.stopObserving()
    }

    func testLoadProjectsBootstrapSnapshotAndSubsequentStreamSnapshot()
        async
    {
        let initial = Self.snapshot(
            connection: .default
        )
        let controller =
            AntigravitySettingsRuntimeControllerDouble(
                snapshot: initial
            )
        let viewModel = AntigravitySettingsViewModel(runtimeController: controller)

        await viewModel.load()

        XCTAssertEqual(
            viewModel.state.usageTarget,
            .cli
        )
        XCTAssertEqual(
            viewModel.state.connection,
            initial.settings?.connection
        )
        XCTAssertEqual(viewModel.state.activity, .idle)
        let bootstrapArguments =
            await controller.bootstrapArguments()
        XCTAssertEqual(
            bootstrapArguments,
            [true]
        )

        var localConnection =
            AntigravityConnectionSettings.default
        localConnection.usageTarget = .app
        let streamed = Self.snapshot(
            connection: localConnection,
            revision: 9
        )
        await controller.publish(streamed)
        await waitUntil {
            viewModel.state.publicationRevision == 9
        }

        XCTAssertEqual(
            viewModel.state.usageTarget,
            .app
        )
        XCTAssertEqual(
            viewModel.state.connection,
            streamed.settings?.connection
        )
        viewModel.stopObserving()
    }

    func testDisplayUpdateDelegatesOnceAndProjectsReturnedSnapshot()
        async
    {
        var display = AntigravityDisplaySettings.default
        display.menuBar.showsSelectedLaneResetTime = true
        let updated = Self.snapshot(display: display, revision: 8)
        let controller =
            AntigravitySettingsRuntimeControllerDouble(
                snapshot: Self.snapshot(),
                displayResult: updated
            )
        let viewModel = AntigravitySettingsViewModel(runtimeController: controller)
        await viewModel.load()

        let changed = await viewModel.updateDisplay(
            display,
            replacing: .default
        )
        let requests = await controller.displayRequests()

        XCTAssertTrue(changed)
        XCTAssertEqual(requests, [display])
        XCTAssertEqual(viewModel.state.display, display)
        XCTAssertEqual(viewModel.state.publicationRevision, 8)
        XCTAssertEqual(
            viewModel.state.notice?.tone,
            .success
        )
        viewModel.stopObserving()
    }

    func testSupersededDisplayUpdateDoesNotReportSuccess()
        async
    {
        let controller =
            AntigravitySettingsRuntimeControllerDouble(
                snapshot: Self.snapshot(),
                displayError: .operationSuperseded
            )
        let viewModel = AntigravitySettingsViewModel(runtimeController: controller)
        await viewModel.load()
        var display = AntigravityDisplaySettings.default
        display.menuBar.showsSelectedLaneResetTime = true

        let changed = await viewModel.updateDisplay(
            display,
            replacing: .default
        )

        XCTAssertFalse(changed)
        XCTAssertEqual(
            viewModel.state.notice?.tone,
            .failure
        )
        XCTAssertTrue(
            viewModel.state.notice?.message
                .contains("다른 곳에서 설정이 바뀌어")
                == true
        )
        XCTAssertEqual(viewModel.state.display, .default)
        viewModel.stopObserving()
    }

    func testManagedRuntimeNotFoundExplainsInstallationRequirement() {
        let presentation =
            AntigravityManagedRuntimeSettingsPresentation
                .resolve(
                    .unavailable(
                        reason:
                            .executableNotFound
                    )
                )

        XCTAssertEqual(
            presentation.diagnosticTitle,
            "설치 안 됨"
        )
    }

    func testVerifiedManagedRuntimeShowsExactDetectedPath() {
        let presentation =
            AntigravityManagedRuntimeSettingsPresentation
                .resolve(
                    .available(
                        displayPath:
                            "~/.local/bin/agy"
                    )
                )

        XCTAssertEqual(
            presentation.diagnosticTitle,
            "설치됨 (~/.local/bin/agy)"
        )
    }

    func testMissingAndRejectedExecutablesRemainDistinct() {
        let missing =
            AntigravityManagedRuntimeSettingsPresentation
                .resolve(
                    .unavailable(
                        reason:
                        .executableNotFound
                    )
                )
        let rejected =
            AntigravityManagedRuntimeSettingsPresentation
                .resolve(
                .unavailable(
                    reason:
                        .signatureRejected
                    )
                )

        XCTAssertEqual(
            missing.diagnosticTitle,
            "설치 안 됨"
        )
        XCTAssertEqual(
            rejected.diagnosticTitle,
            "서명 확인 실패"
        )
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<50 {
            if predicate() {
                return
            }
            await Task.yield()
        }
        XCTFail(
            "Timed out waiting for settings projection",
            file: file,
            line: line
        )
    }

    private static func snapshot(
        connection:
            AntigravityConnectionSettings = .default,
        display: AntigravityDisplaySettings = .default,
        revision: UInt64 = 7
    ) -> AntigravityRuntimeSnapshot {
        AntigravityRuntimeSnapshot(
            readiness: .ready,
            settings: AntigravitySettingsSnapshot(
                connection: connection,
                display: display
            ),
            presentationState: .disabled,
            quotaPresentation:
                .unavailable(.disabled),
            managedRuntimeAvailability: .available(
                displayPath: "~/.local/bin/agy"
            ),
            lastAttemptAt: nil,
            lastSuccessfulAt: nil,
            publicationRevision: revision
        )
    }
}

private actor
    AntigravitySettingsRuntimeControllerDouble:
    AntigravitySettingsRuntimeControlling
{
    private var current: AntigravityRuntimeSnapshot
    private let displayResult:
        AntigravityRuntimeSnapshot?
    private let displayError:
        AntigravityRuntimeControllerError?
    private var bootstrapCalls: [Bool] = []
    private var displayUpdates: [AntigravityDisplaySettings] = []
    private var continuations:
        [
            UUID:
                AsyncStream<
                    AntigravityRuntimeSnapshot
                >.Continuation
        ] = [:]

    init(
        snapshot: AntigravityRuntimeSnapshot,
        displayResult:
            AntigravityRuntimeSnapshot? = nil,
        displayError:
            AntigravityRuntimeControllerError? = nil
    ) {
        current = snapshot
        self.displayResult = displayResult
        self.displayError = displayError
    }

    func snapshot() async
        -> AntigravityRuntimeSnapshot
    {
        current
    }

    func snapshots() async
        -> AsyncStream<AntigravityRuntimeSnapshot>
    {
        let id = UUID()
        return AsyncStream(
            bufferingPolicy: .bufferingNewest(1)
        ) { continuation in
            continuations[id] = continuation
            continuation.yield(current)
            continuation.onTermination = {
                @Sendable [weak self] _ in
                Task {
                    await self?.removeContinuation(id)
                }
            }
        }
    }

    func bootstrap(
        performInitialRefresh: Bool
    ) async -> AntigravityRuntimeSnapshot {
        bootstrapCalls.append(performInitialRefresh)
        return current
    }

    func refresh(
        trigger: AntigravityRefreshTrigger
    ) async -> AntigravityRuntimeSnapshot {
        current
    }

    func updateDisplay(
        _ display: AntigravityDisplaySettings,
        replacing expectedDisplay:
            AntigravityDisplaySettings
    ) async throws -> AntigravityRuntimeSnapshot {
        displayUpdates.append(display)
        if let displayError {
            throw displayError
        }
        if let displayResult {
            publish(displayResult)
        }
        return current
    }

    func consumePendingSettingsNotice() async
        -> AntigravityRuntimeSnapshot
    {
        current
    }

    func publish(
        _ snapshot: AntigravityRuntimeSnapshot
    ) {
        current = snapshot
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    func bootstrapArguments() -> [Bool] {
        bootstrapCalls
    }

    func displayRequests() -> [AntigravityDisplaySettings] {
        displayUpdates
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}

extension AntigravitySettingsViewModelTests {
    func testImmediateBootstrapReturnKeepsRuntimeLoadingUntilReadyStreamPublication() async throws {
        let typedBase = Self.snapshot(revision: 7)
        let typedSettings = try XCTUnwrap(typedBase.settings)
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let lanes = [
            AntigravityQuotaLane(
                id: .geminiWeekly, upstreamGroupID: "gemini", upstreamBucketID: "weekly",
                scope: .gemini, cadence: .weekly, remainingFraction: 0.8,
                resetAt: now.addingTimeInterval(86400), resetDescription: nil, availability: .available),
            AntigravityQuotaLane(
                id: .thirdPartyWeekly, upstreamGroupID: "third-party", upstreamBucketID: "weekly",
                scope: .thirdPartyModels, cadence: .weekly, remainingFraction: 0.4,
                resetAt: now.addingTimeInterval(86400), resetDescription: nil, availability: .available),
        ]
        let finalQuota = AntigravityQuotaSnapshot(
            identity: nil, plan: nil, lanes: lanes, decodeIssues: [],
            provenance: .init(
                transport: .cliUsageReport, endpointOwner: .managed, accountIdentity: nil,
                capability: .groupedQuotaSummary, processIdentity: nil),
            fetchedAt: now)

        func publication(
            readiness: AntigravityRuntimeReadiness,
            presentation: AntigravityPresentationState,
            revision: UInt64
        ) -> AntigravityRuntimeSnapshot {
            AntigravityRuntimeSnapshot(
                readiness: readiness, settings: typedSettings, presentationState: presentation,
                quotaPresentation: AntigravityQuotaPresentationMapper.map(
                    state: presentation, settings: typedSettings.display, now: now, timeZone: utc),
                managedRuntimeAvailability: typedBase.managedRuntimeAvailability,
                lastAttemptAt: now, lastSuccessfulAt: readiness == .ready ? now : nil,
                publicationRevision: revision)
        }

        // This double returns immediately, matching a second bootstrap caller while the actor is still busy.
        let bootstrapping = publication(readiness: .bootstrapping, presentation: .disabled, revision: 7)
        let controller = AntigravitySettingsRuntimeControllerDouble(snapshot: bootstrapping)
        let viewModel = AntigravitySettingsViewModel(runtimeController: controller)
        defer { viewModel.stopObserving() }
        XCTAssertFalse(viewModel.state.isRuntimeLoading)

        await viewModel.load()

        XCTAssertEqual(viewModel.state.activity, .idle)
        XCTAssertEqual(viewModel.state.connection, typedSettings.connection)
        XCTAssertEqual(viewModel.state.display, typedSettings.display)
        XCTAssertTrue(
            viewModel.state.isRuntimeLoading,
            "Typed display exists and load() returned, but the shared runtime has not finished.")
        XCTAssertEqual(viewModel.state.publicationRevision, 7)
        XCTAssertEqual(viewModel.state.quotaPresentation, .unavailable(.disabled))

        // Readiness can already be .ready while its refresh is still pending. Use the canonical isLoading
        // projection rather than deriving this state from readiness or local activity alone.
        let refreshing = publication(
            readiness: .ready, presentation: .refreshing(previous: nil), revision: 8)
        await controller.publish(refreshing)
        await waitUntil { viewModel.state.publicationRevision == 8 }
        XCTAssertEqual(viewModel.state.activity, .idle)
        XCTAssertTrue(viewModel.state.isRuntimeLoading)
        XCTAssertEqual(viewModel.state.quotaPresentation, .unavailable(.refreshing(previous: nil)))

        let ready = publication(readiness: .ready, presentation: .ready(finalQuota), revision: 9)
        await controller.publish(ready)
        await waitUntil { viewModel.state.publicationRevision == 9 }

        XCTAssertEqual(viewModel.state.activity, .idle)
        XCTAssertFalse(viewModel.state.isRuntimeLoading)
        XCTAssertEqual(viewModel.state.presentation, .ready(finalQuota))
        XCTAssertEqual(viewModel.state.connection, typedSettings.connection)
        XCTAssertEqual(viewModel.state.display, typedSettings.display)
        guard case .content(let visibleQuota) = viewModel.state.quotaPresentation else {
            return XCTFail("The final stream publication must replace unavailable quota UI with content.")
        }
        XCTAssertEqual(
            Set(visibleQuota.groups.flatMap(\.lanes).map(\.id)),
            Set([AntigravityQuotaLaneID.geminiWeekly, .thirdPartyWeekly]))
        let bootstrapArguments = await controller.bootstrapArguments()
        XCTAssertEqual(bootstrapArguments, [true], "Readiness must update through observation without a second load.")
    }
}
