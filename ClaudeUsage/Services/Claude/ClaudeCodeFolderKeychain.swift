import CryptoKit
import Foundation

/// 다른 폴더(CLAUDE_CONFIG_DIR) 로그인이 쓰는 Keychain 항목을 찾는다. Claude Code는 변수 원문으로 항목 이름을 정하므로
/// 사용자가 셸에 쓴 표기를 모르면 계산한 이름이 빗나갈 수 있다. 세 단계로 찾는다.
/// 1. 경로에서 나오는 표기(정리한 경로, 끝 '/', 링크를 푼 경로)로 이름을 계산해 찾는다. 찾은 표기로 `claude`도 실행한다.
/// 2. 없으면 어느 폴더의 표기에도 맞지 않는 항목 중 토큰 주인이 이 폴더 계정인 것을 찾는다. 정확히 하나일 때만 고른다.
/// 3. 그래도 없으면 정리한 경로의 이름을 돌려준다. 그 폴더에는 쓸 수 있는 로그인이 없다는 뜻이다.
/// 확인하지 못한 단계가 있으면 추측해서 고르지 않고 3단계 결과를 돌려준다.
nonisolated enum ClaudeCodeFolderKeychain {
    typealias TokenOwner = @Sendable (_ accessToken: String) async -> UsageAccountIdentity?

    /// 2단계에서 토큰 주인을 서버에 묻는 항목 수 상한. 넘으면 고르지 않는다.
    static let maximumOwnerLookups = 8

    static func configDirectoryValues(for directory: URL) -> [String] {
        let canonical = directory.standardizedFileURL.path
        let resolved = directory.resolvingSymlinksInPath().standardizedFileURL.path
        var values: [String] = []
        for value in [canonical, canonical + "/", resolved, resolved + "/"] where !values.contains(value) {
            values.append(value)
        }
        return values
    }

    static func resolve(
        _ directory: URL, excluding otherFolders: [URL] = [], keychain: ClaudeCodeKeychain, tokenOwner: TokenOwner
    ) async -> ClaudeCodeLoginSlot {
        let candidates = configDirectoryValues(for: directory).map {
            ClaudeCodeLoginSlot.folderSlot(directory, configDirectoryValue: $0)
        }
        let canonical = candidates[0]
        var found: [(slot: ClaudeCodeLoginSlot, expiresAt: Date)] = []
        var readFailed = false
        for candidate in candidates {
            switch await keychain.read(candidate.keychainService) {
            case .payload(let payload):
                let credential = parse(payload, service: candidate.keychainService)
                found.append((candidate, credential?.expiresAt ?? .distantPast))
            case .notFound:
                break
            case .failed:
                readFailed = true
            }
        }
        // 같은 폴더를 두 표기로 쓴 적이 있으면 만료가 늦은 쪽이 지금 쓰는 로그인이다. 같으면 정리한 경로를 먼저 본다.
        if let best = found.max(by: { $0.expiresAt < $1.expiresAt }) { return best.slot }
        guard !readFailed,
            !canonical.credentialFiles.contains(where: { FileManager.default.fileExists(atPath: $0.path) })
        else { return canonical }
        guard let accountID = canonical.identity()?.accountID, let names = await keychain.credentialServiceNames()
        else { return canonical }

        let excluded = Set(
            candidates.map(\.keychainService)
                + otherFolders.flatMap { configDirectoryValues(for: $0) }.map {
                    ClaudeCodeCredentialReader.scopedKeychainServiceName(configDirectoryValue: $0)
                })
        let unclaimed = names.filter { isFolderServiceName($0) && !excluded.contains($0) }
        var matches: [String] = []
        var lookups = 0
        for name in unclaimed {
            guard case .payload(let payload) = await keychain.read(name),
                let credential = parse(payload, service: name), !credential.isExpired
            else { continue }
            lookups += 1
            guard lookups <= maximumOwnerLookups, let owner = await tokenOwner(credential.accessToken) else {
                return canonical
            }
            if owner.accountID == accountID { matches.append(name) }
        }
        guard matches.count == 1 else { return canonical }
        return ClaudeCodeLoginSlot(
            configDirectory: directory, profileFile: canonical.profileFile, keychainService: matches[0],
            keychainMatch: .accountOwner)
    }

    /// `Claude Code-credentials-`와 16진수 8자리. 기본 로그인과 다른 제품의 항목은 제외한다.
    static func isFolderServiceName(_ name: String) -> Bool {
        let prefix = ClaudeCodeCredentialReader.defaultKeychainService + "-"
        guard name.hasPrefix(prefix) else { return false }
        let suffix = name.dropFirst(prefix.count)
        return suffix.count == 8 && suffix.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func parse(_ payload: String, service: String) -> ClaudeCodeOAuthCredential? {
        ClaudeCodeCredentialReader.parseCredential(from: payload, source: .keychain(service: service))
    }
}

/// 토큰 주인 조회 결과를 토큰별로 기억한다. 토큰은 회전하므로 확인된 결과만 짧게 둔다.
actor ClaudeCodeTokenOwnerCache {
    static let shared = ClaudeCodeTokenOwnerCache()

    private var owners: [String: UsageAccountIdentity] = [:]

    func owner(
        of accessToken: String, lookup: @Sendable (String) async -> UsageAccountIdentity?
    ) async -> UsageAccountIdentity? {
        let key = SHA256.hash(data: Data(accessToken.utf8)).map { String(format: "%02x", $0) }.joined()
        if let cached = owners[key] { return cached }
        guard let owner = await lookup(accessToken) else { return nil }
        if owners.count >= 64 { owners.removeAll() }
        owners[key] = owner
        return owner
    }
}
