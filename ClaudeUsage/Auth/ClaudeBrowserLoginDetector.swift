import AppKit
import SQLite3

/// 처음 설정에서 어느 브라우저에 Claude 로그인이 있는지 미리 본다.
/// 쿠키 이름과 만료 시각만 읽고 값은 복호화하지 않으므로 Keychain 확인 창이 뜨지 않는다.
nonisolated enum ClaudeBrowserLoginPresence: Equatable, Sendable {
    case present, absent, needsFullDiskAccess
}

nonisolated struct ClaudeBrowserLoginFinding: Equatable, Sendable {
    let family: ClaudeBrowserFamily
    let presence: ClaudeBrowserLoginPresence
}

enum ClaudeBrowserLoginDetector {
    nonisolated static func defaultBrowserFamily() -> ClaudeBrowserFamily? {
        guard let url = URL(string: "https://claude.ai"),
            let app = NSWorkspace.shared.urlForApplication(toOpen: url),
            let identifier = Bundle(url: app)?.bundleIdentifier
        else { return nil }
        return ClaudeBrowserFamily.family(forBundleIdentifier: identifier)
    }

    nonisolated static func isInstalled(_ family: ClaudeBrowserFamily) -> Bool {
        family.bundleIdentifiers.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }

    /// 기본 브라우저를 먼저, 그다음 Claude 앱, 나머지 설치된 브라우저 순으로 본다.
    nonisolated static func orderedFamilies(
        defaultFamily: ClaudeBrowserFamily?, isInstalled: (ClaudeBrowserFamily) -> Bool
    ) -> [ClaudeBrowserFamily] {
        var result: [ClaudeBrowserFamily] = []
        for family in [defaultFamily, .claudeApp].compactMap({ $0 }) + ClaudeBrowserFamily.allCases
        where !result.contains(family) && (family == defaultFamily || isInstalled(family)) {
            result.append(family)
        }
        return result
    }

    /// 로그인이 있는 첫 출처. 없으면 기본 브라우저의 상태를 돌려준다.
    nonisolated static func findLogin() -> ClaudeBrowserLoginFinding? {
        let defaultFamily = defaultBrowserFamily()
        let families = orderedFamilies(defaultFamily: defaultFamily, isInstalled: isInstalled)
        var first: ClaudeBrowserLoginFinding?
        for family in families {
            let finding = ClaudeBrowserLoginFinding(family: family, presence: presence(in: family))
            if finding.presence == .present { return finding }
            if family == defaultFamily { first = finding }
        }
        return first
    }

    nonisolated static func importer(for family: ClaudeBrowserFamily) -> any ClaudeBrowserCookieImporting {
        switch family.storage {
        case .chromiumProfiles, .chromiumSingle: return ClaudeChromeCookieImportService(family: family)
        case .firefox: return ClaudeFirefoxCookieImportService()
        case .safari: return ClaudeSafariCookieImportService()
        }
    }

    nonisolated static func presence(in family: ClaudeBrowserFamily) -> ClaudeBrowserLoginPresence {
        switch family.storage {
        case .chromiumProfiles, .chromiumSingle:
            let paths = ClaudeChromeCookieImportService(family: family, decryptionKeyProvider: { [] })
                .discoverCandidates().map(\.cookiesPath)
            return paths.contains { hasSessionCookie(sqlite: $0, firefox: false) } ? .present : .absent
        case .firefox:
            let paths = ClaudeFirefoxCookieImportService().discoverCandidates().map(\.cookiesPath)
            return paths.contains { hasSessionCookie(sqlite: $0, firefox: true) } ? .present : .absent
        case .safari:
            let service = ClaudeSafariCookieImportService()
            let files = service.discoverCandidates().map(\.cookiesPath)
            guard !files.isEmpty else { return .absent }
            let readable = files.filter { FileManager.default.isReadableFile(atPath: $0.path) }
            guard !readable.isEmpty else { return .needsFullDiskAccess }
            let found = readable.contains { file in
                guard let data = try? Data(contentsOf: file), let records = try? ClaudeSafariBinaryCookies.parse(data)
                else { return false }
                return records.contains { isClaudeSessionCookie(domain: $0.domain, name: $0.name) }
            }
            return found ? .present : .absent
        }
    }

    // expires_utc는 1601-01-01 기준 마이크로초, 0은 세션 쿠키.
    private nonisolated static let chromiumSQL = """
        SELECT host_key, name FROM cookies WHERE name = 'sessionKey'
        AND (expires_utc = 0 OR expires_utc > (strftime('%s','now') + 11644473600) * 1000000)
        """
    private nonisolated static let firefoxSQL = """
        SELECT host, name FROM moz_cookies WHERE name = 'sessionKey'
        AND (expiry = 0 OR expiry > strftime('%s','now'))
        """

    nonisolated static func hasSessionCookie(sqlite path: URL, firefox: Bool) -> Bool {
        let sql = firefox ? firefoxSQL : chromiumSQL
        return
            (try? ClaudeCookieDatabaseCopy.withCopy(of: path, prefix: "claude-login-check") { database -> Bool in
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return false }
                defer { sqlite3_finalize(statement) }
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard let host = sqlite3_column_text(statement, 0).map({ String(cString: $0) }) else { continue }
                    if isClaudeSessionCookie(domain: host, name: "sessionKey") { return true }
                }
                return false
            }) ?? false
    }

    nonisolated static func isClaudeSessionCookie(domain: String, name: String) -> Bool {
        let host = domain.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        return name == "sessionKey" && (host == "claude.ai" || host.hasSuffix(".claude.ai"))
    }
}
