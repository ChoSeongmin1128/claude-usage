import Foundation

nonisolated struct AntigravityOAuthAccount: Codable, Identifiable, Sendable, Equatable {
    let id: String
    var label: String
    var email: String?
    var credentials: AntigravityOAuthCredentials
    var createdAtMilliseconds: Double
    var updatedAtMilliseconds: Double

    var updatedAt: Date {
        Date(timeIntervalSince1970: updatedAtMilliseconds / 1000)
    }
}

nonisolated struct AntigravityOAuthAccountState: Codable, Sendable, Equatable {
    var accounts: [AntigravityOAuthAccount]
    var activeAccountID: String?

    var activeAccount: AntigravityOAuthAccount? {
        guard let activeAccountID else { return nil }
        return accounts.first(where: { $0.id == activeAccountID })
    }
}

nonisolated struct AntigravityOAuthAccountStore: @unchecked Sendable {
    let fileURL: URL
    private let fileManager: FileManager
    private let activeCredentialStore: AntigravityOAuthCredentialsStore

    init(
        fileURL: URL = Self.defaultURL(),
        fileManager: FileManager = .default,
        activeCredentialStore: AntigravityOAuthCredentialsStore = AntigravityOAuthCredentialsStore()
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.activeCredentialStore = activeCredentialStore
    }

    func state() -> AntigravityOAuthAccountState {
        normalized(loadRawState())
    }

    @discardableResult
    func syncActiveCredentialIfNeeded() throws -> AntigravityOAuthAccountState {
        do {
            if let credentials = try activeCredentialStore.load(), credentials.hasTokenMaterial {
                return try upsert(credentials, makeActive: true)
            }
        } catch {
            let state = self.state()
            if let active = state.activeAccount {
                try activeCredentialStore.save(active.credentials)
                return state
            }
            throw error
        }

        let state = self.state()
        if let active = state.activeAccount {
            try activeCredentialStore.save(active.credentials)
        }
        return state
    }

    @discardableResult
    func upsert(_ credentials: AntigravityOAuthCredentials, makeActive: Bool) throws -> AntigravityOAuthAccountState {
        guard credentials.hasTokenMaterial else {
            return state()
        }

        var state = self.state()
        let now = Date().timeIntervalSince1970 * 1000
        let email = credentials.email?.trimmedNonEmpty
        let accountID = accountID(for: credentials, email: email, in: state)
        let label = email ?? "Google 계정 \(state.accounts.count + 1)"

        if let index = state.accounts.firstIndex(where: { $0.id == accountID }) {
            state.accounts[index].label = label
            state.accounts[index].email = email
            state.accounts[index].credentials = credentials
            state.accounts[index].updatedAtMilliseconds = now
        } else {
            state.accounts.append(AntigravityOAuthAccount(
                id: accountID,
                label: label,
                email: email,
                credentials: credentials,
                createdAtMilliseconds: now,
                updatedAtMilliseconds: now
            ))
        }

        if makeActive || state.activeAccountID == nil {
            state.activeAccountID = accountID
            try activeCredentialStore.save(credentials)
        }

        try save(state)
        return state
    }

    @discardableResult
    func setActiveAccountID(_ id: String) throws -> AntigravityOAuthAccountState {
        var state = self.state()
        guard let account = state.accounts.first(where: { $0.id == id }) else {
            return state
        }
        state.activeAccountID = account.id
        try activeCredentialStore.save(account.credentials)
        try save(state)
        return state
    }

    @discardableResult
    func deleteAccount(id: String) throws -> AntigravityOAuthAccountState {
        var state = self.state()
        let removedActiveAccount = state.activeAccountID == id
        state.accounts.removeAll { $0.id == id }
        if removedActiveAccount {
            state.activeAccountID = state.accounts.first?.id
            if let active = state.activeAccount {
                try activeCredentialStore.save(active.credentials)
            } else {
                try activeCredentialStore.deleteIfPresent()
            }
        }
        try save(state)
        return state
    }

    @discardableResult
    func deleteAll() throws -> AntigravityOAuthAccountState {
        try activeCredentialStore.deleteIfPresent()
        let state = AntigravityOAuthAccountState(accounts: [], activeAccountID: nil)
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
        return state
    }

    static func defaultURL(home: URL = FileManager.default.realHomeDirectory) -> URL {
        AntigravityOAuthCredentialsStore.defaultDirectoryURL(home: home)
            .appendingPathComponent("oauth_accounts.json")
    }

    private func loadRawState() -> AntigravityOAuthAccountState {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(AntigravityOAuthAccountState.self, from: data)
        else {
            return AntigravityOAuthAccountState(accounts: [], activeAccountID: nil)
        }
        return state
    }

    private func save(_ state: AntigravityOAuthAccountState) throws {
        let state = normalized(state)
        let directory = fileURL.deletingLastPathComponent()
        try AntigravityOAuthFileStorage.ensurePrivateDirectory(at: directory, fileManager: fileManager)
        let data = try JSONEncoder.antigravityAccountState.encode(state)
        try data.write(to: fileURL, options: [.atomic])
        AntigravityOAuthFileStorage.applyCredentialFilePermissions(at: fileURL, fileManager: fileManager)
    }

    private func normalized(_ state: AntigravityOAuthAccountState) -> AntigravityOAuthAccountState {
        var seen: Set<String> = []
        let accounts = state.accounts.filter { account in
            guard !seen.contains(account.id), account.credentials.hasTokenMaterial else { return false }
            seen.insert(account.id)
            return true
        }
        let activeID = state.activeAccountID.flatMap { id in
            accounts.contains(where: { $0.id == id }) ? id : nil
        } ?? accounts.first?.id
        return AntigravityOAuthAccountState(accounts: accounts, activeAccountID: activeID)
    }

    private func accountID(
        for credentials: AntigravityOAuthCredentials,
        email: String?,
        in state: AntigravityOAuthAccountState
    ) -> String {
        if let existing = existingAccountID(forEmail: email, in: state.accounts) {
            return existing
        }
        if let refreshToken = credentials.refreshToken?.trimmedNonEmpty,
           let existing = state.accounts.first(where: {
               $0.credentials.refreshToken?.trimmedNonEmpty == refreshToken
           }) {
            return existing.id
        }
        if email == nil,
           let activeID = state.activeAccountID,
           state.accounts.contains(where: { $0.id == activeID })
        {
            return activeID
        }
        return email.map(Self.accountID(forEmail:))
            ?? "google-\(UUID().uuidString.lowercased())"
    }

    private func existingAccountID(forEmail email: String?, in accounts: [AntigravityOAuthAccount]) -> String? {
        guard let email else { return nil }
        return accounts.first { account in
            account.email?.caseInsensitiveCompare(email) == .orderedSame
        }?.id
    }

    private static func accountID(forEmail email: String) -> String {
        let lowered = email.lowercased()
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return "-"
        }
        let compact = String(scalars)
            .split(separator: "-")
            .joined(separator: "-")
        return "google-\(compact.isEmpty ? UUID().uuidString.lowercased() : compact)"
    }
}

extension JSONEncoder {
    nonisolated fileprivate static var antigravityAccountState: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension String {
    nonisolated var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
