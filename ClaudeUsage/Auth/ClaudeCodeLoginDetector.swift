import Foundation

/// Claude Code에 로그인돼 있는지만 본다. 파일 존재와 Keychain 항목의 속성만 `/usr/bin/security`로 확인하고
/// 토큰 값은 읽지 않으므로 확인 창이 뜨지 않는다. 값을 읽는 연결은 사용자가 누를 때 한다.
enum ClaudeCodeLoginDetector {
    nonisolated static func credentialFileExists(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> Bool
    {
        let directory =
            environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.realHomeDirectory.appendingPathComponent(".claude", isDirectory: true)
        return ClaudeCodeCredentialReader.credentialFileNames.contains {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    nonisolated static func keychainItemExists(
        service: String = ClaudeCodeCredentialReader.defaultKeychainService
    ) async -> Bool {
        await ClaudeCodeKeychainCLI.itemExists(service: service) == true
    }

    nonisolated static func hasLogin() async -> Bool {
        if credentialFileExists() { return true }
        return await keychainItemExists()
    }
}
