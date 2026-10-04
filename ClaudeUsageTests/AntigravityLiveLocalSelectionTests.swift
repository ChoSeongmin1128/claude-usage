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
            let first = try verifiedReport(await controller.bootstrap(performInitialRefresh: true))
            try markPhase("A1", quota: first, gate: gate)
            for phase in ["B", "A2"] {
                let deadline = ContinuousClock.now.advanced(by: .seconds(1800))
                while !FileManager.default.fileExists(atPath: gate.appendingPathComponent(phase + ".continue").path) {
                    guard ContinuousClock.now < deadline else { throw LiveLocalSelectionError.loginSwitch }
                    try await Task.sleep(for: .milliseconds(250))
                }
                // A report carries no account identity; each phase proves the
                // selected CLI target keeps reporting for the current login.
                let snapshot = await controller.refresh(trigger: .manual)
                _ = try verifiedReport(snapshot)
                let stored = try await settings.load()
                XCTAssertEqual(stored.connection.usageTarget, .cli)
                let repeated = try verifiedReport(await controller.refresh(trigger: .scheduled))
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
        let refresh = AntigravityRefreshCoordinator(
            sources: [], runtimeEnvironment: environment)
        // 기본 legacyAccountCleanup은 아무것도 하지 않아 사용자의 Keychain을 건드리지 않는다.
        let controller = AntigravityRuntimeController(
            settingsStore: settings, refreshCoordinator: refresh, runtimeLifecycle: environment,
            settingsBootstrap: .ready(.alreadyCurrent), agyExecutableStatus: .notFound,
            runtimeEnvironment: environment)
        return (controller, settings)
    }

    func testOfficialCLITargetPersistsWithoutOAuthAndLeavesNoLedger() async throws {
        guard ProcessInfo.processInfo.environment["CLAUDEUSAGE_RUN_LIVE_AGY_TESTS"] == "1" else {
            throw XCTSkip("Official signed-in AGY is required")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeUsage-live-selection-\(UUID())")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let (controller, settings) = try makeRuntime(root: root)
        do {
            let snapshot = await controller.bootstrap(performInitialRefresh: true)
            _ = try verifiedReport(snapshot)
            let target = AntigravityUsageTarget.cli
            let stored = try await settings.load()
            XCTAssertEqual(stored.connection.usageTarget, target)
            let repeated = await controller.refresh(trigger: .scheduled)
            let second = try verifiedReport(repeated)
            XCTAssertEqual(repeated.settings?.connection.usageTarget, target)
            print("LIVE_LOCAL_SELECTION_VERIFIED numeric_lanes=\(second.lanes.count)")
            await controller.shutdown()
            // Reports own no long-lived process, so nothing is ever recorded.
            guard
                !FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(AntigravityManagedProcessRecordFileStore.fileName).path)
            else { throw LiveLocalSelectionError.cleanupUnconfirmed }
            try FileManager.default.removeItem(at: root)
        } catch {
            await controller.shutdown()
            throw error
        }
    }

    private func verifiedReport(
        _ snapshot: AntigravityRuntimeSnapshot
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
        guard quota.identity == nil,
            quota.provenance.transport == .cliUsageReport,
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
    case noAuthenticatedQuota, cleanupUnconfirmed, loginSwitch
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
