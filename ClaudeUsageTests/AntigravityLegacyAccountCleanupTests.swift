import Darwin
import Security
import XCTest
@testable import ClaudeUsage

final class AntigravityLegacyAccountCleanupTests: XCTestCase {
    private static let bundleIdentifier = "com.example.ClaudeUsage.cleanup-test"

    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("AntigravityLegacyAccountCleanupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testSecretsAreDeletedBeforeAnyFile() throws {
        let recorder = CleanupRecorder()
        let keychain = KeychainCleanerStub(
            recorder: recorder,
            listing: .accounts([
                "oauth.antigravity.v2.b", "claude-code-oauth-cache.v2", "oauth.antigravity.v2.a",
                "oauth.antigravity.v2.",
            ]))
        let cleanup = makeCleanup(keychain: keychain, files: FileCleanerStub(recorder: recorder))

        XCTAssertEqual(cleanup.run(), .cleaned)

        let events = recorder.events
        let vault = Self.bundleIdentifier
        XCTAssertEqual(
            Array(events.prefix(7)),
            [
                "list:\(vault)",
                "delete:\(vault)/oauth.antigravity.v2.a",
                "delete:\(vault)/oauth.antigravity.v2.b",
                "delete:\(vault)/antigravity-oauth-credentials",
                "delete:\(vault)/claudeusage.antigravity.oauth.v2.quarantine",
                "delete:ClaudeUsage/antigravity-oauth-credentials",
                "delete:ClaudeUsage/claudeusage.antigravity.oauth.v2.quarantine",
            ])
        let lastKeychain = events.lastIndex { $0.hasPrefix("delete:") || $0.hasPrefix("list:") }
        let firstFile = events.firstIndex { $0.hasPrefix("file:") }
        XCTAssertLessThan(try XCTUnwrap(lastKeychain), try XCTUnwrap(firstFile))
        XCTAssertEqual(events.last, "rmdir:Migrations")
        XCTAssertEqual(
            events.filter { $0.hasPrefix("file:") },
            cleanup.fileTargets.map { "file:" + $0.lastPathComponent })
    }

    func testProductionOwnsTheSharedLegacyServiceOnlyInTheProductionChannel() {
        let production = AntigravityLegacyAccountCleanup.production(
            homeDirectoryURL: home,
            distribution: .resolve(
                releaseChannelValue: "prod", bundleIdentifier: AppIdentifiers.productionBundleIdentifier),
            bundleIdentifierService: AppIdentifiers.productionBundleIdentifier)
        let staging = AntigravityLegacyAccountCleanup.production(
            homeDirectoryURL: home,
            distribution: .resolve(
                releaseChannelValue: "staging", bundleIdentifier: AppIdentifiers.stagingBundleIdentifier),
            bundleIdentifierService: AppIdentifiers.stagingBundleIdentifier)
        let support = home.standardizedFileURL.appendingPathComponent("Library/Application Support", isDirectory: true)

        XCTAssertEqual(
            production.legacyKeychainServices,
            [AppIdentifiers.productionBundleIdentifier, AppIdentifiers.legacyKeychainService])
        XCTAssertEqual(production.vaultService, AppIdentifiers.productionBundleIdentifier)
        XCTAssertEqual(
            production.legacyCredentialDirectory.path,
            support.appendingPathComponent("ClaudeUsage/Antigravity").path)
        XCTAssertEqual(staging.legacyKeychainServices, [AppIdentifiers.stagingBundleIdentifier])
        XCTAssertEqual(staging.vaultService, AppIdentifiers.stagingBundleIdentifier)
        XCTAssertEqual(
            staging.legacyCredentialDirectory.path,
            support.appendingPathComponent("ClaudeUsage-stg/Antigravity").path)
        XCTAssertEqual(
            staging.stateDirectory.path,
            support.appendingPathComponent("ClaudeUsage-stg/Antigravity").path)
        XCTAssertEqual(
            staging.migrationsDirectory.path,
            support.appendingPathComponent("ClaudeUsage-stg/Migrations").path)
        for target in production.fileTargets + staging.fileTargets {
            XCTAssertTrue(target.path.hasPrefix(support.path + "/"), target.path)
        }
    }

    func testSystemQueriesReadAttributesOnlyAndNeverShowUI() {
        let list = SystemAntigravityLegacyAccountKeychainCleaner.listQuery(service: Self.bundleIdentifier)
        let delete = SystemAntigravityLegacyAccountKeychainCleaner.deleteQuery(
            service: Self.bundleIdentifier, account: "antigravity-oauth-credentials")
        let noUIPolicy = KeychainAccessPreflight.authenticationUIFailPolicyForTesting()

        XCTAssertEqual(list[kSecReturnAttributes as String] as? Bool, true)
        for query in [list, delete] {
            XCTAssertNil(query[kSecReturnData as String])
            XCTAssertEqual(query[kSecAttrService as String] as? String, Self.bundleIdentifier)
            XCTAssertEqual(query[kSecUseAuthenticationUI as String] as? String, noUIPolicy)
            XCTAssertNotNil(query[kSecUseAuthenticationContext as String])
        }
        XCTAssertEqual(delete[kSecAttrAccount as String] as? String, "antigravity-oauth-credentials")
    }

    func testKeychainRefusalsAreDeferredWithoutStoppingTheSweep() throws {
        let recorder = CleanupRecorder()
        let keychain = KeychainCleanerStub(
            recorder: recorder,
            listing: .accounts(["oauth.antigravity.v2.a"]),
            statuses: [
                "oauth.antigravity.v2.a": errSecInteractionNotAllowed,
                "antigravity-oauth-credentials": errSecInvalidOwnerEdit,
                "claudeusage.antigravity.oauth.v2.quarantine": errSecAuthFailed,
            ])
        let files = SystemAntigravityLegacyAccountFileCleaner(trustedBaseDirectory: home)
        let cleanup = makeCleanup(keychain: keychain, files: files)
        try createFiles(cleanup.fileTargets)

        XCTAssertEqual(cleanup.run(), .deferred)

        for target in cleanup.fileTargets {
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), target.path)
        }
        XCTAssertEqual(recorder.events.filter { $0.hasPrefix("delete:") }.count, 5)
    }

    func testListingFailureSkipsOnlyTheVault() {
        let recorder = CleanupRecorder()
        let keychain = KeychainCleanerStub(
            recorder: recorder, listing: .failed(errSecInteractionNotAllowed))
        let cleanup = makeCleanup(keychain: keychain, files: FileCleanerStub(recorder: recorder))

        XCTAssertEqual(cleanup.run(), .deferred)

        let events = recorder.events
        XCTAssertFalse(events.contains { $0.contains("oauth.antigravity.v2.") })
        XCTAssertEqual(events.filter { $0.hasPrefix("delete:") }.count, 4)
        XCTAssertEqual(events.filter { $0.hasPrefix("file:") }.count, cleanup.fileTargets.count)
    }

    func testSecondRunFindsNothingLeft() throws {
        let recorder = CleanupRecorder()
        let keychain = KeychainCleanerStub(
            recorder: recorder,
            listing: .accounts(["oauth.antigravity.v2.a"]),
            removesOnDelete: true)
        let cleanup = makeCleanup(
            keychain: keychain, files: SystemAntigravityLegacyAccountFileCleaner(trustedBaseDirectory: home))
        try createFiles(cleanup.fileTargets)

        XCTAssertEqual(cleanup.run(), .cleaned)
        XCTAssertEqual(cleanup.run(), .cleaned)

        let vaultDeletes = recorder.events.filter { $0.hasSuffix("/oauth.antigravity.v2.a") }
        XCTAssertEqual(vaultDeletes.count, 1)
        for target in cleanup.fileTargets {
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), target.path)
        }
    }

    func testAntigravityFolderCLIReportAndManagedLedgerAreKept() throws {
        let cleanup = makeCleanup(
            keychain: KeychainCleanerStub(recorder: CleanupRecorder(), listing: .accounts([])),
            files: SystemAntigravityLegacyAccountFileCleaner(trustedBaseDirectory: home))
        let stateDirectory = cleanup.stateDirectory
        let cliReport = stateDirectory.appendingPathComponent("cli-report", isDirectory: true)
        let ledger = stateDirectory.appendingPathComponent(AntigravityManagedProcessRecordFileStore.fileName)
        try FileManager.default.createDirectory(at: cliReport, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: cliReport.appendingPathComponent("report.json").path, contents: Data())
        FileManager.default.createFile(atPath: ledger.path, contents: Data())
        try createFiles(cleanup.fileTargets)

        XCTAssertEqual(cleanup.run(), .cleaned)

        XCTAssertTrue(FileManager.default.fileExists(atPath: stateDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cliReport.appendingPathComponent("report.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ledger.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleanup.migrationsDirectory.path))
    }

    func testMigrationsFolderWithOtherRecordsIsKept() throws {
        let cleanup = makeCleanup(
            keychain: KeychainCleanerStub(recorder: CleanupRecorder(), listing: .accounts([])),
            files: SystemAntigravityLegacyAccountFileCleaner(trustedBaseDirectory: home))
        try createFiles(cleanup.fileTargets)
        let other = cleanup.migrationsDirectory.appendingPathComponent("other-record.json")
        FileManager.default.createFile(atPath: other.path, contents: Data())

        XCTAssertEqual(cleanup.run(), .cleaned)

        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: cleanup.migrationsDirectory
                    .appendingPathComponent(AntigravityLegacyAccountCleanup.migrationMarkerFileName).path))
    }

    func testLinkedCredentialFileIsRemovedWithoutTouchingItsTarget() throws {
        let cleanup = makeCleanup(
            keychain: KeychainCleanerStub(recorder: CleanupRecorder(), listing: .accounts([])),
            files: SystemAntigravityLegacyAccountFileCleaner(trustedBaseDirectory: home))
        let outside = home.appendingPathComponent("outside.json")
        FileManager.default.createFile(atPath: outside.path, contents: Data("keep".utf8))
        let link = cleanup.legacyCredentialDirectory.appendingPathComponent("oauth_creds.json")
        try FileManager.default.createDirectory(
            at: cleanup.legacyCredentialDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertEqual(cleanup.run(), .cleaned)

        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
        XCTAssertEqual(try Data(contentsOf: outside), Data("keep".utf8))
    }

    func testLinkedAncestorCannotDeleteFilesOutsideTheAppDirectory() throws {
        let cases = [
            ("Library", "Application Support/ClaudeUsage-cleanup-test/Antigravity/oauth_creds.json"),
            ("Library/Application Support", "ClaudeUsage-cleanup-test/Antigravity/oauth_creds.json"),
            ("Library/Application Support/ClaudeUsage-cleanup-test", "Antigravity/oauth_creds.json"),
            ("Library/Application Support/ClaudeUsage-cleanup-test/Antigravity", "oauth_creds.json"),
            ("Library/Application Support/ClaudeUsage-cleanup-test/Migrations", "antigravity-credentials-v2.json"),
        ]
        for (index, paths) in cases.enumerated() {
            let caseHome = home.appendingPathComponent("case-\(index)", isDirectory: true)
            let outside = home.appendingPathComponent("outside-\(index)", isDirectory: true)
            let link = caseHome.appendingPathComponent(paths.0, isDirectory: true)
            let target = outside.appendingPathComponent(paths.1)
            try FileManager.default.createDirectory(
                at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            let cleanup = makeCleanup(
                keychain: KeychainCleanerStub(recorder: CleanupRecorder(), listing: .accounts([])),
                files: SystemAntigravityLegacyAccountFileCleaner(trustedBaseDirectory: caseHome),
                baseDirectory: caseHome)

            XCTAssertEqual(cleanup.run(), .deferred, paths.0)
            XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8), paths.0)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), outside.path)
        }
    }

    func testEmptyDirectoryRemovalRejectsLinkedAncestor() throws {
        let outside = home.appendingPathComponent("outside", isDirectory: true)
        let target = outside.appendingPathComponent("Migrations", isDirectory: true)
        let link = home.appendingPathComponent(
            "Library/Application Support/ClaudeUsage-cleanup-test", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let files = SystemAntigravityLegacyAccountFileCleaner(trustedBaseDirectory: home)

        files.removeDirectoryIfEmpty(at: link.appendingPathComponent("Migrations", isDirectory: true))

        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), outside.path)
    }

    func testEmptyDirectoryRemovalPreservesLeafSymlink() throws {
        let outside = home.appendingPathComponent("outside", isDirectory: true)
        let link = home.appendingPathComponent("Migrations", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let files = SystemAntigravityLegacyAccountFileCleaner(trustedBaseDirectory: home)

        files.removeDirectoryIfEmpty(at: link)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), outside.path)
    }

    func testTargetOutsideTrustedBaseIsRejected() throws {
        let base = home.appendingPathComponent("trusted", isDirectory: true)
        let target = home.appendingPathComponent("outside.json")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: target)
        let files = SystemAntigravityLegacyAccountFileCleaner(trustedBaseDirectory: base)

        XCTAssertEqual(files.removeFile(at: target), .failed(EINVAL))
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
    }

    private func makeCleanup(
        keychain: any AntigravityLegacyAccountKeychainCleaning,
        files: any AntigravityLegacyAccountFileCleaning,
        baseDirectory: URL? = nil
    ) -> AntigravityLegacyAccountCleanup {
        let base = baseDirectory ?? home!
        let support = base.appendingPathComponent(
            "Library/Application Support/ClaudeUsage-cleanup-test", isDirectory: true)
        let antigravity = support.appendingPathComponent("Antigravity", isDirectory: true)
        return AntigravityLegacyAccountCleanup(
            vaultService: Self.bundleIdentifier,
            legacyKeychainServices: [Self.bundleIdentifier, AppIdentifiers.legacyKeychainService],
            legacyCredentialDirectory: antigravity,
            stateDirectory: antigravity,
            migrationsDirectory: support.appendingPathComponent("Migrations", isDirectory: true),
            keychain: keychain,
            files: files
        )
    }

    private func createFiles(_ targets: [URL]) throws {
        for target in targets {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: target.path, contents: Data("{}".utf8))
        }
    }
}

private final class CleanupRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var events: [String] { lock.withLock { recorded } }

    func record(_ event: String) {
        lock.withLock { recorded.append(event) }
    }
}

private final class KeychainCleanerStub: AntigravityLegacyAccountKeychainCleaning, @unchecked Sendable {
    private let lock = NSLock()
    private let recorder: CleanupRecorder
    private var listing: AntigravityLegacyKeychainListing
    private let statuses: [String: OSStatus]
    private let removesOnDelete: Bool

    init(
        recorder: CleanupRecorder,
        listing: AntigravityLegacyKeychainListing,
        statuses: [String: OSStatus] = [:],
        removesOnDelete: Bool = false
    ) {
        self.recorder = recorder
        self.listing = listing
        self.statuses = statuses
        self.removesOnDelete = removesOnDelete
    }

    func accounts(service: String) -> AntigravityLegacyKeychainListing {
        recorder.record("list:\(service)")
        return lock.withLock { listing }
    }

    func delete(service: String, account: String) -> OSStatus {
        recorder.record("delete:\(service)/\(account)")
        if removesOnDelete {
            lock.withLock {
                if case .accounts(let accounts) = listing {
                    listing = .accounts(accounts.filter { $0 != account })
                }
            }
        }
        return statuses[account] ?? errSecItemNotFound
    }
}

private final class FileCleanerStub: AntigravityLegacyAccountFileCleaning, @unchecked Sendable {
    private let recorder: CleanupRecorder

    init(recorder: CleanupRecorder) {
        self.recorder = recorder
    }

    func removeFile(at url: URL) -> AntigravityLegacyFileRemoval {
        recorder.record("file:\(url.lastPathComponent)")
        return .absent
    }

    func removeDirectoryIfEmpty(at url: URL) {
        recorder.record("rmdir:\(url.lastPathComponent)")
    }
}
