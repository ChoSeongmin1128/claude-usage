import Darwin
import XCTest
@testable import ClaudeUsage

final class AntigravityCLIUsageReportSourceTests: XCTestCase {
    // MARK: - Successful reports

    func testReportRunsVersionThenUsageWithFixedArgumentsAndEnvironment() async throws {
        let runner = ScriptedReportRunner(outcomes: [
            .success(output("1.2.12\n")),
            .success(output(try fixture("agy-1.2.12-print-usage-five-hour-and-weekly.json"))),
        ])
        let workspace = URL(fileURLWithPath: "/private/tmp/report-workspace")
        let fetchedAt = Date(timeIntervalSince1970: 1_900_000_000)
        let source = makeSource(runner: runner, workspace: workspace, now: { fetchedAt })

        let response = try await source.fetch(request())

        let requests = await runner.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].arguments, ["--version"])
        XCTAssertEqual(Array(requests[1].arguments.prefix(4)), ["-p", "/usage", "--output-format", "json"])
        XCTAssertEqual(requests[1].arguments[4], "--print-timeout")
        XCTAssertEqual(requests.map(\.environment), Array(repeating: Self.environment, count: 2))
        XCTAssertEqual(requests.map(\.workingDirectoryURL), [workspace, workspace])
        XCTAssertEqual(requests.map(\.executable), [Self.executable, Self.executable])

        guard case .grouped(let snapshot) = response.payload else {
            return XCTFail("Expected grouped quota")
        }
        XCTAssertEqual(
            snapshot.lanes.map(\.id),
            [
                .geminiWeekly, .geminiFiveHour, .thirdPartyWeekly, .thirdPartyFiveHour,
            ])
        XCTAssertNil(snapshot.identity)
        XCTAssertNil(snapshot.plan)
        XCTAssertEqual(snapshot.fetchedAt, fetchedAt)
        XCTAssertEqual(
            snapshot.provenance,
            AntigravityQuotaProvenance(
                transport: .cliUsageReport, endpointOwner: .managed, accountIdentity: nil,
                capability: .groupedQuotaSummary, processIdentity: nil)
        )
    }

    func testIdentityFreeCLIReportCanCompleteWelcomeVerification() async throws {
        let runner = ScriptedReportRunner(outcomes: [
            .success(output("1.2.12\n")),
            .success(output(try fixture("agy-1.2.12-print-usage-five-hour-and-weekly.json"))),
        ])
        let fetchedAt = Date(timeIntervalSince1970: 1_900_000_000)
        let response = try await makeSource(runner: runner, now: { fetchedAt }).fetch(request())
        guard case .grouped(let quota) = response.payload else { return XCTFail("Expected current CLI quota") }
        XCTAssertNil(quota.identity)
        XCTAssertNil(quota.provenance.accountIdentity)
        let runtime = AntigravityRuntimeSnapshot(
            readiness: .ready, settings: .init(connection: .default, display: .default),
            presentationState: .ready(quota),
            quotaPresentation: .content(
                AntigravityQuotaPresentationMapper.map(snapshot: quota, settings: .default, now: fetchedAt)),
            managedRuntimeAvailability: .available(displayPath: "fixture/agy"),
            lastAttemptAt: fetchedAt, lastSuccessfulAt: fetchedAt)
        await MainActor.run {
            let facade = AppRuntimeStateFacade()
            facade.antigravityRuntimeSnapshot = runtime
            XCTAssertEqual(
                WelcomeServiceStatus.resolve(
                    snapshot: facade.snapshot(for: .antigravity, codexAuthenticated: false), antigravity: runtime),
                .verified)
        }
    }

    func testPrintTimeoutLeavesMarginInsideTheRefreshBudget() async throws {
        let runner = ScriptedReportRunner(outcomes: [
            .success(output("1.2.12")),
            .success(output(try fixture("agy-1.2.12-print-usage-weekly-only.json"))),
        ])

        _ = try await makeSource(runner: runner).fetch(request(timeout: .seconds(30)))

        let requests = await runner.requests
        let report = try XCTUnwrap(requests.last)
        let printTimeout = try XCTUnwrap(
            Int(report.arguments[5].dropLast()), "Expected an integer number of seconds")
        XCTAssertEqual(report.arguments[5].last, "s")
        XCTAssertLessThanOrEqual(printTimeout, 28)
        XCTAssertGreaterThanOrEqual(printTimeout, 20)
        XCTAssertLessThanOrEqual(report.timeout, .seconds(30))
        XCTAssertGreaterThan(report.timeout, .seconds(printTimeout))
    }

    func testSupportedVersionIsCheckedOncePerSource() async throws {
        let report = output(try fixture("agy-1.2.12-print-usage-weekly-only.json"))
        let runner = ScriptedReportRunner(outcomes: [
            .success(output(AntigravityCLIVersion.minimumUsageReport.description)), .success(report), .success(report),
        ])
        let source = makeSource(runner: runner)

        _ = try await source.fetch(request())
        _ = try await source.fetch(request())

        let arguments = await runner.requests.map(\.arguments)
        XCTAssertEqual(arguments.filter { $0 == ["--version"] }.count, 1)
        XCTAssertEqual(arguments.count, 3)
    }

    // MARK: - Version gate

    func testOldAGYNeverReceivesTheUsagePrompt() async throws {
        for versionOutput in ["1.1.10", "1.0.99", "agy version unknown", ""] {
            let runner = ScriptedReportRunner(outcomes: [.success(output(versionOutput))])
            let source = makeSource(runner: runner)

            await assertFetchError(source, .runtimeUnavailable(.unsupportedVersion))
            await assertFetchError(source, .runtimeUnavailable(.unsupportedVersion))

            let arguments = await runner.requests.map(\.arguments)
            XCTAssertEqual(arguments, [["--version"]], "Old or unknown AGY must not be asked for /usage")
        }
    }

    func testFailedVersionProbeIsRetriedInsteadOfCached() async throws {
        let runner = ScriptedReportRunner(outcomes: [
            .success(output("", exitStatus: 1)),
            .success(output("1.2.12")),
            .success(output(try fixture("agy-1.2.12-print-usage-weekly-only.json"))),
        ])
        let source = makeSource(runner: runner)

        await assertFetchError(source, .transportFailure)
        _ = try await source.fetch(request())

        let arguments = await runner.requests.map(\.arguments)
        XCTAssertEqual(arguments.filter { $0 == ["--version"] }.count, 2)
    }

    // MARK: - Report outcomes

    func testModelTurnStopsFurtherReports() async throws {
        let answers = [
            #"{"status":"SUCCESS","num_turns":1,"response":"Your quota..."}"#,
            #"{"status":"SUCCESS","num_turns":0,"usage":{"total_tokens":12},"response":"Your quota..."}"#,
        ]
        for answer in answers {
            let runner = ScriptedReportRunner(outcomes: [.success(output("1.2.12")), .success(output(answer))])
            let source = makeSource(runner: runner)

            await assertFetchError(source, .runtimeUnavailable(.reportDisabled))
            await assertFetchError(source, .runtimeUnavailable(.reportDisabled))

            let runs = await runner.requests.count
            XCTAssertEqual(runs, 2, "A report that may have spent quota must not be repeated")
        }
    }

    func testUnexpectedAnswerWithoutModelTurnIsRetried() async throws {
        let answers = [
            #"{"error":"not signed in"}"#,
            #"{"status":"SUCCESS","num_turns":0,"command":{"name":"quota","data":{}}}"#,
        ]
        for answer in answers {
            let runner = ScriptedReportRunner(outcomes: [
                .success(output("1.2.12")), .success(output(answer)),
                .success(output(try fixture("agy-1.2.12-print-usage-weekly-only.json"))),
            ])
            let source = makeSource(runner: runner)

            await assertFetchError(source, .malformedResponse)
            _ = try await source.fetch(request())
        }
    }

    func testNonSuccessReportIsRetriedOnTheNextRefresh() async throws {
        let failed = output(#"{"status":"ERROR","num_turns":0,"error":"not signed in"}"#, exitStatus: 1)
        let runner = ScriptedReportRunner(outcomes: [
            .success(output("1.2.12")), .success(failed),
            .success(output(try fixture("agy-1.2.12-print-usage-weekly-only.json"))),
        ])
        let source = makeSource(runner: runner)

        await assertFetchError(source, .reportFailed)
        _ = try await source.fetch(request())
    }

    func testUnreadableOutputSeparatesCrashFromFormatChange() async throws {
        let cases: [(AntigravityCLIReportProcessResult, AntigravityUsageSourceError)] = [
            (output("not json", exitStatus: 0), .malformedResponse),
            (output("", exitStatus: 2), .transportFailure),
            (output(#"{"status":"SUCCESS","num_turns":0,"command":{"name":"usage","data":{}}}"#), .malformedResponse),
        ]
        for (result, expected) in cases {
            let runner = ScriptedReportRunner(outcomes: [.success(output("1.2.12")), .success(result)])
            await assertFetchError(makeSource(runner: runner), expected)
        }
    }

    func testRunnerFailuresAreTyped() async throws {
        let cases: [(Error, AntigravityUsageSourceError)] = [
            (AntigravityCLIReportProcessError.timedOut, .reportFailed),
            (AntigravityCLIReportProcessError.executableNotAllowed, .runtimeUnavailable(.executableChanged)),
            (AntigravityCLIReportProcessError.launchFailed, .transportFailure),
            (AntigravityCLIReportProcessError.processGroupInvalid, .transportFailure),
            (AntigravityCLIReportProcessError.outputLimitExceeded, .transportFailure),
            (AntigravityCLIReportProcessError.invalidRequest, .transportFailure),
            (CancellationError(), .cancelled),
        ]
        for (error, expected) in cases {
            let runner = ScriptedReportRunner(outcomes: [.success(output("1.2.12")), .failure(error)])
            await assertFetchError(makeSource(runner: runner), expected)
        }
    }

    func testVersionProbeTimeoutIsNotAReportFailure() async throws {
        let runner = ScriptedReportRunner(outcomes: [.failure(AntigravityCLIReportProcessError.timedOut)])

        await assertFetchError(makeSource(runner: runner), .deadlineExceeded)
    }

    // MARK: - Preconditions

    func testChangedExecutableIsNeverRun() async throws {
        let runner = ScriptedReportRunner(outcomes: [])
        let source = makeSource(runner: runner, isCurrent: false)

        await assertFetchError(source, .runtimeUnavailable(.executableChanged))

        let runs = await runner.requests.count
        XCTAssertEqual(runs, 0)
    }

    func testUnusableWorkspaceIsNeverRunIn() async throws {
        let runner = ScriptedReportRunner(outcomes: [])
        let source = AntigravityCLIUsageReportSource(
            executable: Self.executable,
            executableRevalidator: FixedRevalidator(result: true),
            runner: runner,
            environment: Self.environment,
            prepareWorkingDirectory: { throw AntigravityCLIReportWorkspaceError.notAPrivateDirectory }
        )

        await assertFetchError(source, .transportFailure)

        let runs = await runner.requests.count
        XCTAssertEqual(runs, 0)
    }

    func testTooLittleTimeLeftSkipsTheReport() async throws {
        let runner = ScriptedReportRunner(outcomes: [.success(output("1.2.12"))])

        // 정상 보고(5-8초)보다 print-timeout이 짧아지는 예산이면 보고하지 않는다.
        await assertFetchError(makeSource(runner: runner), .deadlineExceeded, timeout: .seconds(8))

        let arguments = await runner.requests.map(\.arguments)
        XCTAssertEqual(arguments, [["--version"]])
    }

    func testExpiredDeadlineRunsNothing() async throws {
        let runner = ScriptedReportRunner(outcomes: [])

        await assertFetchError(makeSource(runner: runner), .deadlineExceeded, timeout: .zero)

        let runs = await runner.requests.count
        XCTAssertEqual(runs, 0)
    }

    // MARK: - Environment and workspace

    func testReportEnvironmentHidesBrowserAndUserTools() {
        let values = AntigravityCLIReportEnvironment.values(
            homeDirectory: URL(fileURLWithPath: "/Users/test"), userName: "tester")

        XCTAssertEqual(
            values,
            [
                "AGY_CLI_DISABLE_AUTO_UPDATE": "true",
                "HOME": "/Users/test",
                "LANG": "en_US.UTF-8",
                "LC_ALL": "en_US.UTF-8",
                "PATH": "/bin",
                "USER": "tester",
            ])
        XCTAssertFalse(FileManager.default.isExecutableFile(atPath: "/bin/open"))
        XCTAssertNil(AntigravityCLIReportEnvironment.values(userName: "  ")["USER"])
    }

    func testWorkspaceIsCreatedPrivateAndRejectsUnsafeDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIReportWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let created = try AntigravityCLIReportWorkspace.prepare(at: root.appendingPathComponent("new"))
        var metadata = stat()
        XCTAssertEqual(lstat(created.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & 0o777, 0o700)
        XCTAssertEqual(try AntigravityCLIReportWorkspace.prepare(at: created), created)

        let shared = root.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(shared.path, 0o755), 0)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: created)
        let file = root.appendingPathComponent("file")
        try Data().write(to: file)
        XCTAssertEqual(chmod(file.path, 0o600), 0)

        for unsafe in [shared, link, file] {
            XCTAssertThrowsError(try AntigravityCLIReportWorkspace.prepare(at: unsafe)) {
                XCTAssertEqual($0 as? AntigravityCLIReportWorkspaceError, .notAPrivateDirectory)
            }
        }
        XCTAssertThrowsError(
            try AntigravityCLIReportWorkspace.prepare(at: created, expectedUserID: getuid() + 1)
        ) {
            XCTAssertEqual($0 as? AntigravityCLIReportWorkspaceError, .notAPrivateDirectory)
        }
    }

    // MARK: - Helpers

    private static let executable = AntigravityCanonicalExecutable(
        canonicalURL: URL(fileURLWithPath: "/Users/test/.local/bin/agy"), role: .agyCLI)
    private static let environment = ["PATH": "/bin", "HOME": "/Users/test"]

    private func makeSource(
        runner: ScriptedReportRunner,
        isCurrent: Bool = true,
        workspace: URL = URL(fileURLWithPath: "/private/tmp/report-workspace"),
        now: @escaping @Sendable () -> Date = Date.init
    ) -> AntigravityCLIUsageReportSource {
        AntigravityCLIUsageReportSource(
            executable: Self.executable,
            executableRevalidator: FixedRevalidator(result: isCurrent),
            runner: runner,
            environment: Self.environment,
            prepareWorkingDirectory: { workspace },
            now: now
        )
    }

    private func request(timeout: Duration = .seconds(30)) -> AntigravityUsageSourceRequest {
        AntigravityUsageSourceRequest(generation: 1, deadline: AntigravityRPCDeadline(totalTimeout: timeout))
    }

    private func output(_ text: String, exitStatus: Int32 = 0) -> AntigravityCLIReportProcessResult {
        output(Data(text.utf8), exitStatus: exitStatus)
    }

    private func output(_ data: Data, exitStatus: Int32 = 0) -> AntigravityCLIReportProcessResult {
        AntigravityCLIReportProcessResult(standardOutput: data, standardError: Data(), exitStatus: exitStatus)
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/Antigravity/\(name)"))
    }

    private func assertFetchError(
        _ source: AntigravityCLIUsageReportSource,
        _ expected: AntigravityUsageSourceError,
        timeout: Duration = .seconds(30),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await source.fetch(request(timeout: timeout))
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AntigravityUsageSourceError, expected, file: file, line: line)
        }
    }
}

private struct FixedRevalidator: AntigravityExecutableRevalidating {
    let result: Bool

    func isCurrent(_ executable: AntigravityCanonicalExecutable) -> Bool {
        result
    }
}

private actor ScriptedReportRunner: AntigravityCLIReportProcessRunning {
    private var outcomes: [Result<AntigravityCLIReportProcessResult, Error>]
    private(set) var requests: [AntigravityCLIReportProcessRequest] = []

    init(outcomes: [Result<AntigravityCLIReportProcessResult, Error>]) {
        self.outcomes = outcomes
    }

    func run(
        _ request: AntigravityCLIReportProcessRequest
    ) async throws -> AntigravityCLIReportProcessResult {
        requests.append(request)
        guard !outcomes.isEmpty else {
            throw AntigravityCLIReportProcessError.launchFailed
        }
        return try outcomes.removeFirst().get()
    }
}
