import Foundation
import LocalAuthentication
import Security

protocol ClaudeOAuthCredentialVault: Sendable {
    nonisolated func loadPayload() throws -> String?
    nonisolated func savePayload(_ payload: String) throws
    nonisolated func deletePayload() throws
}

/// ClaudeUsage가 refresh한 Claude Code OAuth credential 전용 저장소.
/// CLI 소유 Keychain 항목과 service/account namespace를 공유하지 않는다.
final class KeychainClaudeOAuthCredentialVault: ClaudeOAuthCredentialVault, @unchecked Sendable {
    nonisolated static let shared = KeychainClaudeOAuthCredentialVault()
    nonisolated static let account = "claude-code-oauth-cache.v2"

    private let keychainStore: ClaudeKeychainStore

    nonisolated init(keychainStore: ClaudeKeychainStore = .shared) {
        self.keychainStore = keychainStore
    }

    nonisolated func loadPayload() throws -> String? {
        try keychainStore.loadString(account: Self.account)
    }

    nonisolated func savePayload(_ payload: String) throws {
        try keychainStore.saveString(payload, account: Self.account)
    }

    nonisolated func deletePayload() throws {
        try keychainStore.delete(account: Self.account)
    }
}

nonisolated enum ClaudeOAuthCredentialMigrationAvailability: Equatable, Sendable {
    case notNeeded
    case available
    case failed(String)
}

nonisolated enum ClaudeOAuthCredentialMigrationResult: Equatable, Sendable {
    case completed
    case completedWithLegacyCleanupFailure
    case cancelled
    case failed(String)
}

nonisolated enum ClaudeOAuthLegacyAccessError: Error, Equatable, Sendable {
    case cancelled
    case status(Int32)
}

protocol ClaudeOAuthLegacyCredentialMigrating: Sendable {
    nonisolated func availability(
        destination: any ClaudeOAuthCredentialVault
    ) -> ClaudeOAuthCredentialMigrationAvailability

    nonisolated func migrate(
        destination: any ClaudeOAuthCredentialVault
    ) -> ClaudeOAuthCredentialMigrationResult
}

/// v2.3.0 이전 빌드가 잘못된 ACL로 만든 캐시를 명시적 사용자 동의 뒤 한 번만 옮긴다.
/// 읽기와 삭제에 같은 LAContext를 사용해 인증을 반복하지 않는다.
nonisolated final class SecurityFrameworkClaudeOAuthLegacyCredentialMigrator:
    ClaudeOAuthLegacyCredentialMigrating,
    @unchecked Sendable
{
    nonisolated static let legacyService = "ClaudeUsage.Claude Code-credentials-refreshed"
    typealias LegacyPayloadLoader = (LAContext) throws -> String?
    typealias LegacyPayloadDeleter = (LAContext) throws -> Void

    private let account: String
    private let preflightChecker: @Sendable (String, String?) -> KeychainAccessPreflight.Outcome
    private let legacyPayloadLoader: LegacyPayloadLoader
    private let legacyPayloadDeleter: LegacyPayloadDeleter

    nonisolated init(
        account: String = NSUserName(),
        preflightChecker: @escaping @Sendable (String, String?) -> KeychainAccessPreflight.Outcome = {
            KeychainAccessPreflight.checkGenericPassword(service: $0, account: $1)
        },
        legacyPayloadLoader: LegacyPayloadLoader? = nil,
        legacyPayloadDeleter: LegacyPayloadDeleter? = nil
    ) {
        self.account = account
        self.preflightChecker = preflightChecker
        self.legacyPayloadLoader = legacyPayloadLoader ?? { context in
            try Self.loadLegacyPayload(account: account, authenticationContext: context)
        }
        self.legacyPayloadDeleter = legacyPayloadDeleter ?? { context in
            try Self.deleteLegacyPayload(account: account, authenticationContext: context)
        }
    }

    nonisolated func availability(
        destination: any ClaudeOAuthCredentialVault
    ) -> ClaudeOAuthCredentialMigrationAvailability {
        do {
            if try destination.loadPayload() != nil {
                return .notNeeded
            }
        } catch {
            return .failed("새 OAuth 저장소 상태를 확인하지 못했습니다.")
        }

        switch preflightChecker(Self.legacyService, account) {
        case .allowed, .interactionRequired:
            return .available
        case .notFound:
            return .notNeeded
        case .failure:
            return .failed("기존 OAuth 캐시 상태를 확인하지 못했습니다.")
        }
    }

    nonisolated func migrate(
        destination: any ClaudeOAuthCredentialVault
    ) -> ClaudeOAuthCredentialMigrationResult {
        let context = LAContext()
        context.localizedReason = "ClaudeUsage의 기존 Claude OAuth 캐시를 안전한 저장소로 이전합니다."

        let payload: String
        do {
            guard let loaded = try legacyPayloadLoader(context), !loaded.isEmpty else {
                return .failed("이전할 OAuth 캐시를 찾지 못했습니다. Claude Code에 다시 로그인해 주세요.")
            }
            payload = loaded
        } catch let error as ClaudeOAuthLegacyAccessError {
            switch error {
            case .cancelled:
                return .cancelled
            case .status:
                return .failed("기존 OAuth 캐시를 읽지 못했습니다. Claude Code에 다시 로그인해 주세요.")
            }
        } catch {
            return .failed("기존 OAuth 캐시를 읽지 못했습니다. Claude Code에 다시 로그인해 주세요.")
        }

        do {
            try destination.savePayload(payload)
            guard try destination.loadPayload() == payload else {
                return .failed("새 OAuth 저장소의 저장 결과를 검증하지 못했습니다.")
            }
        } catch {
            return .failed("새 OAuth 저장소에 캐시를 저장하지 못했습니다.")
        }

        do {
            try legacyPayloadDeleter(context)
            return .completed
        } catch {
            // 새 vault가 검증된 뒤이므로 정상 사용은 가능하다. 이후 reader는 legacy를 다시 읽지 않는다.
            return .completedWithLegacyCleanupFailure
        }
    }

    private nonisolated static func loadLegacyPayload(
        account: String,
        authenticationContext: LAContext
    ) throws -> String? {
        var query = baseLegacyQuery(account: account, authenticationContext: authenticationContext)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecUserCanceled, errSecAuthFailed:
            throw ClaudeOAuthLegacyAccessError.cancelled
        case errSecItemNotFound:
            return nil
        default:
            throw ClaudeOAuthLegacyAccessError.status(status)
        }
    }

    private nonisolated static func deleteLegacyPayload(
        account: String,
        authenticationContext: LAContext
    ) throws {
        let status = SecItemDelete(
            baseLegacyQuery(account: account, authenticationContext: authenticationContext) as CFDictionary
        )
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw ClaudeOAuthLegacyAccessError.status(status)
        }
    }

    private nonisolated static func baseLegacyQuery(
        account: String,
        authenticationContext: LAContext
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.legacyService,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: authenticationContext,
        ]
    }
}

nonisolated enum ClaudeOAuthCredentialMigrationState: Equatable, Sendable {
    case checking
    case notNeeded
    case available
    case deferred
    case migrating
    case completed
    case completedWithLegacyCleanupFailure
    case failed(String)
}

actor ClaudeOAuthCredentialMigrationCoordinator {
    static let shared = ClaudeOAuthCredentialMigrationCoordinator()

    private let destination: any ClaudeOAuthCredentialVault
    private let migrator: any ClaudeOAuthLegacyCredentialMigrating
    private var state: ClaudeOAuthCredentialMigrationState = .checking
    private var migrationTask: Task<ClaudeOAuthCredentialMigrationState, Never>?

    init(
        destination: any ClaudeOAuthCredentialVault = KeychainClaudeOAuthCredentialVault.shared,
        migrator: any ClaudeOAuthLegacyCredentialMigrating = SecurityFrameworkClaudeOAuthLegacyCredentialMigrator()
    ) {
        self.destination = destination
        self.migrator = migrator
    }

    func inspect() -> ClaudeOAuthCredentialMigrationState {
        if state == .deferred || state == .completed || state == .completedWithLegacyCleanupFailure {
            return state
        }

        switch migrator.availability(destination: destination) {
        case .notNeeded:
            state = .notNeeded
        case .available:
            state = .available
        case .failed(let message):
            state = .failed(message)
        }
        return state
    }

    func deferForCurrentSession() -> ClaudeOAuthCredentialMigrationState {
        guard state != .completed, state != .completedWithLegacyCleanupFailure else { return state }
        state = .deferred
        return state
    }

    func migrate() async -> ClaudeOAuthCredentialMigrationState {
        if state == .deferred || state == .completed || state == .completedWithLegacyCleanupFailure {
            return state
        }
        if let migrationTask {
            return await migrationTask.value
        }

        state = .migrating
        let destination = self.destination
        let migrator = self.migrator
        let task: Task<ClaudeOAuthCredentialMigrationState, Never> = Task.detached(priority: .userInitiated) {
            switch migrator.migrate(destination: destination) {
            case .completed:
                return .completed
            case .completedWithLegacyCleanupFailure:
                return .completedWithLegacyCleanupFailure
            case .cancelled:
                return .deferred
            case .failed(let message):
                return .failed(message)
            }
        }
        migrationTask = task
        let result = await task.value
        migrationTask = nil
        state = result
        return result
    }
}
