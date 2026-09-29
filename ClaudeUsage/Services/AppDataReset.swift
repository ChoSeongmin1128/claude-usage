import Foundation
import Security
import ServiceManagement
import UserNotifications

nonisolated struct AppDataResetPlan: Equatable, Sendable {
    let keepsClaudeCodeTokenCopy: Bool

    static func prepare(
        reader: ClaudeCodeCredentialReader = ClaudeCodeCredentialReader()
    ) async -> Self {
        Self(keepsClaudeCodeTokenCopy: !(await reader.canDiscardAppVaultCopy()))
    }

    // The token may rotate while the confirmation is open, so the check runs
    // again once refreshes have stopped. A later check only turns discard into keep.
    func rechecked(
        reader: ClaudeCodeCredentialReader = ClaudeCodeCredentialReader()
    ) async -> Self {
        keepsClaudeCodeTokenCopy ? self : await Self.prepare(reader: reader)
    }
}

// The reset runs after termination has shut every service down, so nothing
// writes the removed data back before the process exits.
enum AppDataResetRequest {
    static var pending: AppDataResetPlan?
}

// Everything this channel stored under its own bundle identifier and directory
// name. Other products' files and credentials, the other channel, and the
// notification permission kept by the system are never touched.
nonisolated struct AppDataReset: Sendable {
    let bundleIdentifier: String
    let directoryName: String
    let libraryDirectory: URL
    let keychainAccounts: @Sendable (_ service: String) -> [String]
    let deleteKeychainItem: @Sendable (_ service: String, _ account: String) -> Void
    let unregisterLoginItem: @Sendable () -> Void
    let removeNotifications: @Sendable () -> Void
    let removeDefaults: @Sendable (_ domain: String) -> Void

    var storageLocations: [URL] {
        let library = libraryDirectory
        return [
            library.appendingPathComponent("Application Support/\(directoryName)", isDirectory: true),
            library.appendingPathComponent("Logs/\(directoryName)", isDirectory: true),
            library.appendingPathComponent("Caches/\(bundleIdentifier)", isDirectory: true),
            library.appendingPathComponent("HTTPStorages/\(bundleIdentifier)", isDirectory: true),
            library.appendingPathComponent("HTTPStorages/\(bundleIdentifier).binarycookies"),
            library.appendingPathComponent("WebKit/\(bundleIdentifier)", isDirectory: true),
            library.appendingPathComponent("Saved Application State/\(bundleIdentifier).savedState", isDirectory: true),
            // 1.x ran in the App Sandbox and kept its data in these two.
            library.appendingPathComponent("Containers/\(bundleIdentifier)", isDirectory: true),
            library.appendingPathComponent("Application Scripts/\(bundleIdentifier)", isDirectory: true),
        ]
    }

    func perform(_ plan: AppDataResetPlan) {
        for account in keychainAccounts(bundleIdentifier)
        where !(plan.keepsClaudeCodeTokenCopy && account == KeychainClaudeOAuthCredentialVault.account) {
            deleteKeychainItem(bundleIdentifier, account)
        }
        unregisterLoginItem()
        removeNotifications()
        for location in storageLocations {
            try? FileManager.default.removeItem(at: location)
        }
        removeDefaults(bundleIdentifier)
    }

    static var production: Self {
        let distribution = AppDistribution.current
        return Self(
            bundleIdentifier: distribution.bundleIdentifier,
            directoryName: distribution.applicationSupportDirectoryName,
            libraryDirectory: FileManager.default.realHomeDirectory
                .appendingPathComponent("Library", isDirectory: true),
            keychainAccounts: keychainAccounts(service:),
            deleteKeychainItem: { service, account in
                SecItemDelete(
                    [
                        kSecClass as String: kSecClassGenericPassword,
                        kSecAttrService as String: service,
                        kSecAttrAccount as String: account,
                    ] as CFDictionary)
            },
            unregisterLoginItem: { try? SMAppService.mainApp.unregister() },
            removeNotifications: {
                let center = UNUserNotificationCenter.current()
                center.removeAllPendingNotificationRequests()
                center.removeAllDeliveredNotifications()
            },
            removeDefaults: { domain in
                UserDefaults.standard.removePersistentDomain(forName: domain)
                // The process exits right after the reset.
                UserDefaults.standard.synchronize()
            }
        )
    }

    private static func keychainAccounts(service: String) -> [String] {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnAttributes as String: true,
            ] as CFDictionary,
            &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}
