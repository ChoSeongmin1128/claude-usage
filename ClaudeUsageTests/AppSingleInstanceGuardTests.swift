import XCTest
@testable import ClaudeUsage

final class AppSingleInstanceGuardTests: XCTestCase {
    func testOnlyOneGuardCanHoldChannelLock() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeUsage-instance-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = AppSingleInstanceGuard()
        let second = AppSingleInstanceGuard()
        XCTAssertEqual(first.acquire(applicationSupportDirectoryURL: directory), .acquired)
        XCTAssertEqual(second.acquire(applicationSupportDirectoryURL: directory), .alreadyRunning)

        let lockURL = directory.appendingPathComponent(AppSingleInstanceGuard.lockFileName)
        let attributes = try FileManager.default.attributesOfItem(atPath: lockURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)

        first.release()
        XCTAssertEqual(second.acquire(applicationSupportDirectoryURL: directory), .acquired)
        second.release()
    }

    func testDifferentChannelDirectoriesCanEachHoldOneLock() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeUsage-channel-instance-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let production = AppSingleInstanceGuard()
        let staging = AppSingleInstanceGuard()
        XCTAssertEqual(
            production.acquire(applicationSupportDirectoryURL: root.appendingPathComponent("ClaudeUsage")),
            .acquired
        )
        XCTAssertEqual(
            staging.acquire(applicationSupportDirectoryURL: root.appendingPathComponent("ClaudeUsage-stg")),
            .acquired
        )
    }
}
