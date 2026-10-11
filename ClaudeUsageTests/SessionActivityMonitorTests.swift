import XCTest
@testable import ClaudeUsage

@MainActor
final class SessionActivityMonitorTests: XCTestCase {
    func testDirectoryCreatedAfterLaunchStartsBeingWatched() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let monitor = SessionActivityMonitor()
        monitor.start(directories: [.codex: sessions])
        XCTAssertTrue(monitor.watchingServices.isEmpty)

        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        monitor.watchNewDirectories()
        XCTAssertEqual(monitor.watchingServices, [.codex])

        monitor.stop()
        monitor.watchNewDirectories()
        XCTAssertTrue(monitor.watchingServices.isEmpty, "A stopped monitor does not restart itself")
    }
}
