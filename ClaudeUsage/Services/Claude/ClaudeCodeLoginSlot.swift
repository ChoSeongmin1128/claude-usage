import Foundation
import Security

/// Claude Code Keychain 항목 접근. 기본은 `/usr/bin/security`로 확인 창 없이 읽고 쓰며, 그 도구로 못 할 때만
/// 앱이 직접 접근한다(macOS가 암호를 묻는다). 테스트는 실제 Keychain 대신 바꿔 넣는다.
nonisolated struct ClaudeCodeKeychain: Sendable {
    var read: @Sendable (_ service: String) async -> ClaudeCodeKeychainCLI.Outcome
    var update: @Sendable (_ service: String, _ payload: Data) async -> Bool
    var readInteractively: @Sendable (_ service: String, _ reason: String) -> KeychainAccessPreflight.ReadOutcome
    var updateDirectly: @Sendable (_ service: String, _ payload: Data) -> Bool
    /// Claude Code 로그인 항목 이름. 비밀 값은 읽지 않는다. 확인하지 못하면 nil이다.
    var credentialServiceNames: @Sendable () async -> [String]? = { nil }
    var accountName: @Sendable (_ service: String) async -> String? = { _ in nil }
    var readExact: (@Sendable (_ service: String, _ account: String) async -> ClaudeCodeKeychainCLI.Outcome)?
    var updateExact: (@Sendable (_ service: String, _ account: String, _ payload: Data) async -> Bool)?

    static let system = ClaudeCodeKeychain(
        read: { await ClaudeCodeKeychainCLI.read(service: $0) },
        update: { service, payload in
            guard !Task.isCancelled, let account = await ClaudeCodeKeychainCLI.accountName(service: service),
                !Task.isCancelled
            else { return false }
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
        },
        credentialServiceNames: { await ClaudeCodeKeychainCLI.credentialServiceNames() },
        accountName: { await ClaudeCodeKeychainCLI.accountName(service: $0) },
        readExact: { await ClaudeCodeKeychainCLI.read(service: $0, account: $1) },
        updateExact: { await ClaudeCodeKeychainCLI.update(service: $0, account: $1, payload: $2) })

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
        let profile: Data?
        let keychainAccount: String?

        init(storage: Storage, credential: Data, account: Data?, profile: Data? = nil, keychainAccount: String? = nil) {
            self.storage = storage
            self.credential = credential
            self.account = account
            self.profile = profile
            self.keychainAccount = keychainAccount
        }
    }

    /// Keychain 항목을 어떻게 찾았는지. Claude Code는 CLAUDE_CONFIG_DIR 원문으로 항목 이름을 정한다.
    enum KeychainMatch: Equatable, Sendable {
        /// CLAUDE_CONFIG_DIR 없이 실행한 기본 로그인
        case defaultLogin
        /// 이 원문을 CLAUDE_CONFIG_DIR로 준 Claude Code가 쓰는 항목
        case configDirectoryValue(String)
        /// 원문은 모르고 토큰 주인이 이 폴더 계정과 같은 항목. `claude`로 갱신할 수 없고 전환에도 쓰지 않는다.
        case accountOwner
    }

    let configDirectory: URL
    let profileFile: URL
    let keychainService: String
    let keychainMatch: KeychainMatch

    var isDefault: Bool { keychainMatch == .defaultLogin }

    static func defaultSlot(home: URL = FileManager.default.realHomeDirectory) -> Self {
        let directory = home.appendingPathComponent(".claude", isDirectory: true)
        return Self(
            configDirectory: directory, profileFile: home.appendingPathComponent(".claude.json"),
            keychainService: ClaudeCodeCredentialReader.defaultKeychainService, keychainMatch: .defaultLogin)
    }

    /// 경로를 정리한 표기로 계산한 이름. 실제로 쓰인 표기는 `ClaudeCodeFolderKeychain.resolve`가 찾는다.
    static func folderSlot(_ directory: URL, home: URL = FileManager.default.realHomeDirectory) -> Self {
        folderSlot(directory, configDirectoryValue: directory.standardizedFileURL.path)
    }

    static func folderSlot(_ directory: URL, configDirectoryValue: String) -> Self {
        Self(
            configDirectory: directory, profileFile: directory.appendingPathComponent(".claude.json"),
            keychainService: ClaudeCodeCredentialReader.scopedKeychainServiceName(
                configDirectoryValue: configDirectoryValue),
            keychainMatch: .configDirectoryValue(configDirectoryValue))
    }

    /// nil이면 기본 로그인이다.
    static func slot(configDirectory: URL?, home: URL = FileManager.default.realHomeDirectory) -> Self {
        configDirectory.map { folderSlot($0, home: home) } ?? defaultSlot(home: home)
    }

    /// CLI에 넘길 CLAUDE_CONFIG_DIR 원문. 기본 로그인은 넘기지 않는다(넘기면 Keychain 이름이 달라진다).
    var cliConfigDirectoryValue: String? {
        if case .configDirectoryValue(let value) = keychainMatch { return value }
        return nil
    }

    /// `claude`로 이 로그인을 갱신하거나 확인할 수 있는지. 원문을 모르면 다른 항목을 보게 된다.
    var canRunCLI: Bool { keychainMatch != .accountOwner }

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
    func readSnapshot(keychain: ClaudeCodeKeychain = .system, interactive: Bool = true) async throws -> Snapshot {
        try Task.checkCancellation()
        let profile = try CredentialRecoveryFile.read(.file(profileFile))
        let account: Data?
        if let profile {
            guard let object = try? JSONSerialization.jsonObject(with: profile) as? [String: Any] else {
                throw AccountSwitchError.unavailable
            }
            account = try object["oauthAccount"].map { try JSONSerialization.data(withJSONObject: $0) }
        } else {
            account = nil
        }
        switch await keychain.read(keychainService) {
        case .payload(let payload):
            return try await keychainSnapshot(payload, account: account, profile: profile, keychain: keychain)
        case .notFound:
            break
        case .failed:
            try Task.checkCancellation()
            guard interactive else { throw AccountSwitchError.unavailable }
            switch keychain.readInteractively(keychainService, "Claude Code 기본 로그인을 전환합니다.") {
            case .value(let payload):
                return try await keychainSnapshot(payload, account: account, profile: profile, keychain: keychain)
            case .cancelled:
                throw AccountSwitchError.cancelled
            case .notFound: break
            case .interactionRequired, .invalidData, .failure: throw AccountSwitchError.unavailable
            }
        }
        for file in credentialFiles {
            if let data = try CredentialRecoveryFile.read(.file(file)) {
                return Snapshot(storage: .file(file), credential: data, account: account, profile: profile)
            }
        }
        throw AccountSwitchError.unavailable
    }

    private func keychainSnapshot(
        _ payload: String, account: Data?, profile: Data?,
        keychain: ClaudeCodeKeychain
    ) async throws -> Snapshot {
        guard let keychainAccount = await keychain.accountName(keychainService) else {
            throw AccountSwitchError.ownerUnverified
        }
        let latest: ClaudeCodeKeychainCLI.Outcome
        if let readExact = keychain.readExact {
            latest = await readExact(keychainService, keychainAccount)
        } else {
            latest = await keychain.read(keychainService)
        }
        guard latest == .payload(payload) else { throw AccountSwitchError.busy }
        return Snapshot(
            storage: .keychain, credential: Data(payload.utf8), account: account, profile: profile,
            keychainAccount: keychainAccount)
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
            do { try await writeCredential(previous.credential, storage: previous.storage, keychain: keychain) } catch {
                throw AccountSwitchError.rollbackFailed
            }
            throw error
        }
    }

    func recoveryComponents(
        replacing previous: Snapshot, with incoming: Snapshot
    ) throws -> [CredentialRecoverySwitchComponent] {
        let credentialLocation: CredentialRecoveryLocation
        switch previous.storage {
        case .keychain:
            guard let account = previous.keychainAccount else { throw AccountSwitchError.ownerUnverified }
            credentialLocation = .claudeKeychain(keychainService, account: account)
        case .file(let url): credentialLocation = .file(url)
        }
        let proposedProfile: Data?
        if let profile = previous.profile {
            guard var root = try JSONSerialization.jsonObject(with: profile) as? [String: Any] else {
                throw AccountSwitchError.unavailable
            }
            root["oauthAccount"] = try incoming.account.map { try JSONSerialization.jsonObject(with: $0) }
            proposedProfile =
                previous.account == incoming.account
                ? profile
                : try JSONSerialization.data(
                    withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        } else {
            guard incoming.account == nil else { throw AccountSwitchError.writeFailed }
            proposedProfile = nil
        }
        return [
            .init(location: credentialLocation, original: previous.credential, proposed: incoming.credential),
            .init(location: .file(profileFile), original: previous.profile, proposed: proposedProfile),
        ]
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
    /// 링크면 대상 파일을 바꾼다. Claude Code도 링크를 따라가 쓰므로 dotfiles로 관리하는 링크를 끊지 않는다.
    static func writePrivately(_ data: Data, to link: URL) throws {
        let file = link.resolvingSymlinksInPath()
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

    /// `.claude.json`의 다른 설정과 파일 권한은 그대로 두고 `oauthAccount`만 바꾼다. 링크면 대상 파일을 바꾼다.
    static func replaceOAuthAccount(in link: URL, with account: Data?) throws {
        let file = link.resolvingSymlinksInPath()
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
