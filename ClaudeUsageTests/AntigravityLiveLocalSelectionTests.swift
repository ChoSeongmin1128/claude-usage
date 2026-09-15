import Foundation
import os
import XCTest
@testable import ClaudeUsage

final class AntigravityLiveLocalSelectionTests: XCTestCase {
    func testUserDrivenCLILoginChangesKeepUsageTarget() async throws {
        guard let gatePath = ProcessInfo.processInfo.environment["CLAUDEUSAGE_AGY_TARGET_SWITCH_GATE"] else {
            throw XCTSkip("User-driven CLI login switch gate is required")
        }
        let gate = URL(fileURLWithPath: gatePath)
        let (controller, settings) = try makeRuntime(root: gate.appendingPathComponent("runtime"))
        do {
            let first = try verifiedQuota(await controller.bootstrap(performInitialRefresh: true))
            try markPhase("A1", quota: first, gate: gate)
            for phase in ["B", "A2"] {
                let deadline = ContinuousClock.now.advanced(by: .seconds(1800))
                while !FileManager.default.fileExists(atPath: gate.appendingPathComponent(phase + ".continue").path) {
                    guard ContinuousClock.now < deadline else { throw LiveLocalSelectionError.loginSwitch }
                    try await Task.sleep(for: .milliseconds(250))
                }
                let snapshot = await controller.refresh(trigger: .manual)
                let quota = try verifiedQuota(snapshot)
                let sameIdentity = AntigravityAccountIdentityMatcher.match(
                    expected: try XCTUnwrap(first.identity), received: quota.identity
                ).isMatch
                guard sameIdentity == (phase == "A2") else { throw LiveLocalSelectionError.loginSwitch }
                let stored = try await settings.load()
                XCTAssertEqual(stored.connection.usageTarget, .cli)
                XCTAssertNil(snapshot.activeAccountID)
                let repeated = try verifiedQuota(
                    await controller.refresh(trigger: .scheduled), expected: quota.identity)
                XCTAssertEqual(quota.provenance.processIdentity, repeated.provenance.processIdentity)
                try markPhase(phase, quota: repeated, gate: gate)
            }
            await controller.shutdown()
        } catch {
            await controller.shutdown()
            throw error
        }
    }

    private func markPhase(_ phase: String, quota: AntigravityQuotaSnapshot, gate: URL) throws {
        print("LIVE_CLI_TARGET_PHASE \(phase) verified numeric_lanes=\(quota.lanes.count)")
        try Data("verified".utf8).write(to: gate.appendingPathComponent(phase + ".ready"), options: .atomic)
    }

    private func makeRuntime(root: URL) throws -> (AntigravityRuntimeController, AntigravitySettingsStore) {
        let environment = AntigravityRuntimeEnvironment.production(
            homeDirectoryURL: FileManager.default.realHomeDirectory, stateDirectory: root)
        let settings = AntigravitySettingsStore(persistence: try LiveLocalSelectionPersistence())
        let repository = LiveLocalOnlyRepository()
        let refresh = AntigravityRefreshCoordinator(
            repository: repository, sources: [], runtimeEnvironment: environment)
        let controller = AntigravityRuntimeController(
            repository: repository, settingsStore: settings, migrationCoordinator: LiveNoCredentialMigration(),
            refreshCoordinator: refresh, managedSession: environment, settingsBootstrap: .ready(.alreadyCurrent),
            agyExecutableStatus: .notFound, runtimeEnvironment: environment)
        return (controller, settings)
    }

    func testOfficialLocalAccountSelectionPersistsWithoutOAuthAndReusesSession() async throws {
        guard ProcessInfo.processInfo.environment["CLAUDEUSAGE_RUN_LIVE_AGY_TESTS"] == "1" else {
            throw XCTSkip("Official signed-in AGY is required")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeUsage-live-selection-\(UUID())")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let (controller, settings) = try makeRuntime(root: root)
        do {
            let snapshot = await controller.bootstrap(performInitialRefresh: true)
            let first = try verifiedQuota(snapshot)
            let target = AntigravityUsageTarget.cli
            XCTAssertNil(snapshot.activeAccountID)
            XCTAssertTrue(snapshot.accounts.isEmpty)
            let stored = try await settings.load()
            XCTAssertEqual(stored.connection.usageTarget, target)
            let repeated = await controller.refresh(trigger: .scheduled)
            let second = try verifiedQuota(repeated, expected: first.identity)
            XCTAssertEqual(first.provenance.processIdentity, second.provenance.processIdentity)
            XCTAssertEqual(repeated.settings?.connection.usageTarget, target)
            print("LIVE_LOCAL_SELECTION_VERIFIED numeric_lanes=\(second.lanes.count)")
            await controller.shutdown()
            let ledger = try AntigravityManagedProcessRecordFileStore(
                fileURL: root.appendingPathComponent("managed-agy-sessions.json")
            ).loadLedger()
            guard ledger.entries.isEmpty else { throw LiveLocalSelectionError.cleanupUnconfirmed }
            try FileManager.default.removeItem(at: root)
        } catch {
            await controller.shutdown()
            // A failed process cleanup must retain its ownership evidence.
            throw error
        }
    }

    private func verifiedQuota(
        _ snapshot: AntigravityRuntimeSnapshot,
        expected: ProviderAccountIdentity? = nil
    ) throws -> AntigravityQuotaSnapshot {
        let quota: AntigravityQuotaSnapshot
        switch snapshot.presentationState {
        case .ready(let value), .partial(let value, _): quota = value
        default:
            print(
                "LIVE_CLI_TARGET_REJECTED code=\(OperationalDiagnostic.antigravity(snapshot.presentationState)?.code ?? "noQuota")"
            )
            throw LiveLocalSelectionError.noAuthenticatedQuota
        }
        guard let identity = quota.identity,
            AntigravityAccountIdentityMatcher.match(expected: expected ?? identity, received: identity).isMatch,
            !quota.lanes.isEmpty,
            quota.lanes.allSatisfy({ lane in
                guard let fraction = lane.remainingFraction else { return false }
                return fraction.isFinite && (0...1).contains(fraction)
            })
        else { throw LiveLocalSelectionError.noAuthenticatedQuota }
        return quota
    }
}

private enum LiveLocalSelectionError: Error {
    case noAuthenticatedQuota, unexpectedOAuthAccess, cleanupUnconfirmed, loginSwitch
}

/// Any OAuth operation fails the live test instead of reaching the user's credential store.
private struct LiveLocalOnlyRepository: AntigravityRuntimeAccountPersisting, AntigravityRefreshAccountRepository {
    func state() async throws -> AntigravityAccountRepositoryState { .init() }
    func credentialSnapshot(for accountID: AntigravityAccountID) async throws -> AntigravityCredentialSnapshot? {
        throw LiveLocalSelectionError.unexpectedOAuthAccess
    }
    func createAccount(
        credentials: AntigravityOAuthCredentials, label: String,
        externalIdentity: AntigravityExternalAccountIdentity, migrationAliases: [String],
        makeActive: Bool, expectedRevision: UInt64
    ) async throws -> AntigravityAccountRepositoryState {
        throw LiveLocalSelectionError.unexpectedOAuthAccess
    }
    func replaceCredential(
        for accountID: AntigravityAccountID, with credentials: AntigravityOAuthCredentials,
        externalIdentity: AntigravityExternalAccountIdentity?,
        expectedRevision: UInt64
    ) async throws -> AntigravityAccountRepositoryState {
        throw LiveLocalSelectionError.unexpectedOAuthAccess
    }
    func deleteAccount(
        id accountID: AntigravityAccountID,
        expectedRevision: UInt64
    ) async throws -> AntigravityAccountRepositoryState {
        throw LiveLocalSelectionError.unexpectedOAuthAccess
    }
}

private struct LiveNoCredentialMigration: AntigravityRuntimeMigrationCoordinating {
    func checkForMigration() async -> AntigravityMigrationStatus {
        .init(
            phase: .complete, sourceOutcomes: [:], plannedAccountCount: 0,
            blocker: nil, requiredAction: nil, authorizationCancelledThisSession: false)
    }
    func performInteractiveMigration() async -> AntigravityMigrationStatus { await checkForMigration() }
    func removeAllAccounts() async -> AntigravityMigrationStatus { await checkForMigration() }
    func removeAllAccountsInteractively() async -> AntigravityMigrationStatus { await checkForMigration() }
}

private struct LiveLocalSelectionPersistence: AntigravitySettingsDataPersisting {
    let storage: OSAllocatedUnfairLock<[String: Data]>
    init() throws {
        var connection = AntigravityConnectionSettings.default
        connection.usageTarget = .cli
        storage = OSAllocatedUnfairLock(initialState: [
            AntigravitySettingsMigrationKeys.connectionSettings: try JSONEncoder().encode(connection),
            AntigravitySettingsMigrationKeys.displaySettings: try JSONEncoder().encode(
                AntigravityDisplaySettings.default),
        ])
    }
    func storedData(forKey key: String) -> AntigravitySettingsStoredData {
        storage.withLock { $0[key].map(AntigravitySettingsStoredData.data) ?? .missing }
    }
    func setData(_ data: Data, forKey key: String) throws { storage.withLock { $0[key] = data } }
}
