import Darwin
import Foundation
import Security

nonisolated enum AntigravityLegacyKeychainListing: Equatable, Sendable {
    case accounts([String])
    case failed(OSStatus)
}

nonisolated enum AntigravityLegacyFileRemoval: Equatable, Sendable {
    case removed
    case absent
    case failed(Int32)
}

/// 값은 읽지 않는다. 목록은 속성만 받고, 삭제는 service와 account를 정확히 지정한다.
nonisolated protocol AntigravityLegacyAccountKeychainCleaning: Sendable {
    func accounts(service: String) -> AntigravityLegacyKeychainListing
    func delete(service: String, account: String) -> OSStatus
}

nonisolated protocol AntigravityLegacyAccountFileCleaning: Sendable {
    func removeFile(at url: URL) -> AntigravityLegacyFileRemoval
    func removeDirectoryIfEmpty(at url: URL)
}

nonisolated enum AntigravityLegacyAccountCleanupResult: Equatable, Sendable {
    case cleaned
    case deferred
}

// 2.5.1 전 버전이 보관한 Antigravity Google OAuth 계정과 그 이전 기록을 지운다.
// 지금은 AGY CLI 로그인만 쓰므로 값을 읽거나 옮기지 않고, 확인 창 없이 지우지 못한 항목은 다음 실행에 다시 시도한다.
nonisolated struct AntigravityLegacyAccountCleanup: Sendable {
    static let vaultAccountPrefix = "oauth.antigravity.v2."
    static let legacyKeychainAccounts = [
        "antigravity-oauth-credentials",
        "claudeusage.antigravity.oauth.v2.quarantine",
    ]
    static let legacyCredentialFileNames = [
        "oauth_accounts.json",
        "oauth_creds.json",
        "oauth_metadata.json",
    ]
    static let quarantineFilePrefix = ".claudeusage-v2-quarantine-"
    static let stateFileNames = [
        "accounts.json",
        "account-operation.json",
        "credential-migration-v2.json",
    ]
    static let migrationMarkerFileName = "antigravity-credentials-v2.json"

    let vaultService: String
    let legacyKeychainServices: [String]
    let legacyCredentialDirectory: URL
    let stateDirectory: URL
    let migrationsDirectory: URL
    let keychain: any AntigravityLegacyAccountKeychainCleaning
    let files: any AntigravityLegacyAccountFileCleaning

    var fileTargets: [URL] {
        let credentialFiles = Self.legacyCredentialFileNames.flatMap { name in
            [
                legacyCredentialDirectory.appendingPathComponent(name),
                legacyCredentialDirectory.appendingPathComponent(Self.quarantineFilePrefix + name),
            ]
        }
        return credentialFiles
            + Self.stateFileNames.map { stateDirectory.appendingPathComponent($0) }
            + [migrationsDirectory.appendingPathComponent(Self.migrationMarkerFileName)]
    }

    @discardableResult
    func run() -> AntigravityLegacyAccountCleanupResult {
        var deferred: [String] = []
        // 비밀이 든 Keychain 항목부터 지운다. 중간에 멈춰도 비밀 없이 메타데이터만 남는다.
        switch keychain.accounts(service: vaultService) {
        case .accounts(let accounts):
            for account in accounts.filter(Self.isVaultAccount).sorted() {
                deleteKeychainItem(service: vaultService, account: account, deferred: &deferred)
            }
        case .failed(let status):
            deferred.append("keychain.list:\(status)")
        }
        for service in legacyKeychainServices {
            for account in Self.legacyKeychainAccounts {
                deleteKeychainItem(service: service, account: account, deferred: &deferred)
            }
        }
        for url in fileTargets {
            if case .failed(let code) = files.removeFile(at: url) {
                deferred.append("file.\(url.lastPathComponent):\(code)")
            }
        }
        files.removeDirectoryIfEmpty(at: migrationsDirectory)
        guard deferred.isEmpty else {
            Logger.warning(
                "[Antigravity] 이전 계정 정리를 마치지 못해 다음 실행에 다시 시도합니다: \(deferred.joined(separator: ", "))"
            )
            return .deferred
        }
        return .cleaned
    }

    private func deleteKeychainItem(service: String, account: String, deferred: inout [String]) {
        let status = keychain.delete(service: service, account: account)
        guard status != errSecSuccess, status != errSecItemNotFound else { return }
        // 상호작용 불가, 인증 실패, 다른 서명이 만든 항목(errSecInvalidOwnerEdit)은 확인 창 없이 지울 수 없다.
        deferred.append("keychain.delete:\(status)")
    }

    private static func isVaultAccount(_ account: String) -> Bool {
        account.hasPrefix(vaultAccountPrefix) && account.count > vaultAccountPrefix.count
    }

    static func production(
        homeDirectoryURL: URL = FileManager.default.realHomeDirectory,
        distribution: AppDistributionDescriptor = AppDistribution.current,
        bundleIdentifierService: String = Bundle.main.bundleIdentifier ?? AppIdentifiers.legacyKeychainService
    ) -> Self {
        let ownsProductionLegacyLocations = distribution.ownsProductionLegacyLocations
        // 이전 OAuth 파일은 운영 채널 이름의 폴더에 있었다. staging은 자기 채널 폴더만 본다.
        let legacyFolder =
            ownsProductionLegacyLocations
            ? AppIdentifiers.productionSupportDirectoryName : distribution.applicationSupportDirectoryName
        var legacyServices = [bundleIdentifierService]
        // 이전 공용 Keychain service는 운영 채널의 것이라 staging은 지우지 않는다.
        if ownsProductionLegacyLocations, !legacyServices.contains(AppIdentifiers.legacyKeychainService) {
            legacyServices.append(AppIdentifiers.legacyKeychainService)
        }
        let directoryName = distribution.applicationSupportDirectoryName
        return Self(
            vaultService: bundleIdentifierService,
            legacyKeychainServices: legacyServices,
            legacyCredentialDirectory: AntigravityStoragePaths.canonicalStateDirectoryURL(
                homeDirectoryURL: homeDirectoryURL, directoryName: legacyFolder),
            stateDirectory: AntigravityStoragePaths.canonicalStateDirectoryURL(
                homeDirectoryURL: homeDirectoryURL, directoryName: directoryName),
            migrationsDirectory: AntigravityStoragePaths.applicationSupportDirectoryURL(
                homeDirectoryURL: homeDirectoryURL, directoryName: directoryName
            ).appendingPathComponent("Migrations", isDirectory: true),
            keychain: SystemAntigravityLegacyAccountKeychainCleaner(),
            files: SystemAntigravityLegacyAccountFileCleaner(trustedBaseDirectory: homeDirectoryURL)
        )
    }
}

nonisolated struct SystemAntigravityLegacyAccountKeychainCleaner: AntigravityLegacyAccountKeychainCleaning {
    func accounts(service: String) -> AntigravityLegacyKeychainListing {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(Self.listQuery(service: service) as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            let items = result as? [[String: Any]] ?? (result as? [String: Any]).map { [$0] } ?? []
            return .accounts(items.compactMap { $0[kSecAttrAccount as String] as? String })
        case errSecItemNotFound:
            return .accounts([])
        default:
            return .failed(status)
        }
    }

    func delete(service: String, account: String) -> OSStatus {
        SecItemDelete(Self.deleteQuery(service: service, account: account) as CFDictionary)
    }

    static func listQuery(service: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        KeychainAccessPreflight.applyNoUI(to: &query)
        return query
    }

    static func deleteQuery(service: String, account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        KeychainAccessPreflight.applyNoUI(to: &query)
        return query
    }
}

nonisolated struct SystemAntigravityLegacyAccountFileCleaner: AntigravityLegacyAccountFileCleaning {
    let trustedBaseDirectory: URL

    private enum ParentDirectory {
        case opened(descriptor: Int32, name: String)
        case failed(Int32)
    }

    func removeFile(at url: URL) -> AntigravityLegacyFileRemoval {
        let descriptor: Int32
        let name: String
        switch openParentDirectory(for: url) {
        case .opened(let parent, let leaf):
            descriptor = parent
            name = leaf
        case .failed(let code):
            return code == ENOENT ? .absent : .failed(code)
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
            let code = errno
            return code == ENOENT ? .absent : .failed(code)
        }
        // 링크는 따라가지 않고 링크만 지운다. 이전 버전은 이 이름으로 디렉터리를 만든 적이 없다.
        guard metadata.st_mode & S_IFMT != S_IFDIR else { return .failed(EISDIR) }
        guard unlinkat(descriptor, name, 0) == 0 else {
            let code = errno
            return code == ENOENT ? .absent : .failed(code)
        }
        return .removed
    }

    func removeDirectoryIfEmpty(at url: URL) {
        guard case .opened(let descriptor, let name) = openParentDirectory(for: url) else { return }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
            metadata.st_mode & S_IFMT == S_IFDIR
        else { return }
        _ = unlinkat(descriptor, name, AT_REMOVEDIR)
    }

    private func openParentDirectory(for url: URL) -> ParentDirectory {
        let basePath = trustedBaseDirectory.standardizedFileURL.path
        let prefix = basePath == "/" ? "/" : basePath + "/"
        let path = url.path
        guard url.isFileURL, trustedBaseDirectory.isFileURL,
            !basePath.utf8.contains(0), !path.utf8.contains(0), path.hasPrefix(prefix)
        else { return .failed(EINVAL) }
        let components = path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
            let leaf = components.last
        else { return .failed(EINVAL) }
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        var descriptor = open(basePath, flags)
        guard descriptor >= 0 else { return .failed(errno) }
        // 기준 폴더 아래의 모든 부모를 고정해, 중간 링크나 경로 교체가 삭제를 밖으로 돌리지 못하게 한다.
        for component in components.dropLast() {
            let next = openat(descriptor, String(component), flags)
            guard next >= 0 else {
                let code = errno
                close(descriptor)
                return .failed(code)
            }
            close(descriptor)
            descriptor = next
        }
        return .opened(descriptor: descriptor, name: String(leaf))
    }
}
