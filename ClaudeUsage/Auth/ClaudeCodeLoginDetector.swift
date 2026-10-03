import Foundation
import Security

/// Claude Code에 로그인돼 있는지만 본다. 파일 존재와 Keychain 항목의 속성만 확인하고
/// 토큰 값은 읽지 않으므로 확인 창이 뜨지 않는다. 값을 읽는 연결은 사용자가 누를 때 한다.
enum ClaudeCodeLoginDetector {
    nonisolated static func credentialFileExists(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> Bool
    {
        let directory =
            environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.realHomeDirectory.appendingPathComponent(".claude", isDirectory: true)
        return [".credentials.json", "credentials.json"].contains {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    nonisolated static func keychainItemExists(service: String = "Claude Code-credentials") -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    nonisolated static func hasLogin() -> Bool {
        credentialFileExists() || keychainItemExists()
    }
}
