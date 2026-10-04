import Darwin
import Foundation
import XCTest

@testable import ClaudeUsage

final class AntigravityLiveAGYIntegrationTests: XCTestCase {
    /// The user switches the official AGY login between phases; only phase
    /// markers cross this test boundary. A usage report carries no account
    /// identity, so each phase proves that reports keep returning numeric quota
    /// for whichever account is signed in.
    func testUserDrivenCLILoginSwitchKeepsReportingNumericQuota() async throws {
        guard let gatePath = ProcessInfo.processInfo.environment["CLAUDEUSAGE_AGY_ACCOUNT_SWITCH_GATE"] else {
            throw XCTSkip("User-driven AGY A→B→A gate is required")
        }
        let gate = URL(fileURLWithPath: gatePath)
        let environment = AntigravityRuntimeEnvironment.production(
            homeDirectoryURL: FileManager.default.realHomeDirectory,
            stateDirectory: gate.appendingPathComponent("report-state"))
        do {
            try validatePhase(try await fetchReport(environment), phase: "A1", gate: gate)
            for phase in ["B", "A2"] {
                let waitDeadline = ContinuousClock.now.advanced(by: .seconds(1800))
                while !FileManager.default.fileExists(atPath: gate.appendingPathComponent(phase + ".continue").path) {
                    guard ContinuousClock.now < waitDeadline else { throw LiveAGYIntegrationTestError.accountSwitch }
                    try await Task.sleep(for: .milliseconds(250))
                }
                try validatePhase(try await fetchReport(environment), phase: phase, gate: gate)
            }
            await environment.shutdown()
        } catch {
            await environment.shutdown()
            throw error
        }
    }

    private func validatePhase(_ snapshot: AntigravityQuotaSnapshot, phase: String, gate: URL) throws {
        guard !snapshot.lanes.isEmpty,
            snapshot.lanes.allSatisfy({ lane in
                guard let fraction = lane.remainingFraction else { return false }
                return fraction.isFinite && (0...1).contains(fraction)
            })
        else { throw LiveAGYIntegrationTestError.accountSwitch }
        Swift.print("LIVE_AGY_ACCOUNT_PHASE \(phase) verified numeric_lanes=\(snapshot.lanes.count)")
        try Data("verified".utf8).write(to: gate.appendingPathComponent(phase + ".ready"), options: .atomic)
    }

    func testRuntimeEnvironmentRecoversAfterOfficialBinaryReplacement() async throws {
        guard ProcessInfo.processInfo.environment["CLAUDEUSAGE_RUN_LIVE_AGY_TESTS"] == "1" else {
            throw XCTSkip("CLAUDEUSAGE_RUN_LIVE_AGY_TESTS=1 is required")
        }
        let home = FileManager.default.realHomeDirectory
        let original = try XCTUnwrap(
            AntigravityProductionExecutableCatalogResolver(homeDirectoryURL: home)
                .resolve().reportExecutable)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ClaudeUsage-live-replacement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let executable = root.appendingPathComponent("agy")
        try FileManager.default.copyItem(at: original.canonicalURL, to: executable)
        let environment = AntigravityRuntimeEnvironment.production(
            homeDirectoryURL: home,
            stateDirectory: root.appendingPathComponent("state"),
            environment: ["ANTIGRAVITY_CLI_PATH": executable.path])
        do {
            let first = try await fetchReport(environment)
            let replacement = root.appendingPathComponent("agy-next")
            try FileManager.default.copyItem(at: original.canonicalURL, to: replacement)
            // Same official version, new inode: deterministic updater-style atomic replacement.
            guard rename(replacement.path, executable.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
            let second = try await fetchReport(environment)
            XCTAssertFalse(first.lanes.isEmpty)
            XCTAssertFalse(second.lanes.isEmpty)
            XCTAssertEqual(second.provenance.transport, .cliUsageReport)
            assertNoChildProcess(running: executable)
            Swift.print("LIVE_AGY_REPLACEMENT_RECOVERED lanes=\(second.lanes.count)")
            await environment.shutdown()
            try FileManager.default.removeItem(at: root)
        } catch {
            await environment.shutdown()
            throw error
        }
    }

    func testProductionCLIReportReturnsRealGroupedQuota() async throws {
        guard ProcessInfo.processInfo.environment["CLAUDEUSAGE_RUN_LIVE_AGY_TESTS"] == "1" else {
            throw XCTSkip("CLAUDEUSAGE_RUN_LIVE_AGY_TESTS=1 is required")
        }
        let home = FileManager.default.realHomeDirectory
        let resolution = AntigravityProductionExecutableCatalogResolver(homeDirectoryURL: home).resolve()
        let executable = try XCTUnwrap(
            resolution.reportExecutable, "A verified official AGY CLI is required")
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeUsage-live-agy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let workspace = AntigravityCLIReportWorkspace.url(in: stateDirectory)
        let source = AntigravityCLIUsageReportSource(
            executable: executable,
            executableRevalidator: resolution.catalog,
            environment: AntigravityCLIReportEnvironment.values(homeDirectory: home),
            prepareWorkingDirectory: { try AntigravityCLIReportWorkspace.prepare(at: workspace) }
        )

        let deadline = AntigravityRPCDeadline(totalTimeout: AntigravityRPCDeadline.defaultRefreshTimeout)
        let response: AntigravityUsageSourceResponse
        do {
            response = try await source.fetch(.init(generation: 1, deadline: deadline))
        } catch {
            throw LiveAGYIntegrationTestError.report(String(reflecting: error))
        }
        guard case .grouped(let snapshot) = response.payload else {
            return XCTFail("Expected real grouped quota")
        }
        let quotaDiagnostics = snapshot.lanes.map { lane in
            "\(lane.id.rawValue)=\(lane.remainingFraction.map { String($0) } ?? "nil")"
        }.joined(separator: ",")
        Swift.print("LIVE_AGY_QUOTAS \(quotaDiagnostics)")

        XCTAssertEqual(snapshot.provenance.transport, .cliUsageReport)
        XCTAssertEqual(snapshot.provenance.endpointOwner, .managed)
        XCTAssertEqual(snapshot.provenance.capability, .groupedQuotaSummary)
        XCTAssertNil(snapshot.provenance.processIdentity)
        XCTAssertNil(snapshot.identity)
        assertNumericQuotaForEachGroup(in: snapshot)
        assertNoChildProcess(running: executable.canonicalURL)

        let presentation = AntigravityQuotaPresentationMapper.map(
            snapshot: snapshot, settings: .default, now: snapshot.fetchedAt, timeZone: .current)
        for expectedGroup in ["Gemini", "Claude · GPT"] {
            let group = try XCTUnwrap(
                presentation.groups.first { $0.title == expectedGroup },
                "Expected \(expectedGroup) in the live AGY presentation")
            XCTAssertFalse(group.lanes.isEmpty)
            XCTAssertTrue(group.lanes.allSatisfy { ["5시간", "주간"].contains($0.cadenceTitle) })
        }

        // The CLI target reads only the report, through the same coordinator
        // path that production refreshes use.
        let coordinator = AntigravityRefreshCoordinator(sources: [source])
        let automatic = await coordinator.refresh(
            AntigravityRefreshRequest(trigger: .manual, connection: .default))
        switch automatic {
        case .ready(let value), .partial(let value, _):
            XCTAssertEqual(value.provenance.transport, .cliUsageReport)
            assertNumericQuotaForEachGroup(in: value)
        case .failed(let failure), .stale(_, let failure):
            XCTFail("Expected CLI report quota: \(failure.diagnosticCode)")
        case .setupRequired(let reason):
            XCTFail("Expected CLI report quota: setup \(reason)")
        default:
            XCTFail("Expected CLI report quota")
        }
        assertNoChildProcess(running: executable.canonicalURL)
    }

    private func fetchReport(_ environment: AntigravityRuntimeEnvironment) async throws -> AntigravityQuotaSnapshot {
        let deadline = AntigravityRPCDeadline(totalTimeout: .seconds(30))
        let result: Result<AntigravityQuotaSnapshot, Error> = try await environment.withSources(
            forceDiscovery: true, deadline: deadline
        ) { sources in
            do {
                let source = try XCTUnwrap(sources.first { $0.id == .cliReport })
                let response = try await source.fetch(
                    .init(generation: 1, deadline: deadline.beginningDiscoveryNow()))
                guard case .grouped(let snapshot) = response.payload else {
                    throw AntigravityRuntimeFailure.executableChanged
                }
                return .success(snapshot)
            } catch { return .failure(error) }
        }
        return try result.get()
    }

    private func assertNumericQuotaForEachGroup(
        in snapshot: AntigravityQuotaSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for scope in [AntigravityQuotaScope.gemini, .thirdPartyModels] {
            let lanes = snapshot.lanes.filter { $0.scope == scope }
            XCTAssertFalse(lanes.isEmpty, "Expected numeric quota for \(scope)", file: file, line: line)
            XCTAssertTrue(
                lanes.allSatisfy {
                    guard let fraction = $0.remainingFraction else { return false }
                    return fraction.isFinite && (0...1).contains(fraction)
                        && ($0.cadence == .fiveHour || $0.cadence == .weekly)
                }, "Expected supported numeric quota windows", file: file, line: line)
        }
    }

    /// A report must exit with its process group; no AGY child may remain.
    private func assertNoChildProcess(
        running executable: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let path = executable.resolvingSymlinksInPath().standardizedFileURL.path
        var buffer = [pid_t](repeating: 0, count: 4_096)
        let bytes = buffer.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(getpid()), $0.baseAddress, Int32($0.count))
        }
        let children = buffer.prefix(Int(bytes) / MemoryLayout<pid_t>.stride).filter { $0 > 0 }
        let agyChildren = children.filter { child in
            var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(child, &pathBuffer, UInt32(pathBuffer.count)) > 0 else { return false }
            return URL(fileURLWithPath: String(cString: pathBuffer))
                .resolvingSymlinksInPath().standardizedFileURL.path == path
        }
        XCTAssertTrue(agyChildren.isEmpty, "AGY children remained: \(agyChildren)", file: file, line: line)
    }
}

private enum LiveAGYIntegrationTestError: Error {
    case accountSwitch
    case report(String)
}
