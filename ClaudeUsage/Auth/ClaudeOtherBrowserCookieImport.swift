import Foundation
import SQLite3

/// Firefox 쿠키는 암호화하지 않아 Keychain 확인 없이 읽는다.
final class ClaudeFirefoxCookieImportService: ClaudeBrowserCookieImporting, @unchecked Sendable {
    private let profilesRoot: URL

    nonisolated init(profilesRoot: URL? = nil) {
        self.profilesRoot =
            profilesRoot
            ?? FileManager.default.realHomeDirectory.appendingPathComponent(
                "Library/Application Support/Firefox/Profiles", isDirectory: true)
    }

    nonisolated func discoverCandidates() -> [ClaudeBrowserSessionCandidate] {
        let fileManager = FileManager.default
        let profiles =
            (try? fileManager.contentsOfDirectory(
                at: profilesRoot, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? []
        return profiles.compactMap { profile -> (ClaudeBrowserSessionCandidate, Date)? in
            let cookies = profile.appendingPathComponent("cookies.sqlite")
            guard fileManager.fileExists(atPath: cookies.path) else { return nil }
            let modified = (try? cookies.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            return (
                ClaudeBrowserSessionCandidate(
                    family: .firefox, profileName: profile.lastPathComponent, cookiesPath: cookies,
                    supportsAutomaticImport: true),
                modified ?? .distantPast
            )
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    nonisolated func attemptImport() throws -> ClaudeBrowserImportOutcome {
        ClaudeBrowserImportCollector.collect(
            family: .firefox, candidates: discoverCandidates(),
            read: { try ClaudeFirefoxCookieReader.readCookies(cookiesURL: $0.cookiesPath) })
    }
}

enum ClaudeFirefoxCookieReader {
    nonisolated static func readCookies(cookiesURL: URL) throws -> [ClaudeChromiumCookieRecord] {
        try ClaudeCookieDatabaseCopy.withCopy(of: cookiesURL, prefix: "claude-firefox") { database in
            var statement: OpaquePointer?
            let sql = """
                SELECT host, name, path, expiry, isSecure, value FROM moz_cookies
                WHERE host LIKE '%claude.ai%' OR host LIKE '%anthropic.com%'
                """
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw ClaudeChromiumCookieReaderError.sqlitePrepareFailed(details: "moz_cookies")
            }
            defer { sqlite3_finalize(statement) }
            var records: [ClaudeChromiumCookieRecord] = []
            let now = Date()
            while sqlite3_step(statement) == SQLITE_ROW {
                func text(_ index: Int32) -> String? {
                    sqlite3_column_text(statement, index).map { String(cString: $0) }
                }
                guard let host = text(0), let name = text(1), let value = text(5) else { continue }
                let expiry = sqlite3_column_int64(statement, 3)
                // Firefox 일부 버전은 expiry를 밀리초로 저장한다.
                let seconds = expiry > 100_000_000_000 ? Double(expiry) / 1000 : Double(expiry)
                let expiresAt = expiry > 0 ? Date(timeIntervalSince1970: seconds) : nil
                if let expiresAt, expiresAt < now { continue }
                records.append(
                    ClaudeChromiumCookieRecord(
                        domain: host, name: name, path: text(2) ?? "/", value: value, expiresAt: expiresAt,
                        isSecure: sqlite3_column_int(statement, 4) != 0))
            }
            return records
        }
    }
}

/// Safari 쿠키 파일은 전체 디스크 접근 권한이 있어야 열린다.
final class ClaudeSafariCookieImportService: ClaudeBrowserCookieImporting, @unchecked Sendable {
    private let cookieFiles: [URL]

    nonisolated init(cookieFiles: [URL]? = nil) {
        let home = FileManager.default.realHomeDirectory
        self.cookieFiles =
            cookieFiles ?? [
                home.appendingPathComponent(
                    "Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"),
                home.appendingPathComponent("Library/Cookies/Cookies.binarycookies"),
            ]
    }

    nonisolated func discoverCandidates() -> [ClaudeBrowserSessionCandidate] {
        cookieFiles.filter { FileManager.default.fileExists(atPath: $0.path) }.map {
            ClaudeBrowserSessionCandidate(
                family: .safari, profileName: "Default", cookiesPath: $0, supportsAutomaticImport: true)
        }
    }

    nonisolated func attemptImport() throws -> ClaudeBrowserImportOutcome {
        let candidates = discoverCandidates()
        guard candidates.contains(where: { FileManager.default.isReadableFile(atPath: $0.cookiesPath.path) }) else {
            return candidates.isEmpty
                ? .unavailable(message: "Safari 쿠키 파일을 찾지 못했습니다.") : .needsFullDiskAccess
        }
        return ClaudeBrowserImportCollector.collect(
            family: .safari, candidates: candidates,
            read: { try ClaudeSafariBinaryCookies.parse(Data(contentsOf: $0.cookiesPath)) })
    }
}

/// `Cookies.binarycookies` 형식: "cook", 페이지 수와 크기(빅엔디언), 페이지마다 쿠키 오프셋(리틀엔디언).
enum ClaudeSafariBinaryCookies {
    enum ParseError: Error { case invalid }

    nonisolated static func parse(_ data: Data, now: Date = Date()) throws -> [ClaudeChromiumCookieRecord] {
        let bytes = [UInt8](data)
        func u32(_ offset: Int, bigEndian: Bool) throws -> Int {
            guard offset >= 0, offset + 4 <= bytes.count else { throw ParseError.invalid }
            let b = bytes[offset..<offset + 4].map(UInt32.init)
            return Int(
                bigEndian ? b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3] : b[3] << 24 | b[2] << 16 | b[1] << 8 | b[0])
        }
        func double(_ offset: Int) throws -> Double {
            guard offset >= 0, offset + 8 <= bytes.count else { throw ParseError.invalid }
            var raw: UInt64 = 0
            for index in 0..<8 { raw |= UInt64(bytes[offset + index]) << (8 * index) }
            return Double(bitPattern: raw)
        }
        func string(_ offset: Int, limit: Int) -> String? {
            guard offset >= 0, offset < limit else { return nil }
            guard let end = bytes[offset..<limit].firstIndex(of: 0) else { return nil }
            return String(bytes: bytes[offset..<end], encoding: .utf8)
        }
        guard bytes.count >= 8, bytes[0..<4].elementsEqual(Array("cook".utf8)) else { throw ParseError.invalid }
        let pageCount = try u32(4, bigEndian: true)
        guard pageCount < 100_000 else { throw ParseError.invalid }
        var pageSizes: [Int] = []
        for index in 0..<pageCount { pageSizes.append(try u32(8 + index * 4, bigEndian: true)) }
        var pageStart = 8 + pageCount * 4
        var records: [ClaudeChromiumCookieRecord] = []
        for size in pageSizes {
            let pageEnd = pageStart + size
            guard pageEnd <= bytes.count else { throw ParseError.invalid }
            let cookieCount = try u32(pageStart + 4, bigEndian: false)
            for index in 0..<min(cookieCount, 100_000) {
                let start = pageStart + (try u32(pageStart + 8 + index * 4, bigEndian: false))
                let recordSize = try u32(start, bigEndian: false)
                let recordEnd = min(start + recordSize, pageEnd)
                guard recordSize >= 56, recordEnd <= pageEnd else { continue }
                let flags = try u32(start + 8, bigEndian: false)
                guard let domain = string(start + (try u32(start + 16, bigEndian: false)), limit: recordEnd),
                    let name = string(start + (try u32(start + 20, bigEndian: false)), limit: recordEnd),
                    let value = string(start + (try u32(start + 28, bigEndian: false)), limit: recordEnd)
                else { continue }
                let path = string(start + (try u32(start + 24, bigEndian: false)), limit: recordEnd) ?? "/"
                // 날짜는 2001-01-01 기준 초다.
                let expiresAt = Date(timeIntervalSinceReferenceDate: try double(start + 40))
                guard expiresAt > now else { continue }
                records.append(
                    ClaudeChromiumCookieRecord(
                        domain: domain, name: name, path: path, value: value, expiresAt: expiresAt,
                        isSecure: flags & 1 != 0))
            }
            pageStart = pageEnd
        }
        return records
    }
}

enum ClaudeBrowserImportCollector {
    nonisolated static func collect(
        family: ClaudeBrowserFamily, candidates: [ClaudeBrowserSessionCandidate],
        read: (ClaudeBrowserSessionCandidate) throws -> [ClaudeChromiumCookieRecord]
    ) -> ClaudeBrowserImportOutcome {
        guard !candidates.isEmpty else {
            return .unavailable(message: "\(family.displayName)에서 Claude 로그인을 찾지 못했습니다.")
        }
        var sessions: [ClaudeBrowserImportedSession] = []
        var fingerprints = Set<String>()
        for candidate in candidates {
            guard let records = try? read(candidate),
                let key = ClaudeChromeCookieImportService.findSessionKey(in: records),
                fingerprints.insert(ClaudeAccountStore.fingerprint(for: key)).inserted
            else { continue }
            sessions.append(
                ClaudeBrowserImportedSession(family: family, profileName: candidate.profileName, sessionKey: key))
        }
        switch sessions.count {
        case 0:
            return .manualSessionKeyRequired(
                message:
                    "\(family.displayName)에서 Claude 로그인 정보를 찾지 못했습니다. \(family.displayName)에서 claude.ai에 로그인되어 있는지 확인하세요."
            )
        case 1: return .importedSession(sessions[0])
        default: return .importedSessionCandidates(sessions)
        }
    }
}

/// 잠긴 쿠키 DB는 WAL과 함께 임시 폴더에 복사해 읽기 전용으로 연다.
enum ClaudeCookieDatabaseCopy {
    nonisolated static func withCopy<T>(of source: URL, prefix: String, body: (OpaquePointer?) throws -> T) throws -> T
    {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent(source.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: source, to: copy)
        } catch {
            throw ClaudeChromiumCookieReaderError.unableToCopyCookies(details: error.localizedDescription)
        }
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.copyItem(
                at: URL(fileURLWithPath: source.path + suffix), to: URL(fileURLWithPath: copy.path + suffix))
        }
        var database: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            throw ClaudeChromiumCookieReaderError.sqliteOpenFailed(details: source.lastPathComponent)
        }
        defer { sqlite3_close(database) }
        return try body(database)
    }
}
