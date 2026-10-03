import XCTest
@testable import ClaudeUsage

final class ClaudeAccountLocalDataTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var directory: URL!

    override func setUpWithError() throws {
        suiteName = "ClaudeAccountLocalDataTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    func testRemovingAnAccountDeletesItsCacheKeysAndMetadataFile() throws {
        seed(accountID: "a1")
        seed(accountID: "a2")

        ClaudeAccountLocalData.remove(accountID: "a1", defaults: defaults, directory: directory)

        XCTAssertNil(defaults.object(forKey: "ClaudeUsage.authPathHealth.v1.a1"))
        XCTAssertNil(defaults.object(forKey: "ClaudeUsage.cachedOrganizations.v1.a1"))
        XCTAssertFalse(fileExists("claude-profile-metadata.a1.json"))
        XCTAssertNotNil(defaults.object(forKey: "ClaudeUsage.cachedOrganizations.v1.a2"))
        XCTAssertTrue(fileExists("claude-profile-metadata.a2.json"))
    }

    func testOrphanCleanupKeepsCurrentAccountsAndUnscopedData() throws {
        seed(accountID: "kept")
        seed(accountID: "deleted-earlier")
        defaults.set(Data(), forKey: "ClaudeUsage.authPathHealth.v1.ephemeral")
        try Data("{}".utf8).write(to: directory.appendingPathComponent("claude-profile-metadata.json"))
        try Data().write(to: directory.appendingPathComponent("unrelated.json"))

        ClaudeAccountLocalData.removeOrphans(keeping: ["kept"], defaults: defaults, directory: directory)

        XCTAssertNil(defaults.object(forKey: "ClaudeUsage.authPathHealth.v1.deleted-earlier"))
        XCTAssertFalse(fileExists("claude-profile-metadata.deleted-earlier.json"))
        XCTAssertNotNil(defaults.object(forKey: "ClaudeUsage.authPathHealth.v1.kept"))
        XCTAssertNotNil(defaults.object(forKey: "ClaudeUsage.authPathHealth.v1.ephemeral"))
        XCTAssertTrue(fileExists("claude-profile-metadata.kept.json"))
        XCTAssertTrue(fileExists("claude-profile-metadata.json"))
        XCTAssertTrue(fileExists("unrelated.json"))
    }

    private func seed(accountID: String) {
        defaults.set(Data(), forKey: "ClaudeUsage.authPathHealth.v1.\(accountID)")
        defaults.set(Data(), forKey: "ClaudeUsage.cachedOrganizations.v1.\(accountID)")
        FileManager.default.createFile(
            atPath: ClaudeAccountLocalData.metadataFileURL(accountID: accountID, directory: directory).path,
            contents: Data("{}".utf8))
    }

    private func fileExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
    }
}
