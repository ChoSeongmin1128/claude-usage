import Foundation
import Security

enum ClaudeKeychainStoreError: Error, LocalizedError, Sendable {
    case invalidValue
    case itemNotFound
    case duplicateItem
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidValue:
            return "유효하지 않은 값입니다."
        case .itemNotFound:
            return "키체인 항목을 찾을 수 없습니다."
        case .duplicateItem:
            return "키체인 항목이 이미 존재합니다."
        case .unexpectedStatus(let status):
            return "키체인 오류: \(status)"
        }
    }
}

final class ClaudeKeychainStore: @unchecked Sendable {
    nonisolated static let shared = ClaudeKeychainStore()
    nonisolated static let defaultAccount = "claude-session-key"

    private let service = Bundle.main.bundleIdentifier ?? "ClaudeUsage"

    private nonisolated init() {}

    nonisolated static func accountName(for accountID: String) -> String {
        "\(defaultAccount).\(accountID)"
    }

    nonisolated func saveString(_ value: String, account: String = ClaudeKeychainStore.defaultAccount) throws {
        guard !value.isEmpty else {
            throw ClaudeKeychainStoreError.invalidValue
        }

        let data = Data(value.utf8)
        let query = self.baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, [
            kSecValueData as String: data,
        ] as CFDictionary)

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw ClaudeKeychainStoreError.unexpectedStatus(addStatus)
            }
        default:
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            switch addStatus {
            case errSecSuccess:
                return
            case errSecDuplicateItem:
                let retryStatus = SecItemUpdate(query as CFDictionary, [
                kSecValueData as String: data,
            ] as CFDictionary)
                guard retryStatus == errSecSuccess else {
                    throw ClaudeKeychainStoreError.unexpectedStatus(retryStatus)
                }
            default:
                throw ClaudeKeychainStoreError.unexpectedStatus(addStatus)
            }
        }
    }

    nonisolated func loadString(account: String = ClaudeKeychainStore.defaultAccount) throws -> String? {
        var query = self.baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw ClaudeKeychainStoreError.unexpectedStatus(status)
        }
    }

    nonisolated func delete(account: String = ClaudeKeychainStore.defaultAccount) throws {
        let status = SecItemDelete(self.baseQuery(account: account) as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw ClaudeKeychainStoreError.unexpectedStatus(status)
        }
    }

    private nonisolated func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: account,
        ]
    }
}

extension ClaudeKeychainStore: ClaudeSessionKeyVault {}
