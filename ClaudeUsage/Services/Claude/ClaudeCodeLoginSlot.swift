import Foundation
import Security

/// Claude Code Keychain 항목 접근. 기본은 `/usr/bin/security`로 확인 창 없이 읽고 쓰며, 그 도구로 못 할 때만
/// 앱이 직접 접근한다(macOS가 암호를 묻는다). 테스트는 실제 Keychain 대신 바꿔 넣는다.
nonisolated struct ClaudeCodeKeychain: Sendable {
    var read: @Sendable (_ service: String) async -> ClaudeCodeKeychainCLI.Outcome
    var update: @Sendable (_ service: String, _ payload: Data) async -> Bool
    var readInteractively: @Sendable (_ service: String, _ reason: String) -> KeychainAccessPreflight.ReadOutcome
    var updateDirectly: @Sendable (_ service: String, _ payload: Data) -> Bool

    static let system = ClaudeCodeKeychain(
        read: { await ClaudeCodeKeychainCLI.read(service: $0) },
        update: { service, payload in
            guard let account = await ClaudeCodeKeychainCLI.accountName(service: service) else { return false }
            return await ClaudeCodeKeychainCLI.update(service: service, account: account, payload: payload)
        },
        readInteractively: { service, reason in
            KeychainAccessPreflight.readGenericPasswordInteractively(
                service: service, account: nil, localizedReason: reason)
        },
        updateDirectly: { service, payload in
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            ]
            return SecItemUpdate(query as CFDictionary, [kSecValueData as String: payload] as CFDictionary)
                == errSecSuccess
        })

    /// Keychain에 항목이 없는 것으로 동작한다.
    static let none = ClaudeCodeKeychain(
        read: { _ in .notFound }, update: { _, _ in false }, readInteractively: { _, _ in .notFound },
        updateDirectly: { _, _ in false })
}

/// Claude Code 로그인 한 벌이 있는 곳: 자격 증명(Keychain 항목 또는 파일)과 `.claude.json`의 계정 정보.
/// 기본 로그인은 `~/.claude`와 홈의 `.claude.json`, 다른 폴더(CLAUDE_CONFIG_DIR)는 그 폴더 안을 쓴다.
nonisolated struct ClaudeCodeLoginSlot: Equatable, Sendable {
    enum CredentialRead: Equatable, Sendable {
        case credential(ClaudeCodeOAuthCredential)
        case needsPermission
        case missing
    }

    struct Snapshot: Equatable, Sendable {
        enum Storage: Equatable, Sendable { case keychain, file(URL) }
        let storage: Storage
        let credential: Data
        let account: Data?
    }

    let configDirectory: URL
    let profileFile: URL
    let keychainService: String
    let isDefault: Bool

    static func defaultSlot(home: URL = FileManager.default.realHomeDirectory) -> Self {
        let directory = home.appendingPathComponent(".claude", isDirectory: true)
        return Self(
            configDirectory: directory, profileFile: home.appendingPathComponent(".claude.json"),
            keychainService: ClaudeCodeCredentialReader.defaultKeychainService, isDefault: true)
    }

    static func folderSlot(_ directory: URL, home: URL = FileManager.default.realHomeDirectory) -> Self {
        Self(
            configDirectory: directory, profileFile: directory.appendingPathComponent(".claude.json"),
            keychainService: ClaudeCodeCredentialReader.keychainServiceName(
                for: directory, homeDirectory: home, usesExplicitConfigDirectory: true),
            isDefault: false)
    }

    /// nil이면 기본 로그인이다.
    static func slot(configDirectory: URL?, home: URL = FileManager.default.realHomeDirectory) -> Self {
        configDirectory.map { folderSlot($0, home: home) } ?? defaultSlot(home: home)
    }

    /// CLI에 넘길 CLAUDE_CONFIG_DIR. 기본 로그인은 넘기지 않는다(넘기면 Keychain 이름이 달라진다).
    var cliConfigDirectory: URL? { isDefault ? nil : configDirectory }

    var credentialFiles: [URL] {
        ClaudeCodeCredentialReader.credentialFileNames.map { configDirectory.appendingPathComponent($0) }
    }

    func identity() -> UsageAccountIdentity? {
        guard let data = try? Data(contentsOf: profileFile),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let account = object["oauthAccount"] as? [String: Any]
        else { return nil }
        return UsageAccountIdentity(
            accountID: account["accountUuid"] as? String, organizationID: account["organizationUuid"] as? String,
            email: account["emailAddress"] as? String, organizationName: account["organizationName"] as? String)
    }

    /// 지금 로그인을 읽는다. 파일과 Keychain이 둘 다 있으면 메뉴바 계정 조회와 같은 기준으로 고른다
    /// (Claude Code는 Keychain만 갱신하고 파일은 오래된 채로 둘 수 있다).
    /// interactive가 아니면 macOS 확인 창이 뜰 수 있는 직접 접근은 하지 않는다.
    func currentCredential(interactive: Bool, keychain: ClaudeCodeKeychain = .system) async -> CredentialRead {
        let file = credentialFiles.lazy.compactMap { url -> ClaudeCodeOAuthCredential? in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return ClaudeCodeCredentialReader.parseCredential(from: text, source: .file(url))
        }.first
        let stored: ClaudeCodeOAuthCredential?
        switch await keychain.read(keychainService) {
        case .payload(let payload):
            stored = parseKeychain(payload)
        case .notFound:
            stored = nil
        case .failed:
            guard interactive else { return file.map(CredentialRead.credential) ?? .needsPermission }
            switch keychain.readInteractively(keychainService, "다른 Claude Code 계정의 사용량을 확인합니다.") {
            case .value(let payload): stored = parseKeychain(payload)
            case .interactionRequired, .cancelled: return file.map(CredentialRead.credential) ?? .needsPermission
            case .notFound, .invalidData, .failure: stored = nil
            }
        }
        if let stored, ClaudeCodeCredentialReader.shouldPreferKeychainCredential(stored, over: file) {
            return .credential(stored)
        }
        return file.map(CredentialRead.credential) ?? .missing
    }

    private func parseKeychain(_ payload: String) -> ClaudeCodeOAuthCredential? {
        ClaudeCodeCredentialReader.parseCredential(from: payload, source: .keychain(service: keychainService))
    }

    // MARK: - 전환

    /// 사용자가 전환을 누른 뒤에만 부른다. `security`로 못 읽으면 macOS 확인 창을 거쳐 읽는다.
    func readSnapshot(keychain: ClaudeCodeKeychain = .system) async throws -> Snapshot {
        let account = Self.oauthAccount(in: profileFile)
        switch await keychain.read(keychainService) {
        case .payload(let payload):
            return Snapshot(storage: .keychain, credential: Data(payload.utf8), account: account)
        case .notFound:
            break
        case .failed:
            switch keychain.readInteractively(keychainService, "Claude Code 기본 로그인을 전환합니다.") {
            case .value(let payload):
                return Snapshot(storage: .keychain, credential: Data(payload.utf8), account: account)
            case .cancelled:
                throw AccountSwitchError.cancelled
            case .notFound, .interactionRequired, .invalidData, .failure:
                break
            }
        }
        for file in credentialFiles {
            if let data = try? Data(contentsOf: file) {
                return Snapshot(storage: .file(file), credential: data, account: account)
            }
        }
        throw AccountSwitchError.unavailable
    }

    /// previous는 이 자리에 지금 있는 값이다. 원래 저장 방식을 지켜 Keychain에 있던 로그인은 Keychain에,
    /// 파일이던 로그인은 같은 파일에 쓴다. 프로필을 쓰지 못하면 자격 증명을 previous로 되돌려 둘이 어긋나지 않게 한다.
    func write(
        credential: Data, account: Data?, over previous: Snapshot, keychain: ClaudeCodeKeychain = .system
    ) async throws {
        try await writeCredential(credential, storage: previous.storage, keychain: keychain)
        do {
            try Self.replaceOAuthAccount(in: profileFile, with: account)
        } catch {
            try? await writeCredential(previous.credential, storage: previous.storage, keychain: keychain)
            throw error
        }
    }

    private func writeCredential(
        _ credential: Data, storage: Snapshot.Storage, keychain: ClaudeCodeKeychain
    ) async throws {
        switch storage {
        case .keychain:
            if await keychain.update(keychainService, credential) { break }
            guard keychain.updateDirectly(keychainService, credential) else { throw AccountSwitchError.writeFailed }
        case .file(let original):
            let file =
                original.deletingLastPathComponent() == configDirectory
                ? original : configDirectory.appendingPathComponent(original.lastPathComponent)
            do {
                try Self.writePrivately(credential, to: file)
            } catch {
                throw AccountSwitchError.writeFailed
            }
        }
    }

    /// 권한을 0600으로 만든 임시 파일에 쓴 뒤 바꿔 넣는다. 쓰는 동안에도 다른 사용자가 읽을 수 없다.
    static func writePrivately(_ data: Data, to file: URL) throws {
        let temporary = file.deletingLastPathComponent()
            .appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString).tmp")
        guard
            FileManager.default.createFile(
                atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            guard rename(temporary.path, file.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    static func oauthAccount(in file: URL) -> Data? {
        guard let data = try? Data(contentsOf: file),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let account = object["oauthAccount"]
        else { return nil }
        return try? JSONSerialization.data(withJSONObject: account)
    }

    /// `.claude.json`의 다른 설정과 파일 권한은 그대로 두고 `oauthAccount`만 바꾼다.
    static func replaceOAuthAccount(in file: URL, with account: Data?) throws {
        guard let data = try? Data(contentsOf: file),
            var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            if account == nil { return }
            throw AccountSwitchError.writeFailed
        }
        object["oauthAccount"] = account.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        let permissions = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.posixPermissions]
        guard
            let output = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes])
        else {
            throw AccountSwitchError.writeFailed
        }
        do {
            try output.write(to: file, options: .atomic)
            if let permissions {
                try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
            }
        } catch {
            throw AccountSwitchError.writeFailed
        }
    }
}
