import Foundation
import XCTest
@testable import ClaudeUsage

final class UpdateRuntimeStateTests: XCTestCase {
    func testPopoverButtonOnlyAppearsAfterSparkleDownloadIsPrepared() {
        let sparkleReady = UpdateEngineStatus(
            modeSummary: "Sparkle",
            sparkleIntegrated: true,
            feedConfigured: true,
            publicKeyConfigured: true
        )

        XCTAssertFalse(
            UpdateRuntimeState.shouldShowPopoverButton(
                phase: .idle,
                engineStatus: sparkleReady
            )
        )
        XCTAssertFalse(
            UpdateRuntimeState.shouldShowPopoverButton(
                phase: .updateAvailable(version: "9.9.9"),
                engineStatus: sparkleReady
            )
        )
        XCTAssertFalse(
            UpdateRuntimeState.shouldShowPopoverButton(
                phase: .downloading(version: "9.9.9"),
                engineStatus: sparkleReady
            )
        )
        XCTAssertFalse(
            UpdateRuntimeState.shouldShowPopoverButton(
                phase: .downloaded(version: "9.9.9"),
                engineStatus: sparkleReady
            )
        )
        XCTAssertTrue(
            UpdateRuntimeState.shouldShowPopoverButton(
                phase: .readyToInstall(version: "9.9.9"),
                engineStatus: sparkleReady
            )
        )
        XCTAssertFalse(
            UpdateRuntimeState.shouldShowPopoverButton(
                phase: .readyToInstall(version: "9.9.9"),
                engineStatus: UpdateEngineStatus(
                    modeSummary: "Fallback",
                    sparkleIntegrated: false,
                    feedConfigured: false,
                    publicKeyConfigured: false
                )
            )
        )
    }

    func testPrimaryActionOnlyTreatsSparklePreparedUpdateAsInstallable() {
        let sparkleReady = UpdateEngineStatus(
            modeSummary: "Sparkle",
            sparkleIntegrated: true,
            feedConfigured: true,
            publicKeyConfigured: true
        )
        let fallback = UpdateEngineStatus(
            modeSummary: "Fallback",
            sparkleIntegrated: false,
            feedConfigured: false,
            publicKeyConfigured: false
        )

        XCTAssertFalse(
            UpdateRuntimeState.shouldShowPrimaryAction(
                phase: .downloaded(version: "9.9.9"),
                engineStatus: sparkleReady
            )
        )
        XCTAssertTrue(
            UpdateRuntimeState.shouldShowPrimaryAction(
                phase: .readyToInstall(version: "9.9.9"),
                engineStatus: sparkleReady
            )
        )
        XCTAssertTrue(
            UpdateRuntimeState.shouldShowPrimaryAction(
                phase: .installing(version: "9.9.9"),
                engineStatus: sparkleReady
            )
        )
        XCTAssertFalse(
            UpdateRuntimeState.shouldShowPrimaryAction(
                phase: .updateAvailable(version: "9.9.9"),
                engineStatus: sparkleReady
            )
        )
        XCTAssertTrue(
            UpdateRuntimeState.shouldShowPrimaryAction(
                phase: .updateAvailable(version: "9.9.9"),
                engineStatus: fallback
            )
        )
    }
}

@MainActor
final class UpdateServiceTests: XCTestCase {
    #if canImport(Sparkle)
    @MainActor
    func testBackgroundUpdaterDeclaresGentleReminderSupport() {
        let engine = SparkleUpdateEngine(
            feedURL: nil
        )

        XCTAssertTrue(
            engine
                .supportsGentleScheduledUpdateReminders
        )
        XCTAssertTrue(
            engine.responds(
                to: NSSelectorFromString(
                    "supportsGentleScheduledUpdateReminders"
                )
            )
        )
    }
    #endif

    func testUserInitiatedCheckUsesBackgroundCheckWhenEngineIsNotInteractive() async {
        let engine = FakeUpdateEngine(supportsInteractiveCheck: false)
        let service = UpdateService(engine: engine)

        await service.performUserInitiatedCheck()

        XCTAssertEqual(engine.checkCount, 1)
        XCTAssertEqual(engine.interactiveCheckCount, 0)
    }

    func testUserInitiatedCheckUsesInteractivePathOnlyWhenEngineSupportsIt() async {
        let engine = FakeUpdateEngine(supportsInteractiveCheck: true)
        let service = UpdateService(engine: engine)

        await service.performUserInitiatedCheck()

        XCTAssertEqual(engine.checkCount, 0)
        XCTAssertEqual(engine.interactiveCheckCount, 1)
    }

    func testPreparedUpdatePresentationUsesExplicitInteractivePath() async {
        let engine = FakeUpdateEngine(supportsInteractiveCheck: false)
        let service = UpdateService(engine: engine)

        let didPresent = await service.presentPreparedUpdate()

        XCTAssertTrue(didPresent)
        XCTAssertEqual(engine.checkCount, 0)
        XCTAssertEqual(engine.interactiveCheckCount, 1)
    }

    func testInstallPreparedUpdateDelegatesToEngine() async {
        let engine = FakeUpdateEngine(supportsInteractiveCheck: false)
        let service = UpdateService(engine: engine)

        let didInstall = await service.installPreparedUpdate()

        XCTAssertTrue(didInstall)
        XCTAssertEqual(engine.installCount, 1)
    }
}

private final class FakeUpdateEngine: AppUpdateEngine {
    private let isInteractive: Bool
    private let name: String
    private var _checkCount = 0
    private var _interactiveCheckCount = 0
    private var _installCount = 0

    init(supportsInteractiveCheck: Bool, name: String = "Fake") {
        self.isInteractive = supportsInteractiveCheck
        self.name = name
    }

    var checkCount: Int {
        _checkCount
    }

    var interactiveCheckCount: Int {
        _interactiveCheckCount
    }

    var installCount: Int {
        _installCount
    }

    func modeSummary() async -> String {
        name
    }

    func checkForUpdates() async -> UpdateCheckResult {
        _checkCount += 1
        return .upToDate(message: nil)
    }

    func latestDownloadURL() async -> URL {
        URL(string: "https://example.com/ClaudeUsage.zip")!
    }

    func usesExternalScheduler() async -> Bool {
        true
    }

    func supportsInteractiveCheck() async -> Bool {
        isInteractive
    }

    func performInteractiveCheck() async -> String? {
        _interactiveCheckCount += 1
        return "interactive"
    }

    func presentPreparedUpdate() async -> Bool {
        _ = await performInteractiveCheck()
        return true
    }

    func synchronizeScheduler(interval: UpdateCheckInterval, runImmediate: Bool) async { }

    func installPreparedUpdate() async -> Bool {
        _installCount += 1
        return true
    }

    func configurationStatus() async -> UpdateEngineStatus {
        UpdateEngineStatus(
            modeSummary: "Fake",
            sparkleIntegrated: true,
            feedConfigured: true,
            publicKeyConfigured: true
        )
    }
}


extension UpdateServiceTests {
    func testConcurrentEngineResolutionSharesOneInitialization() async throws {
        let factory = SuspendedReviewEngineFactory()
        let service = UpdateService(makeEngine: { await factory.make() }, configurationSignature: { "same" })
        let first = Task { await service.currentModeSummary() }
        let second = Task { await service.currentModeSummary() }
        try await waitForReviewEngine { !factory.created.isEmpty }
        for _ in 0..<20 { await Task.yield() }
        factory.completeAll()
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertEqual(firstResult, "engine-1")
        XCTAssertEqual(secondResult, "engine-1")
        XCTAssertEqual(factory.created.count, 1)
        let installed = await service.installPreparedUpdate()
        XCTAssertTrue(installed)
        XCTAssertEqual(factory.created.first?.installCount, 1)
    }

    func testLateEngineForPreviousConfigurationCannotReplaceCurrentEngine() async throws {
        let signature = ReviewEngineSignature("a")
        let factory = SuspendedReviewEngineFactory()
        let service = UpdateService(makeEngine: { await factory.make() }, configurationSignature: { signature.value })
        let first = Task { await service.currentModeSummary() }
        try await waitForReviewEngine { factory.created.count == 1 }
        signature.value = "b"
        let second = Task { await service.currentModeSummary() }
        try await waitForReviewEngine { factory.created.count == 2 }
        factory.complete(2)
        let secondResult = await second.value
        XCTAssertEqual(secondResult, "engine-2")
        factory.complete(1)
        let firstResult = await first.value
        XCTAssertEqual(firstResult, "engine-2")
        let installed = await service.installPreparedUpdate()
        XCTAssertTrue(installed)
        XCTAssertEqual(factory.created[0].installCount, 0)
        XCTAssertEqual(factory.created[1].installCount, 1)
        XCTAssertEqual(factory.created.count, 2)
    }

    private func waitForReviewEngine(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("업데이트 엔진 생성이 시작되지 않았습니다") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testOtherAccountUsageRemainsVisibleWhenRuntimeLoginRequiresAuthentication() throws {
        let suite = "UpdateServiceTests.secondaryQuota.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.setProviderEnabled(true, for: .claude)
        let update = UpdateRuntimeState(
            settings: settings,
            updateService: UpdateService(
                engine: FakeUpdateEngine(supportsInteractiveCheck: false)))
        let model = PopoverViewModel(updateRuntimeState: update)
        model.multiAccount[.claude] = .init(
            service: .claude, mode: .summaryRows,
            rows: [
                .init(
                    id: "other", service: .claude, name: "other", badges: [], status: .current,
                    usage: .init(fiveHour: .init(usedPercent: 20, resetsAt: nil)), fetchedAt: Date(),
                    isRuntime: false, basis: .used)
            ], selectedIDs: [])
        XCTAssertEqual(model.contentPhase(for: .claude, settings: settings), .content)
        XCTAssertTrue(
            model.displaySections(for: .claude, density: .standard, settings: settings).contains {
                $0.kind == .accountRow
            })
        model.multiAccount.removeAll()
        XCTAssertEqual(model.contentPhase(for: .claude, settings: settings), .authRequired)
    }
}

@MainActor
private final class SuspendedReviewEngineFactory {
    private(set) var created: [FakeUpdateEngine] = []
    private var pending: [Int: CheckedContinuation<Void, Never>] = [:]
    func make() async -> any AppUpdateEngine {
        let number = created.count + 1
        let engine = FakeUpdateEngine(supportsInteractiveCheck: false, name: "engine-\(number)")
        created.append(engine)
        await withCheckedContinuation { pending[number] = $0 }
        return engine
    }
    func complete(_ number: Int) { pending.removeValue(forKey: number)?.resume() }
    func completeAll() { for number in Array(pending.keys) { complete(number) } }
}

nonisolated private final class ReviewEngineSignature: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String
    init(_ value: String) { storage = value }
    var value: String {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }
}

extension UpdateServiceTests {
    private func scopedHeaderModel(metadata: RuntimeProviderFetchMetadata) throws -> (PopoverViewModel, AppSettings) {
        let suite = "UpdateServiceTests.header.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.setProviderEnabled(true, for: .claude)
        let model = PopoverViewModel(
            updateRuntimeState: .init(
                settings: settings,
                updateService: UpdateService(engine: FakeUpdateEngine(supportsInteractiveCheck: false))))
        let empty = ClaudeAPIService.AuthPathHealthSnapshot(
            lastAttemptAt: nil, lastSuccessAt: nil, lastFailureAt: nil, lastErrorMessage: nil,
            consecutiveFailures: 0, totalAttempts: 0, totalFailures: 0)
        model.usageHealthSnapshot = .init(
            lastOverallSuccessAt: nil, session: empty, oauth: empty,
            runtime: .init(
                activePath: .oauthPreferred,
                credentialAvailability: .init(sessionCredentialAvailable: false, oauthCredentialAvailable: true),
                sessionValidationState: .unavailable, oauthValidationState: .verified,
                sessionCooldownRemaining: nil, oauthPreferredRemaining: nil),
            accounts: [
                .init(
                    id: ClaudeAccountStore.claudeCodeExternalAccountID, kind: .claudeCodeExternal,
                    displayName: "old A",
                    identity: .init(
                        email: "a@example.com", organizationName: "Old Org",
                        organizationID: "old-org", planLabel: "old-plan")),
                .init(id: "other", kind: .webSession, displayName: "other"),
            ],
            activeAccountID: ClaudeAccountStore.claudeCodeExternalAccountID)
        model.update(snapshots: [
            .init(
                service: .claude,
                payload: .claude(.init(fiveHour: .init(utilization: 42, resetsAt: nil), sevenDay: nil)),
                lastUpdated: Date(), credentialState: .usable, isDetected: true,
                canAttemptRefresh: true, hasAuthError: false, lastSuccessfulMetadata: metadata)
        ])
        return (model, settings)
    }

    func testNormalAndCompactHeadersUseNewPayloadIdentityBeforeHealthCatchesUp() throws {
        let candidate = UsageAccountCandidate(
            source: .init(role: .defaultLogin, reference: "/fixture/.claude"),
            identity: .init(
                accountID: "user-b", organizationID: "new-org", email: "b@example.com", organizationName: "New Org"))
        let metadata = RuntimeProviderFetchMetadata(
            sourceLabel: "Claude Code", accountID: ClaudeAccountStore.claudeCodeExternalAccountID, account: candidate
        ).withClaudeProfileMetadata(.init(organizationUUID: "new-org", subscriptionType: "new-plan"))
        let (model, settings) = try scopedHeaderModel(metadata: metadata)
        XCTAssertEqual(model.runtimeServiceState(for: .claude, settings: settings).accountLabel, "b@example.com")
        XCTAssertEqual(model.claudeAccountPresentation?.identity.planLabel, "new-plan")
        XCTAssertEqual(model.compactHeaderContext(for: .claude, settings: settings)?.accountLabel, "b@example.com")
        for density in [PopoverDensity.standard, .compact] {
            let sections = model.displaySections(for: .claude, density: density, settings: settings)
            XCTAssertTrue(
                sections.contains { section in
                    guard case .usage(let usage) = section.payload else { return false }
                    return usage.percentage == 42
                })
        }
    }

    func testUnknownIdentityDoesNotBorrowOldSlotProfileOrHideQuota() throws {
        let candidate = UsageAccountCandidate(
            source: .init(role: .defaultLogin, reference: "/fixture/.claude"), identity: .init())
        let metadata = RuntimeProviderFetchMetadata(
            sourceLabel: "Claude Code", accountID: ClaudeAccountStore.claudeCodeExternalAccountID,
            account: candidate
        ).withClaudeProfileMetadata(.init(organizationUUID: "old-org", subscriptionType: "old-plan"))
        let (model, settings) = try scopedHeaderModel(metadata: metadata)
        XCTAssertNil(model.runtimeServiceState(for: .claude, settings: settings).accountLabel)
        XCTAssertNil(model.claudeAccountPresentation?.identity.planLabel)
        XCTAssertNil(model.compactHeaderContext(for: .claude, settings: settings))
        XCTAssertEqual(model.contentPhase(for: .claude, settings: settings), .content)
        XCTAssertTrue(
            model.displaySections(for: .claude, density: .standard, settings: settings).contains { $0.kind == .usage })
    }

    func testWebPresentationAllowsOnlyMatchingFingerprintAndOrganizationAlias() {
        let stored = ClaudeAccount(
            id: "web", kind: .webSession, displayName: "Chrome 2",
            identity: .init(email: "a@example.com", organizationName: "Team", organizationID: "org", planLabel: "team"))
        let candidate = UsageAccountCandidate(
            source: .init(role: .web, reference: "web"), identity: .init(organizationID: "org"))
        let metadata = RuntimeProviderFetchMetadata(accountID: "web", account: candidate)
        let presentation = ClaudeUsageAccountPresentation.resolve(metadata: metadata, storedAccounts: [stored])
        XCTAssertEqual(presentation?.identity.email, "a@example.com")
        XCTAssertEqual(presentation?.sourceAlias, "Chrome 2")
        let otherOrg = RuntimeProviderFetchMetadata(
            accountID: "web",
            account: .init(
                source: candidate.source,
                identity: .init(organizationID: "other-org")))
        XCTAssertNil(ClaudeUsageAccountPresentation.resolve(metadata: otherOrg, storedAccounts: [stored])?.sourceAlias)
        XCTAssertNil(
            ClaudeUsageAccountPresentation.resolve(metadata: otherOrg, storedAccounts: [stored])?.identity.email)
        let otherSource = RuntimeProviderFetchMetadata(
            accountID: "other-web",
            account: .init(
                source: .init(role: .web, reference: "other-web"), identity: .init(organizationID: "org")))
        XCTAssertNil(
            ClaudeUsageAccountPresentation.resolve(metadata: otherSource, storedAccounts: [stored])?.sourceAlias)
    }

    func testPlanOnlyMetadataRemainsDistinctFromCompactAccountIdentity() throws {
        let candidate = UsageAccountCandidate(
            source: .init(role: .defaultLogin, reference: "/fixture/.claude"),
            identity: .init(accountID: "user-b", organizationID: "new-org"))
        let metadata = RuntimeProviderFetchMetadata(
            accountID: ClaudeAccountStore.claudeCodeExternalAccountID,
            account: candidate
        ).withClaudeProfileMetadata(.init(organizationUUID: "new-org", subscriptionType: "team"))
        let (model, settings) = try scopedHeaderModel(metadata: metadata)
        XCTAssertEqual(model.claudeAccountPresentation?.identity.planLabel, "team")
        XCTAssertNil(model.compactHeaderContext(for: .claude, settings: settings))
        XCTAssertEqual(model.claudeUsage?.fiveHour?.utilization, 42)
        let wrongProfile = metadata.withClaudeProfileMetadata(
            .init(organizationUUID: "old-org", subscriptionType: "old-plan"))
        XCTAssertNil(wrongProfile.claudeProfileMetadata)
    }
}
