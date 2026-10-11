import XCTest
import os
@testable import ClaudeUsage

final class ExternalCommandTests: XCTestCase {
    private let shell = URL(fileURLWithPath: "/bin/sh")

    func testReturnsStatusAndOutput() async throws {
        let result = await ExternalCommand.run(
            shell, arguments: ["-c", "echo hello; exit 3"], environment: [:], timeout: 5)
        let output = try XCTUnwrap(result)
        XCTAssertEqual(output.status, 3)
        XCTAssertEqual(String(decoding: output.data, as: UTF8.self), "hello\n")
    }

    func testLargeOutputDoesNotBlockTheCommand() async throws {
        let result = await ExternalCommand.run(
            shell, arguments: ["-c", "head -c 300000 /dev/zero"], environment: [:], timeout: 5)
        let output = try XCTUnwrap(result)
        XCTAssertTrue(output.succeeded)
        XCTAssertEqual(output.data.count, 300_000, "파이프 버퍼보다 큰 출력도 끝까지 읽어야 합니다")
    }

    func testTimeoutStopsTheCommand() async {
        let started = Date()
        let output = await ExternalCommand.run(shell, arguments: ["-c", "sleep 5"], environment: [:], timeout: 0.2)
        XCTAssertNil(output)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testCancellationStopsTheCommand() async {
        let started = Date()
        let shell = shell
        let task = Task {
            await ExternalCommand.run(shell, arguments: ["-c", "sleep 5"], environment: [:], timeout: 10)
        }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let output = await task.value
        XCTAssertNil(output)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testPassesInputThroughStandardInput() async throws {
        let result = await ExternalCommand.run(
            URL(fileURLWithPath: "/bin/cat"), arguments: [], environment: [:], input: Data("secret".utf8), timeout: 5)
        let output = try XCTUnwrap(result)
        XCTAssertEqual(String(decoding: output.data, as: UTF8.self), "secret")
    }

    func testTimeoutAlsoStopsDescendantsThatIgnoreTerm() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = await ExternalCommand.run(
            shell, arguments: ["-c", "trap '' TERM; /bin/sleep 30 & echo $! > child.pid; wait"], environment: [:],
            currentDirectory: directory, timeout: 0.3)
        XCTAssertNil(output)
        let pid = try XCTUnwrap(
            Int32(
                String(contentsOf: directory.appendingPathComponent("child.pid"), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(Self.isAlive(pid), "The whole process group must be stopped")
    }

    func testDescendantsLeftByAFinishedCommandAreStopped() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = await ExternalCommand.run(
            shell, arguments: ["-c", "/bin/sleep 30 > /dev/null & echo $! > child.pid; echo done"], environment: [:],
            currentDirectory: directory, timeout: 5)
        XCTAssertEqual(output.map { String(decoding: $0.data, as: UTF8.self) }, "done\n")
        let pid = try XCTUnwrap(
            Int32(
                String(contentsOf: directory.appendingPathComponent("child.pid"), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(Self.isAlive(pid))
    }

    func testStreamsMergedOutputAndStopsAtTheOutputLimit() async throws {
        let chunks = OSAllocatedUnfairLock(initialState: Data())
        var request = OwnedProcessRun.Request(
            executable: shell, arguments: ["-c", "echo out; echo err >&2"], environment: [:], timeout: 5)
        request.mergesStandardError = true
        request.onOutput = { data in chunks.withLock { $0.append(data) } }
        let result = await ExternalCommand.run(request)
        let merged = try XCTUnwrap(result)
        XCTAssertEqual(String(decoding: merged.data, as: UTF8.self), "out\nerr\n")
        XCTAssertEqual(chunks.withLock { $0 }, merged.data)

        var limited = OwnedProcessRun.Request(
            executable: shell, arguments: ["-c", "head -c 100000 /dev/zero"], environment: [:], timeout: 5)
        limited.maximumOutputBytes = 1_000
        let overflow = await ExternalCommand.run(limited)
        XCTAssertNil(overflow)
    }

    private static func isAlive(_ pid: Int32) -> Bool {
        var information = proc_bsdinfo()
        let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &information, Int32(MemoryLayout<proc_bsdinfo>.size))
        return count > 0 && information.pbi_status != UInt32(SZOMB)
    }

    func testSearchPathKeepsUserLocalAndSystemDirectoriesOnce() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let directories = ExternalCommand.searchDirectories(home: home)
        XCTAssertEqual(directories.first, "/opt/homebrew/bin")
        XCTAssertTrue(directories.contains("/Users/someone/.local/bin"))
        XCTAssertEqual(directories.count, Set(directories).count)
        XCTAssertTrue(directories.contains("/usr/bin") && directories.contains("/bin"))
    }
}
