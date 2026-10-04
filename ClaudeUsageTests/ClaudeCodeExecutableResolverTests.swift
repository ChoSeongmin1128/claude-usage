import Darwin
import XCTest

@testable import ClaudeUsage

@MainActor
final class ClaudeCodeExecutableResolverTests: XCTestCase {
    func testKnownExecutableAndCachedReadsNeverStartLoginShell() async throws {
        let fixture = try ResolverFixture()
        defer { fixture.remove() }
        let selection = try fixture.selection()
        let counter = LookupCounter()
        let resolver = ClaudeCodeExecutableResolver(
            known: { selection },
            lookup: {
                counter.increment()
                return nil
            })
        for _ in 0..<10 { XCTAssertEqual(resolver.cachedSelection(), selection) }
        let resolved = await resolver.resolve()
        XCTAssertEqual(resolved, selection)
        XCTAssertEqual(counter.count, 0)
    }

    func testConcurrentLookupIsSharedAndPositiveResultIsCached() async throws {
        let fixture = try ResolverFixture()
        defer { fixture.remove() }
        let selection = try fixture.selection()
        let counter = LookupCounter()
        let resolver = ClaudeCodeExecutableResolver(
            known: { nil },
            lookup: {
                counter.increment()
                try? await Task.sleep(for: .milliseconds(20))
                return selection
            })
        XCTAssertNil(resolver.cachedSelection())
        let results = await withTaskGroup(of: ClaudeCodeExecutableSelection?.self) { group in
            for _ in 0..<8 { group.addTask { await resolver.resolve() } }
            var values: [ClaudeCodeExecutableSelection?] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results.count, 8)
        XCTAssertTrue(results.allSatisfy { $0 == selection })
        XCTAssertEqual(resolver.cachedSelection(), selection)
        _ = await resolver.resolve()
        XCTAssertEqual(counter.count, 1)
    }

    func testCancelledWaiterReturnsWithoutCancellingTheSharedLookup() async throws {
        let fixture = try ResolverFixture()
        defer { fixture.remove() }
        let selection = try fixture.selection()
        let counter = LookupCounter()
        let resolver = ClaudeCodeExecutableResolver(
            known: { nil },
            lookup: {
                counter.increment()
                try? await Task.sleep(for: .seconds(1))
                return selection
            })
        let cancelled = Task { await resolver.resolve() }
        let survivor = Task { await resolver.resolve() }
        while counter.count == 0 { try await Task.sleep(for: .milliseconds(1)) }
        let start = ContinuousClock.now
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        XCTAssertNil(cancelledResult)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
        let survivorResult = await survivor.value
        XCTAssertEqual(survivorResult, selection)
        XCTAssertEqual(resolver.cachedSelection(), selection)
        XCTAssertEqual(counter.count, 1)
    }

    func testFailedLookupIsNotRepeatedByRefreshOrRendering() async {
        let counter = LookupCounter()
        let resolver = ClaudeCodeExecutableResolver(
            known: { nil },
            lookup: {
                counter.increment()
                return nil
            })
        for _ in 0..<4 {
            let result = await resolver.resolve()
            XCTAssertNil(result)
            XCTAssertNil(resolver.cachedSelection())
        }
        XCTAssertEqual(counter.count, 1)
    }

    func testDeletedCachedExecutableIsNotExecutedOrProbedAgain() async throws {
        let fixture = try ResolverFixture()
        defer { fixture.remove() }
        let selection = try fixture.selection()
        let counter = LookupCounter()
        let resolver = ClaudeCodeExecutableResolver(
            known: { nil },
            lookup: {
                counter.increment()
                return selection
            })
        _ = await resolver.resolve()
        try FileManager.default.removeItem(at: selection.originalURL)
        XCTAssertNil(resolver.cachedSelection())
        let result = await resolver.resolve()
        XCTAssertNil(result)
        XCTAssertEqual(counter.count, 1)
    }

    func testLoginShellResultRetainsNpmBinPathForInterpreter() async throws {
        let fixture = try ResolverFixture()
        defer { fixture.remove() }
        let bin = fixture.root.appendingPathComponent("node-version/bin")
        let package = fixture.root.appendingPathComponent("node-version/lib/cli.js")
        try fixture.script(at: package, text: "#!/usr/bin/env fixture-node\nignored\n")
        let alias = bin.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: package)
        try fixture.script(
            at: bin.appendingPathComponent("fixture-node"), text: "#!/bin/sh\nprintf interpreter-found\n")
        let output = Data("\(alias.path)\n\0\(bin.path):relative:/usr/bin:/bin\n".utf8)
        let selected = try XCTUnwrap(ClaudeCodeLoginShellLookup.selection(from: output, home: fixture.root))
        XCTAssertEqual(selected.executableURL, package.resolvingSymlinksInPath())
        XCTAssertEqual(selected.searchDirectories.first, bin.path)
        let result = await ExternalCommand.run(
            selected.executableURL, arguments: [],
            environment: ClaudeCodeCLI.environment(
                configDirectory: nil, home: fixture.root, additionalSearchDirectories: selected.searchDirectories),
            currentDirectory: fixture.root, timeout: 1)
        XCTAssertTrue(result?.succeeded == true)
        XCTAssertEqual(result.flatMap { String(data: $0.data, encoding: .utf8) }, "interpreter-found")
    }

    func testAliasStartupNoiseAndWritableCandidateAreRejected() throws {
        let fixture = try ResolverFixture()
        defer { fixture.remove() }
        let selection = try fixture.selection()
        for path in ["claude", "claude is a function", "hello\n\(selection.originalURL.path)"] {
            XCTAssertNil(
                ClaudeCodeLoginShellLookup.selection(
                    from: Data("\(path)\0/usr/bin:/bin\n".utf8), home: fixture.root))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: selection.originalURL.path)
        XCTAssertNil(
            ClaudeCodeLoginShellLookup.selection(
                from: Data("\(selection.originalURL.path)\0/usr/bin:/bin\n".utf8), home: fixture.root))
    }

    func testTimeoutKillsOwnedShellGroupWithinItsBudget() async throws {
        let fixture = try ResolverFixture()
        defer { fixture.remove() }
        let pidFile = fixture.root.appendingPathComponent("child.pid")
        let start = ContinuousClock.now
        let result = await ClaudeCodeLoginShellLookup.run(
            shell: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; /bin/sleep 30 & echo $! > child.pid; wait"],
            environment: ["PATH": "/usr/bin:/bin", "HOME": fixture.root.path], home: fixture.root,
            timeout: .milliseconds(200))
        XCTAssertNil(result)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
        let pid = try XCTUnwrap(
            Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        try? await Task.sleep(for: .milliseconds(50))
        var information = proc_bsdinfo()
        let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &information, Int32(MemoryLayout<proc_bsdinfo>.size))
        XCTAssertTrue(count <= 0 || information.pbi_status == UInt32(SZOMB))
    }

    func testCancellationDoesNotWaitForTheTimeout() async throws {
        let fixture = try ResolverFixture()
        defer { fixture.remove() }
        let task = Task {
            await ClaudeCodeLoginShellLookup.run(
                shell: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "/bin/sleep 30"],
                environment: ["PATH": "/usr/bin:/bin", "HOME": fixture.root.path], home: fixture.root)
        }
        try? await Task.sleep(for: .milliseconds(50))
        let start = ContinuousClock.now
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
    }
}

private nonisolated final class LookupCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

private nonisolated struct ResolverFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeExecutable-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func script(at url: URL, text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func selection() throws -> ClaudeCodeExecutableSelection {
        let executable = root.appendingPathComponent("bin/claude")
        try script(at: executable, text: "#!/bin/sh\nexit 0\n")
        return ClaudeCodeExecutableSelection(
            originalURL: executable, executableURL: executable.resolvingSymlinksInPath(),
            searchDirectories: [executable.deletingLastPathComponent().path])
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
