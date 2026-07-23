import LocalAuthentication
import XCTest
@testable import ClaudeUsage

final class ClaudeOAuthCredentialMigrationTests: XCTestCase {
    func testSuccessfulMigrationUsesOneContextThenVerifiesAndDeletesLegacyItem() throws {
        let vault = MigrationVaultStub()
        let contextRecorder = MigrationContextRecorder()
        let migrator = SecurityFrameworkClaudeOAuthLegacyCredentialMigrator(
            preflightChecker: { _, _ in .interactionRequired },
            legacyPayloadLoader: { context in
                contextRecorder.recordLoad(context)
                return Self.payload
            },
            legacyPayloadDeleter: { context in
                contextRecorder.recordDelete(context)
            }
        )

        XCTAssertEqual(migrator.availability(destination: vault), .available)
        XCTAssertEqual(migrator.migrate(destination: vault), .completed)
        let migratedPayload = try XCTUnwrap(vault.payload)
        XCTAssertEqual(
            ClaudeOAuthCredentialVaultPayload.ownership(of: migratedPayload),
            .appManaged
        )
        XCTAssertTrue(migratedPayload.contains(#""accessToken":"access""#))
        XCTAssertEqual(vault.saveCount, 1)
        XCTAssertEqual(contextRecorder.deleteCount, 1)
        XCTAssertTrue(contextRecorder.usedSameContext)
    }

    func testCancelledAuthenticationDoesNotWriteOrDeleteLegacyItem() {
        let vault = MigrationVaultStub()
        let deleteCounter = LockedCounter()
        let migrator = SecurityFrameworkClaudeOAuthLegacyCredentialMigrator(
            preflightChecker: { _, _ in .interactionRequired },
            legacyPayloadLoader: { _ in throw ClaudeOAuthLegacyAccessError.cancelled },
            legacyPayloadDeleter: { _ in deleteCounter.increment() }
        )

        XCTAssertEqual(migrator.migrate(destination: vault), .cancelled)
        XCTAssertNil(vault.payload)
        XCTAssertEqual(vault.saveCount, 0)
        XCTAssertEqual(deleteCounter.value, 0)
    }

    func testDestinationFailureKeepsLegacyItem() {
        let vault = MigrationVaultStub(saveError: TestError.expected)
        let deleteCounter = LockedCounter()
        let migrator = SecurityFrameworkClaudeOAuthLegacyCredentialMigrator(
            preflightChecker: { _, _ in .allowed },
            legacyPayloadLoader: { _ in Self.payload },
            legacyPayloadDeleter: { _ in deleteCounter.increment() }
        )

        guard case .failed = migrator.migrate(destination: vault) else {
            return XCTFail("새 vault 저장 실패는 migration 실패여야 합니다")
        }
        XCTAssertEqual(deleteCounter.value, 0)
    }

    func testLegacyDeletionFailureKeepsVerifiedNewVault() {
        let vault = MigrationVaultStub()
        let migrator = SecurityFrameworkClaudeOAuthLegacyCredentialMigrator(
            preflightChecker: { _, _ in .allowed },
            legacyPayloadLoader: { _ in Self.payload },
            legacyPayloadDeleter: { _ in throw ClaudeOAuthLegacyAccessError.status(-1) }
        )

        XCTAssertEqual(migrator.migrate(destination: vault), .completedWithLegacyCleanupFailure)
        let migratedPayload = try? XCTUnwrap(vault.payload)
        XCTAssertEqual(
            migratedPayload.map(ClaudeOAuthCredentialVaultPayload.ownership(of:)),
            .appManaged
        )
    }

    func testInvalidLegacyPayloadIsNotSavedOrDeleted() {
        let vault = MigrationVaultStub()
        let deleteCounter = LockedCounter()
        let migrator = SecurityFrameworkClaudeOAuthLegacyCredentialMigrator(
            preflightChecker: { _, _ in .allowed },
            legacyPayloadLoader: { _ in #"{"notOAuth":true}"# },
            legacyPayloadDeleter: { _ in deleteCounter.increment() }
        )

        guard case .failed = migrator.migrate(destination: vault) else {
            return XCTFail("유효하지 않은 legacy payload는 migration 실패여야 합니다")
        }
        XCTAssertNil(vault.payload)
        XCTAssertEqual(vault.saveCount, 0)
        XCTAssertEqual(deleteCounter.value, 0)
    }

    func testConcurrentMigrationRequestsShareOneOperation() async {
        let vault = MigrationVaultStub()
        let migrator = MigrationMigratorStub(result: .completed, delay: 0.08)
        let coordinator = ClaudeOAuthCredentialMigrationCoordinator(
            destination: vault,
            migrator: migrator
        )

        let states = await withTaskGroup(of: ClaudeOAuthCredentialMigrationState.self) { group in
            for _ in 0..<6 {
                group.addTask { await coordinator.migrate() }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        XCTAssertEqual(states.count, 6)
        XCTAssertTrue(states.allSatisfy { $0 == .completed })
        XCTAssertEqual(migrator.migrateCount, 1)
    }

    func testCancellationDefersForCurrentCoordinatorSessionWithoutReprompt() async {
        let migrator = MigrationMigratorStub(result: .cancelled)
        let coordinator = ClaudeOAuthCredentialMigrationCoordinator(
            destination: MigrationVaultStub(),
            migrator: migrator
        )

        let first = await coordinator.migrate()
        let second = await coordinator.migrate()
        let inspected = await coordinator.inspect()
        XCTAssertEqual(first, .deferred)
        XCTAssertEqual(second, .deferred)
        XCTAssertEqual(inspected, .deferred)
        XCTAssertEqual(migrator.migrateCount, 1)
    }

    private static let payload = #"{"claudeAiOauth":{"accessToken":"access","refreshToken":"refresh"}}"#
}

private enum TestError: Error {
    case expected
}

private final class MigrationVaultStub: ClaudeOAuthCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var storedPayload: String?
    private var recordedSaveCount = 0
    private let saveError: Error?

    init(payload: String? = nil, saveError: Error? = nil) {
        storedPayload = payload
        self.saveError = saveError
    }

    var payload: String? { lock.withLock { storedPayload } }
    var saveCount: Int { lock.withLock { recordedSaveCount } }

    nonisolated func loadPayload() throws -> String? {
        lock.withLock { storedPayload }
    }

    nonisolated func savePayload(_ payload: String) throws {
        if let saveError { throw saveError }
        lock.withLock {
            recordedSaveCount += 1
            storedPayload = payload
        }
    }

    nonisolated func deletePayload() throws {
        lock.withLock { storedPayload = nil }
    }
}

private final class MigrationContextRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var loadContext: ObjectIdentifier?
    private var deleteContext: ObjectIdentifier?
    private var recordedDeleteCount = 0

    var deleteCount: Int { lock.withLock { recordedDeleteCount } }
    var usedSameContext: Bool {
        lock.withLock { loadContext != nil && loadContext == deleteContext }
    }

    func recordLoad(_ context: LAContext) {
        lock.withLock { loadContext = ObjectIdentifier(context) }
    }

    func recordDelete(_ context: LAContext) {
        lock.withLock {
            deleteContext = ObjectIdentifier(context)
            recordedDeleteCount += 1
        }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class MigrationMigratorStub: ClaudeOAuthLegacyCredentialMigrating, @unchecked Sendable {
    private let lock = NSLock()
    private let result: ClaudeOAuthCredentialMigrationResult
    private let delay: TimeInterval
    private var recordedMigrateCount = 0

    init(result: ClaudeOAuthCredentialMigrationResult, delay: TimeInterval = 0) {
        self.result = result
        self.delay = delay
    }

    var migrateCount: Int { lock.withLock { recordedMigrateCount } }

    nonisolated func availability(
        destination: any ClaudeOAuthCredentialVault
    ) -> ClaudeOAuthCredentialMigrationAvailability {
        _ = destination
        return .available
    }

    nonisolated func migrate(
        destination: any ClaudeOAuthCredentialVault
    ) -> ClaudeOAuthCredentialMigrationResult {
        _ = destination
        lock.withLock { recordedMigrateCount += 1 }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return result
    }
}
