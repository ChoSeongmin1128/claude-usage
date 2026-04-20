import Foundation
import LocalAuthentication
import Security

enum KeychainAccessPreflight {
    enum Outcome {
        case allowed
        case interactionRequired
        case notFound
        case failure(Int)
    }

    nonisolated static func checkGenericPassword(service: String, account: String?) -> Outcome {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        if let account {
            query[kSecAttrAccount as String] = account
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return .allowed
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed:
            return .interactionRequired
        default:
            return .failure(Int(status))
        }
    }
}
