import Darwin
import Foundation
import LocalAuthentication
import Security

enum KeychainAccessPreflight {
    private nonisolated static let authenticationUIFailPolicy =
        resolveAuthenticationUIFailPolicy()

    enum Outcome: Sendable {
        case allowed
        case interactionRequired
        case notFound
        case failure(Int)
    }

    enum ReadOutcome: Equatable, Sendable {
        case value(String)
        case notFound
        case interactionRequired
        case cancelled
        case invalidData
        case failure(Int)
    }

    nonisolated static func checkGenericPassword(service: String, account: String?) -> Outcome {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        applyNoUI(to: &query)
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

    /// Reads the actual secret data while explicitly forbidding Keychain UI.
    ///
    /// An attribute-only preflight cannot prove that password data is readable:
    /// classic ACL items may expose attributes and still prompt for `kSecValueData`.
    /// Background credential discovery must use this operation directly.
    nonisolated static func readGenericPasswordWithoutUI(
        service: String,
        account: String?
    ) -> ReadOutcome {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        applyNoUI(to: &query)

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8),
                  !value.isEmpty else {
                return .invalidData
            }
            return .value(value)
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            return .interactionRequired
        default:
            return .failure(Int(status))
        }
    }

    /// Reads one exact Keychain item after an explicit user action. This is the
    /// only Claude CLI credential path allowed to present macOS authentication UI.
    nonisolated static func readGenericPasswordInteractively(
        service: String,
        account: String?,
        localizedReason: String
    ) -> ReadOutcome {
        let context = LAContext()
        context.localizedReason = localizedReason
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8),
                  !value.isEmpty else {
                return .invalidData
            }
            return .value(value)
        case errSecItemNotFound:
            return .notFound
        case errSecUserCanceled, errSecAuthFailed:
            return .cancelled
        case errSecInteractionNotAllowed:
            return .interactionRequired
        default:
            return .failure(Int(status))
        }
    }

    nonisolated static func applyNoUI(to query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        query[kSecUseAuthenticationUI as String] = authenticationUIFailPolicy as CFString
    }

    nonisolated static func authenticationUIFailPolicyForTesting() -> String {
        authenticationUIFailPolicy
    }

    private nonisolated static func resolveAuthenticationUIFailPolicy() -> String {
        let securityPath = "/System/Library/Frameworks/Security.framework/Security"
        guard let handle = dlopen(securityPath, RTLD_NOW) else {
            return "u_AuthUIF"
        }
        defer { dlclose(handle) }

        guard let symbol = dlsym(handle, "kSecUseAuthenticationUIFail") else {
            return "u_AuthUIF"
        }
        let valuePointer = symbol.assumingMemoryBound(to: CFString?.self)
        return (valuePointer.pointee as String?) ?? "u_AuthUIF"
    }
}
