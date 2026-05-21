import Foundation
import Darwin
import LocalAuthentication
import Security

nonisolated struct AntigravityOAuthCredentials: Codable, Sendable, Equatable {
    var accessToken: String?
    var refreshToken: String?
    var expiryDateMilliseconds: Double?
    var idToken: String?
    var email: String?
    var projectID: String?
    var clientID: String?
    var clientSecret: String?

    init(
        accessToken: String?,
        refreshToken: String?,
        expiryDate: Date?,
        idToken: String? = nil,
        email: String? = nil,
        projectID: String? = nil,
        clientID: String? = nil,
        clientSecret: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiryDateMilliseconds = expiryDate.map { $0.timeIntervalSince1970 * 1000 }
        self.idToken = idToken
        self.email = email
        self.projectID = projectID
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    var expiryDate: Date? {
        guard let expiryDateMilliseconds else { return nil }
        return Date(timeIntervalSince1970: expiryDateMilliseconds / 1000)
    }

    var hasTokenMaterial: Bool {
        accessToken?.trimmedNonEmpty != nil || refreshToken?.trimmedNonEmpty != nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decodeIfPresent(String.self, forKey: .accessTokenSnake)
            ?? container.decodeIfPresent(String.self, forKey: .accessTokenCamel)
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshTokenSnake)
            ?? container.decodeIfPresent(String.self, forKey: .refreshTokenCamel)
        idToken = try container.decodeIfPresent(String.self, forKey: .idTokenSnake)
            ?? container.decodeIfPresent(String.self, forKey: .idTokenCamel)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        projectID = try container.decodeIfPresent(String.self, forKey: .projectIDSnake)
            ?? container.decodeIfPresent(String.self, forKey: .projectIDCamel)
        clientID = try container.decodeIfPresent(String.self, forKey: .clientIDSnake)
            ?? container.decodeIfPresent(String.self, forKey: .clientIDCamel)
        clientSecret = try container.decodeIfPresent(String.self, forKey: .clientSecretSnake)
            ?? container.decodeIfPresent(String.self, forKey: .clientSecretCamel)

        if let expiry = try container.decodeIfPresent(Double.self, forKey: .expiryDateSnake)
            ?? container.decodeIfPresent(Double.self, forKey: .expiresAtCamel)
        {
            expiryDateMilliseconds = expiry
        } else if let expiry = try container.decodeIfPresent(Int.self, forKey: .expiryDateSnake)
            ?? container.decodeIfPresent(Int.self, forKey: .expiresAtCamel)
        {
            expiryDateMilliseconds = Double(expiry)
        } else {
            expiryDateMilliseconds = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(accessToken, forKey: .accessTokenSnake)
        try container.encodeIfPresent(refreshToken, forKey: .refreshTokenSnake)
        try container.encodeIfPresent(expiryDateMilliseconds, forKey: .expiryDateSnake)
        try container.encodeIfPresent(idToken, forKey: .idTokenSnake)
        try container.encodeIfPresent(email, forKey: .email)
        try container.encodeIfPresent(projectID, forKey: .projectIDSnake)
        try container.encodeIfPresent(clientID, forKey: .clientIDSnake)
        try container.encodeIfPresent(clientSecret, forKey: .clientSecretSnake)
    }

    enum CodingKeys: String, CodingKey {
        case accessTokenSnake = "access_token"
        case accessTokenCamel = "accessToken"
        case refreshTokenSnake = "refresh_token"
        case refreshTokenCamel = "refreshToken"
        case expiryDateSnake = "expiry_date"
        case expiresAtCamel = "expiresAt"
        case idTokenSnake = "id_token"
        case idTokenCamel = "idToken"
        case email
        case projectIDSnake = "project_id"
        case projectIDCamel = "projectId"
        case clientIDSnake = "client_id"
        case clientIDCamel = "clientId"
        case clientSecretSnake = "client_secret"
        case clientSecretCamel = "clientSecret"
    }
}

nonisolated struct AntigravityOAuthClient: Sendable, Equatable {
    let clientID: String
    let clientSecret: String

    /// Antigravity 2.0 bundles multiple Google OAuth client secrets in the
    /// language server binary. The authorization code is tied to clientID, so
    /// token exchange can safely retry alternate secrets for the same client.
    let clientSecretCandidates: [String]

    init(clientID: String, clientSecret: String, clientSecretCandidates: [String]? = nil) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.clientSecretCandidates = Self.uniqueSecrets(clientSecretCandidates ?? [clientSecret], preferred: clientSecret)
    }

    private static func uniqueSecrets(_ values: [String], preferred: String) -> [String] {
        var result: [String] = []
        for value in [preferred] + values {
            guard let secret = value.trimmedNonEmpty, !result.contains(secret) else { continue }
            result.append(secret)
        }
        return result
    }
}

private nonisolated struct AntigravityLegacyOAuthTokenSecrets: Decodable, Sendable, Equatable {
    var accessToken: String?
    var refreshToken: String?
    var idToken: String?

    var hasTokenMaterial: Bool {
        accessToken?.trimmedNonEmpty != nil || refreshToken?.trimmedNonEmpty != nil
    }

    enum CodingKeys: String, CodingKey {
        case accessTokenSnake = "access_token"
        case accessTokenCamel = "accessToken"
        case refreshTokenSnake = "refresh_token"
        case refreshTokenCamel = "refreshToken"
        case idTokenSnake = "id_token"
        case idTokenCamel = "idToken"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decodeIfPresent(String.self, forKey: .accessTokenSnake)
            ?? container.decodeIfPresent(String.self, forKey: .accessTokenCamel)
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshTokenSnake)
            ?? container.decodeIfPresent(String.self, forKey: .refreshTokenCamel)
        idToken = try container.decodeIfPresent(String.self, forKey: .idTokenSnake)
            ?? container.decodeIfPresent(String.self, forKey: .idTokenCamel)
    }
}

private nonisolated struct AntigravityLegacyOAuthCredentialMetadata: Decodable, Sendable, Equatable {
    var expiryDateMilliseconds: Double?
    var email: String?
    var projectID: String?
    var clientID: String?

    enum CodingKeys: String, CodingKey {
        case expiryDateMilliseconds = "expiry_date"
        case email
        case projectID = "project_id"
        case clientID = "client_id"
    }
}

protocol AntigravityLegacyOAuthKeychainStore: Sendable {
    nonisolated func loadStringWithoutAuthenticationPrompt(account: String) throws -> String?
    nonisolated func delete(account: String) throws
}

struct AntigravitySecurityLegacyOAuthKeychainStore: AntigravityLegacyOAuthKeychainStore {
    nonisolated static let shared = AntigravitySecurityLegacyOAuthKeychainStore()

    private let services: [String]

    nonisolated init(service: String = Bundle.main.bundleIdentifier ?? "ClaudeUsage") {
        self.services = Self.uniqueServices([service, "ClaudeUsage"])
    }

    nonisolated func loadStringWithoutAuthenticationPrompt(account: String) throws -> String? {
        var firstError: Error?
        for service in services {
            do {
                if let value = try loadStringWithoutAuthenticationPrompt(account: account, service: service) {
                    return value
                }
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError {
            throw firstError
        }
        return nil
    }

    nonisolated func delete(account: String) throws {
        var firstError: Error?
        for service in services {
            do {
                try delete(account: account, service: service)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError {
            throw firstError
        }
    }

    private nonisolated func loadStringWithoutAuthenticationPrompt(
        account: String,
        service: String
    ) throws -> String? {
        var query = baseQuery(account: account, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        AntigravityLegacyKeychainNoUIQuery.apply(to: &query)

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound, errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            return nil
        default:
            throw ClaudeKeychainStoreError.unexpectedStatus(status)
        }
    }

    private nonisolated func delete(account: String, service: String) throws {
        let status = SecItemDelete(baseQuery(account: account, service: service) as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw ClaudeKeychainStoreError.unexpectedStatus(status)
        }
    }

    private nonisolated func baseQuery(account: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private nonisolated static func uniqueServices(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values {
            guard !value.isEmpty, !result.contains(value) else { continue }
            result.append(value)
        }
        return result
    }
}

private enum AntigravityLegacyKeychainNoUIQuery {
    nonisolated private static let authenticationUIFailValue = resolveAuthenticationUIFailValue()

    nonisolated static func apply(to query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context

        // macOS can still show Allow/Deny dialogs for legacy generic-password
        // items unless the deprecated UI-fail policy is set. Resolve it at
        // runtime so release builds avoid direct deprecated symbol references.
        query[kSecUseAuthenticationUI as String] = authenticationUIFailValue as CFString
    }

    private static func resolveAuthenticationUIFailValue() -> String {
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

private nonisolated final class AntigravityLegacyOAuthMigrationAttempts: @unchecked Sendable {
    static let shared = AntigravityLegacyOAuthMigrationAttempts()

    private let lock = NSLock()
    private var attemptedStorePaths: Set<String> = []

    func claim(storePath: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !attemptedStorePaths.contains(storePath) else { return false }
        attemptedStorePaths.insert(storePath)
        return true
    }
}

nonisolated enum AntigravityOAuthConfig {
    static let authURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    static let userInfoURL = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!
    static let scopes = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
    ]

    static let missingCredentialsMessage =
        "Antigravity OAuth client를 찾지 못했습니다. Antigravity.app을 설치하거나 ANTIGRAVITY_OAUTH_CLIENT_ID/ANTIGRAVITY_OAUTH_CLIENT_SECRET 환경변수를 설정해 주세요."

    static func resolvedClient() -> AntigravityOAuthClient? {
        if let client = environmentClient() {
            return client
        }
        return discoverClientFromInstalledApp()
    }

    private static func environmentClient() -> AntigravityOAuthClient? {
        let env = ProcessInfo.processInfo.environment
        guard let clientID = env["ANTIGRAVITY_OAUTH_CLIENT_ID"]?.trimmedNonEmpty,
              let clientSecret = env["ANTIGRAVITY_OAUTH_CLIENT_SECRET"]?.trimmedNonEmpty
        else {
            return nil
        }
        return AntigravityOAuthClient(clientID: clientID, clientSecret: clientSecret)
    }

    static func discoverClientFromInstalledApp(fileManager: FileManager = .default) -> AntigravityOAuthClient? {
        for url in candidateTextBundleURLs(fileManager: fileManager) where fileManager.fileExists(atPath: url.path) {
            guard let content = try? String(contentsOf: url, encoding: .utf8),
                  let client = parseClient(fromBundleContent: content)
            else {
                continue
            }
            return client
        }
        for url in candidateLanguageServerURLs(fileManager: fileManager) where fileManager.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  let client = parseClient(fromBundleContent: String(decoding: data, as: UTF8.self))
            else {
                continue
            }
            return client
        }
        return nil
    }

    private static func candidateTextBundleURLs(fileManager: FileManager) -> [URL] {
        let relativePath = "Antigravity.app/Contents/Resources/app/out/main.js"
        return [
            URL(fileURLWithPath: "/Applications", isDirectory: true).appendingPathComponent(relativePath),
            fileManager.realHomeDirectory
                .appendingPathComponent("Applications", isDirectory: true)
                .appendingPathComponent(relativePath),
        ]
    }

    private static func candidateLanguageServerURLs(fileManager: FileManager) -> [URL] {
        let relativePath = "Antigravity.app/Contents/Resources/bin/language_server"
        return [
            URL(fileURLWithPath: "/Applications", isDirectory: true).appendingPathComponent(relativePath),
            fileManager.realHomeDirectory
                .appendingPathComponent("Applications", isDirectory: true)
                .appendingPathComponent(relativePath),
        ]
    }

    static func parseClient(fromBundleContent content: String) -> AntigravityOAuthClient? {
        for haystack in clientSearchWindows(in: content) {
            if let client = parseClient(fromSearchWindow: haystack) {
                return client
            }
        }
        return nil
    }

    private static func parseClient(fromSearchWindow haystack: String) -> AntigravityOAuthClient? {
        guard let clientID = uniqueMatches(
            pattern: #"[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com"#,
            in: haystack
        ).first else {
            return nil
        }
        let clientSecrets = uniqueMatches(
            pattern: #"GOCSPX-[A-Za-z0-9_-]+"#,
            in: haystack
        )
        guard let clientSecret = clientSecrets.first else {
            return nil
        }
        return AntigravityOAuthClient(
            clientID: clientID,
            clientSecret: clientSecret,
            clientSecretCandidates: clientSecrets
        )
    }

    private static func clientSearchWindows(in content: String) -> [String] {
        let marker = "vs/platform/cloudCode/common/oauthClient.js"
        guard let markerRange = content.range(of: marker) else {
            return [content]
        }

        let searchStart = markerRange.lowerBound
        let searchEnd = content.index(searchStart, offsetBy: 4000, limitedBy: content.endIndex) ?? content.endIndex
        let focusedWindow = String(content[searchStart..<searchEnd])
        return focusedWindow == content ? [content] : [focusedWindow, content]
    }

    private static func uniqueMatches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var result: [String] = []
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match,
                  let swiftRange = Range(match.range, in: text)
            else {
                return
            }
            let value = String(text[swiftRange])
            guard !result.contains(value) else { return }
            result.append(value)
        }
        return result
    }
}

nonisolated struct AntigravityOAuthCredentialsStore: @unchecked Sendable {
    static let environmentCredentialsKey = "ANTIGRAVITY_OAUTH_CREDENTIALS_JSON"
    static let legacyKeychainAccount = "antigravity-oauth-credentials"

    let fileURL: URL
    private let fileManager: FileManager
    private let legacyKeychainStore: (any AntigravityLegacyOAuthKeychainStore)?

    init(
        fileURL: URL = Self.defaultURL(),
        fileManager: FileManager = .default,
        legacyKeychainStore: (any AntigravityLegacyOAuthKeychainStore)? = AntigravitySecurityLegacyOAuthKeychainStore.shared
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.legacyKeychainStore = legacyKeychainStore
    }

    func load() throws -> AntigravityOAuthCredentials? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let credentials = try JSONDecoder().decode(AntigravityOAuthCredentials.self, from: data)
        try? fileManager.removeItem(at: legacyMetadataURL)
        return credentials
    }

    func save(_ credentials: AntigravityOAuthCredentials) throws {
        let data = try JSONEncoder.antigravityCredentials.encode(credentials)
        let directory = fileURL.deletingLastPathComponent()
        try AntigravityOAuthFileStorage.ensurePrivateDirectory(at: directory, fileManager: fileManager)
        try data.write(to: fileURL, options: [.atomic])
        AntigravityOAuthFileStorage.applyCredentialFilePermissions(at: fileURL, fileManager: fileManager)
        try? fileManager.removeItem(at: legacyMetadataURL)
    }

    func deleteIfPresent() throws {
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
        if fileManager.fileExists(atPath: legacyMetadataURL.path) {
            try fileManager.removeItem(at: legacyMetadataURL)
        }
        try? legacyKeychainStore?.delete(account: Self.legacyKeychainAccount)
    }

    func credentialStatus() -> AntigravityOAuthCredentialStatus? {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let credentials = try? JSONDecoder().decode(AntigravityOAuthCredentials.self, from: data),
              credentials.hasTokenMaterial
        else {
            return nil
        }

        return AntigravityOAuthCredentialStatus(
            hasCredential: true,
            email: credentials.email?.trimmedNonEmpty,
            sourceDescription: "ClaudeUsage OAuth"
        )
    }

    private var legacyMetadataURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("oauth_metadata.json")
    }

    func migrateLegacyKeychainCredentialsIfAvailable() throws -> AntigravityOAuthCredentials? {
        guard AntigravityLegacyOAuthMigrationAttempts.shared.claim(storePath: fileURL.standardizedFileURL.path) else {
            return nil
        }
        guard let payload = try legacyKeychainStore?.loadStringWithoutAuthenticationPrompt(
            account: Self.legacyKeychainAccount
        )?.trimmedNonEmpty,
            let data = payload.data(using: .utf8),
            let credentials = legacyCredentials(from: data),
            credentials.hasTokenMaterial
        else {
            return nil
        }

        try save(credentials)
        try? legacyKeychainStore?.delete(account: Self.legacyKeychainAccount)
        Logger.info("[Antigravity] legacy OAuth Keychain 항목을 파일 저장소로 마이그레이션했습니다.")
        return credentials
    }

    private func legacyCredentials(from data: Data) -> AntigravityOAuthCredentials? {
        if let credentials = try? JSONDecoder().decode(AntigravityOAuthCredentials.self, from: data),
           credentials.hasTokenMaterial
        {
            return credentials.mergingMissingLegacyMetadata(legacyMetadata())
        }

        guard let secrets = try? JSONDecoder().decode(AntigravityLegacyOAuthTokenSecrets.self, from: data),
              secrets.hasTokenMaterial
        else {
            return nil
        }
        let metadata = legacyMetadata()
        return AntigravityOAuthCredentials(
            accessToken: secrets.accessToken,
            refreshToken: secrets.refreshToken,
            expiryDate: metadata?.expiryDateMilliseconds.map { Date(timeIntervalSince1970: $0 / 1000) },
            idToken: secrets.idToken,
            email: metadata?.email,
            projectID: metadata?.projectID,
            clientID: metadata?.clientID,
            clientSecret: nil
        )
    }

    private func legacyMetadata() -> AntigravityLegacyOAuthCredentialMetadata? {
        guard fileManager.fileExists(atPath: legacyMetadataURL.path),
              let data = try? Data(contentsOf: legacyMetadataURL)
        else {
            return nil
        }
        return try? JSONDecoder().decode(AntigravityLegacyOAuthCredentialMetadata.self, from: data)
    }

    static func defaultDirectoryURL(home: URL = FileManager.default.realHomeDirectory) -> URL {
        home
            .appendingPathComponent("Library/Application Support/ClaudeUsage", isDirectory: true)
            .appendingPathComponent("Antigravity", isDirectory: true)
    }

    static func defaultURL(home: URL = FileManager.default.realHomeDirectory) -> URL {
        defaultDirectoryURL(home: home).appendingPathComponent("oauth_creds.json")
    }

    static func credentials(fromEnvironmentValue value: String) -> AntigravityOAuthCredentials? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AntigravityOAuthCredentials.self, from: data)
    }
}

private extension AntigravityOAuthCredentials {
    nonisolated func mergingMissingLegacyMetadata(
        _ metadata: AntigravityLegacyOAuthCredentialMetadata?
    ) -> AntigravityOAuthCredentials {
        guard let metadata else { return self }
        var credentials = self
        credentials.expiryDateMilliseconds = credentials.expiryDateMilliseconds ?? metadata.expiryDateMilliseconds
        credentials.email = credentials.email ?? metadata.email
        credentials.projectID = credentials.projectID ?? metadata.projectID
        credentials.clientID = credentials.clientID ?? metadata.clientID
        return credentials
    }
}

nonisolated struct AntigravityOAuthCredentialStatus: Sendable, Equatable {
    let hasCredential: Bool
    let email: String?
    let sourceDescription: String?
}

nonisolated enum AntigravityOAuthCredentialProbe {
    static func current(
        home: URL = FileManager.default.realHomeDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> AntigravityOAuthCredentialStatus {
        if let value = environment[AntigravityOAuthCredentialsStore.environmentCredentialsKey],
           let credentials = AntigravityOAuthCredentialsStore.credentials(fromEnvironmentValue: value),
           credentials.hasTokenMaterial
        {
            return AntigravityOAuthCredentialStatus(
                hasCredential: true,
                email: credentials.email?.trimmedNonEmpty,
                sourceDescription: "환경변수"
            )
        }

        let url = AntigravityOAuthCredentialsStore.defaultURL(home: home)
        let store = AntigravityOAuthCredentialsStore(
            fileURL: url,
            fileManager: fileManager
        )
        if let status = store.credentialStatus() {
            return status
        }

        let accountStore = AntigravityOAuthAccountStore(
            fileURL: AntigravityOAuthAccountStore.defaultURL(home: home),
            fileManager: fileManager,
            activeCredentialStore: store
        )
        if let active = accountStore.state().activeAccount {
            return AntigravityOAuthCredentialStatus(
                hasCredential: true,
                email: active.email?.trimmedNonEmpty ?? active.credentials.email?.trimmedNonEmpty,
                sourceDescription: "ClaudeUsage OAuth"
            )
        }

        return AntigravityOAuthCredentialStatus(
            hasCredential: false,
            email: nil,
            sourceDescription: nil
        )
    }
}

extension JSONEncoder {
    nonisolated fileprivate static var antigravityCredentials: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension String {
    nonisolated fileprivate var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
