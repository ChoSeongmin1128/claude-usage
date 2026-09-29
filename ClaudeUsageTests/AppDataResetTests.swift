import XCTest
@testable import ClaudeUsage

final class AppDataResetTests: XCTestCase {
    private static let bundleIdentifier = "com.example.ClaudeUsage.reset-test"
    private static let directoryName = "ClaudeUsage-reset-test"

    private var library: URL!

    override func setUpWithError() throws {
        library = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDataResetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: library)
    }

    func testResetRemovesEverythingThisChannelStored() throws {
        let keychain = KeychainStub(accounts: [
            "claude-session-key.account", KeychainClaudeOAuthCredentialVault.account, "oauth.antigravity.v2.id",
        ])
        let recorder = SystemRecorder()
        let reset = makeReset(keychain: keychain, recorder: recorder)
        try createAll(reset.storageLocations)
        let untouched = [
            "Application Support/ClaudeUsage",
            "Application Support/ClaudeUsageShared",
            "Caches/com.example.ClaudeUsage",
            "Application Support/Claude",
        ].map { library.appendingPathComponent($0, isDirectory: true) }
        try createAll(untouched)

        reset.perform(AppDataResetPlan(keepsClaudeCodeTokenCopy: false))

        for location in reset.storageLocations {
            XCTAssertFalse(FileManager.default.fileExists(atPath: location.path), location.path)
        }
        for location in untouched {
            XCTAssertTrue(FileManager.default.fileExists(atPath: location.path), location.path)
        }
        XCTAssertEqual(Set(keychain.deleted.map(\.account)), Set(keychain.accounts))
        XCTAssertEqual(Set(keychain.deleted.map(\.service)), [Self.bundleIdentifier])
        XCTAssertEqual(recorder.events, ["login-item", "notifications", "defaults:\(Self.bundleIdentifier)"])
    }

    func testResetKeepsTheClaudeCodeTokenCopyWhenThePlanSaysSo() {
        let keychain = KeychainStub(accounts: [
            "claude-session-key.account", KeychainClaudeOAuthCredentialVault.account,
        ])
        let reset = makeReset(keychain: keychain, recorder: SystemRecorder())

        reset.perform(AppDataResetPlan(keepsClaudeCodeTokenCopy: true))

        XCTAssertEqual(keychain.deleted.map(\.account), ["claude-session-key.account"])
    }

    func testLaterCheckCanOnlyKeepTheTokenCopy() async {
        let rotated = VaultStub(payload: #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"only-copy"}}"#)
        let unreadableClaudeCode = ClaudeCodeCredentialReader(
            homeDirectory: library,
            appCredentialVault: rotated,
            keychainPayloadReaderWithoutUI: { _, _ in .interactionRequired }
        )

        let discard = await AppDataResetPlan(keepsClaudeCodeTokenCopy: false).rechecked(reader: unreadableClaudeCode)
        let keep = await AppDataResetPlan(keepsClaudeCodeTokenCopy: true).rechecked(reader: unreadableClaudeCode)

        XCTAssertTrue(discard.keepsClaudeCodeTokenCopy)
        XCTAssertTrue(keep.keepsClaudeCodeTokenCopy)
        XCTAssertEqual(rotated.loadCount, 1)
    }

    func testEveryLocationBelongsToThisChannel() {
        let reset = makeReset(keychain: KeychainStub(accounts: []), recorder: SystemRecorder())

        for location in reset.storageLocations {
            XCTAssertTrue(location.path.hasPrefix(library.path + "/"), location.path)
            XCTAssertTrue(
                location.lastPathComponent.hasPrefix(Self.bundleIdentifier)
                    || location.lastPathComponent == Self.directoryName,
                location.path)
        }
    }

    private func makeReset(keychain: KeychainStub, recorder: SystemRecorder) -> AppDataReset {
        AppDataReset(
            bundleIdentifier: Self.bundleIdentifier,
            directoryName: Self.directoryName,
            libraryDirectory: library,
            keychainAccounts: { service in service == Self.bundleIdentifier ? keychain.accounts : [] },
            deleteKeychainItem: { service, account in keychain.delete(service: service, account: account) },
            unregisterLoginItem: { recorder.record("login-item") },
            removeNotifications: { recorder.record("notifications") },
            removeDefaults: { domain in recorder.record("defaults:\(domain)") }
        )
    }

    private func createAll(_ locations: [URL]) throws {
        for location in locations {
            if location.pathExtension == "binarycookies" {
                try FileManager.default.createDirectory(
                    at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: location.path, contents: Data())
            } else {
                try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: location.appendingPathComponent("item").path, contents: Data())
            }
        }
    }
}

private final class VaultStub: ClaudeOAuthCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private let payload: String?
    private var loads = 0

    init(payload: String?) {
        self.payload = payload
    }

    var loadCount: Int { lock.withLock { loads } }

    func loadPayload() throws -> String? {
        lock.withLock { loads += 1 }
        return payload
    }

    func savePayload(_ payload: String) throws {}

    func deletePayload() throws {}
}

private final class KeychainStub: @unchecked Sendable {
    struct Item: Equatable {
        let service: String
        let account: String
    }

    let accounts: [String]
    private let lock = NSLock()
    private var deletedItems: [Item] = []

    init(accounts: [String]) {
        self.accounts = accounts
    }

    var deleted: [Item] { lock.withLock { deletedItems } }

    func delete(service: String, account: String) {
        lock.withLock { deletedItems.append(Item(service: service, account: account)) }
    }
}

private final class SystemRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var events: [String] { lock.withLock { recorded } }

    func record(_ event: String) {
        lock.withLock { recorded.append(event) }
    }
}
