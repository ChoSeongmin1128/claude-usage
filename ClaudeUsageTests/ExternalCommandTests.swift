import XCTest
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

    func testSearchPathKeepsUserLocalAndSystemDirectoriesOnce() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let directories = ExternalCommand.searchDirectories(home: home)
        XCTAssertEqual(directories.first, "/opt/homebrew/bin")
        XCTAssertTrue(directories.contains("/Users/someone/.local/bin"))
        XCTAssertEqual(directories.count, Set(directories).count)
        XCTAssertTrue(directories.contains("/usr/bin") && directories.contains("/bin"))
    }
}
