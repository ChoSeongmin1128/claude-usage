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
                homeDirectoryURL: home,
                directoryName: "ClaudeUsage"
            ).path,
            "/Users/example/Library/Application Support/ClaudeUsage"
        )
        XCTAssertEqual(
            AntigravityStoragePaths.canonicalStateDirectoryURL(
                homeDirectoryURL: home,
                directoryName: "ClaudeUsage"
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
                homeDirectoryURL: home,
                directoryName: "ClaudeUsage"
            ).path,
            "/Users/example/Library/Application Support/ClaudeUsage/Antigravity"
        )
    }

    func testStagingStateAndSharedLaunchLockUseSeparateRoots() {
        let home = URL(
            fileURLWithPath: "/Users/example",
            isDirectory: true
        )

        XCTAssertEqual(
            AntigravityStoragePaths
                .canonicalStateDirectoryURL(
                    homeDirectoryURL: home,
                    directoryName:
                        "ClaudeUsage-stg"
                ).path,
            "/Users/example/Library/Application Support/ClaudeUsage-stg/Antigravity"
        )
        XCTAssertEqual(
            AntigravityStoragePaths
                .managedLaunchCoordinationDirectoryURL(
                    homeDirectoryURL: home
                ).path,
            "/Users/example/Library/Application Support/ClaudeUsageShared/Antigravity"
        )
    }
}
