import XCTest
@testable import ClaudeUsage

final class AntigravityStoragePathsTests: XCTestCase {
    func testCanonicalStateDirectoryUsesApplicationSupportRoot() {
        let home = URL(
            fileURLWithPath: "/Users/example",
            isDirectory: true
        )

        XCTAssertEqual(
            AntigravityStoragePaths.applicationSupportDirectoryURL(
                homeDirectoryURL: home
            ).path,
            "/Users/example/Library/Application Support/ClaudeUsage"
        )
        XCTAssertEqual(
            AntigravityStoragePaths.canonicalStateDirectoryURL(
                homeDirectoryURL: home
            ).path,
            "/Users/example/Library/Application Support/ClaudeUsage/Antigravity"
        )
    }

    func testCanonicalStateDirectoryStandardizesHomeBeforeAppending() {
        let home = URL(
            fileURLWithPath: "/Users/example/work/..",
            isDirectory: true
        )

        XCTAssertEqual(
            AntigravityStoragePaths.canonicalStateDirectoryURL(
                homeDirectoryURL: home
            ).path,
            "/Users/example/Library/Application Support/ClaudeUsage/Antigravity"
        )
    }
}
