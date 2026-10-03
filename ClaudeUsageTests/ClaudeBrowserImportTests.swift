import SQLite3
import XCTest
@testable import ClaudeUsage

final class ClaudeBrowserImportTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("browser-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func sqlite(_ name: String, _ statements: [String]) throws -> URL {
        let url = directory.appendingPathComponent(name)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        for statement in statements { XCTAssertEqual(sqlite3_exec(database, statement, nil, nil, nil), SQLITE_OK) }
        return url
    }

    func testFirefoxImportReadsPlainSessionKeyAndSkipsExpired() throws {
        let profile = directory.appendingPathComponent("abc.default-release")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let future = Int(Date().timeIntervalSince1970) + 86_400
        let db = try sqlite(
            "abc.default-release/cookies.sqlite",
            [
                "CREATE TABLE moz_cookies (host TEXT, name TEXT, value TEXT, path TEXT, expiry INTEGER, isSecure INTEGER)",
                "INSERT INTO moz_cookies VALUES ('.claude.ai', 'activitySessionId', '6f1c2a4e-9b7d-4c1e-8a2f-3d5b7e9c1a0b', '/', \(future), 1)",
                "INSERT INTO moz_cookies VALUES ('.claude.ai', 'sessionKey', 'sk-ant-sid01-firefox-0123456789abcdef', '/', \(future), 1)",
                "INSERT INTO moz_cookies VALUES ('.claude.ai', 'sessionKey', 'sk-ant-sid01-expired-0123456789abcdef', '/', 10, 1)",
            ])

        guard
            case .importedSession(let session) = try ClaudeFirefoxCookieImportService(profilesRoot: directory)
                .attemptImport()
        else { return XCTFail("Firefox 세션을 가져와야 합니다") }
        XCTAssertEqual(session.sessionKey, "sk-ant-sid01-firefox-0123456789abcdef")
        XCTAssertEqual(session.family, .firefox)
        XCTAssertTrue(session.sourceDetail.hasPrefix("Firefox "))
        XCTAssertTrue(ClaudeBrowserLoginDetector.hasSessionCookie(sqlite: db, firefox: true))
    }

    func testChromiumPresenceUsesNamesOnlyAndRespectsExpiry() throws {
        let chromeEpochOffset: Int64 = 11_644_473_600
        let future = (Int64(Date().timeIntervalSince1970) + 86_400 + chromeEpochOffset) * 1_000_000
        let live = try sqlite(
            "Cookies",
            [
                "CREATE TABLE cookies (host_key TEXT, name TEXT, expires_utc INTEGER, encrypted_value BLOB)",
                "INSERT INTO cookies VALUES ('.claude.ai', 'sessionKey', \(future), x'763130')",
            ])
        let expired = try sqlite(
            "Cookies-old",
            [
                "CREATE TABLE cookies (host_key TEXT, name TEXT, expires_utc INTEGER, encrypted_value BLOB)",
                "INSERT INTO cookies VALUES ('.claude.ai', 'sessionKey', 1, x'763130')",
                "INSERT INTO cookies VALUES ('evilclaude.ai', 'sessionKey', \(future), x'763130')",
            ])

        XCTAssertTrue(ClaudeBrowserLoginDetector.hasSessionCookie(sqlite: live, firefox: false))
        XCTAssertFalse(ClaudeBrowserLoginDetector.hasSessionCookie(sqlite: expired, firefox: false))
    }

    func testSafariBinaryCookiesParse() throws {
        let data = Self.binaryCookies([
            ("claude.ai", "sessionKey", "sk-ant-sid01-safari-0123456789abcdef", Date().addingTimeInterval(86_400)),
            ("claude.ai", "sessionKey", "sk-ant-sid01-old-0123456789abcdef", Date().addingTimeInterval(-60)),
        ])
        let records = try ClaudeSafariBinaryCookies.parse(data)

        XCTAssertEqual(records.map(\.value), ["sk-ant-sid01-safari-0123456789abcdef"])
        XCTAssertEqual(records.first?.domain, "claude.ai")
        XCTAssertThrowsError(try ClaudeSafariBinaryCookies.parse(Data("nope".utf8)))
    }

    func testUnreadableSafariFileAsksForFullDiskAccess() throws {
        let file = directory.appendingPathComponent("Cookies.binarycookies")
        try Data().write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }

        XCTAssertEqual(try ClaudeSafariCookieImportService(cookieFiles: [file]).attemptImport(), .needsFullDiskAccess)
    }

    func testDefaultBrowserComesFirstThenClaudeApp() {
        let installed: Set<ClaudeBrowserFamily> = [.chrome, .claudeApp, .firefox]
        XCTAssertEqual(
            ClaudeBrowserLoginDetector.orderedFamilies(defaultFamily: .safari, isInstalled: installed.contains),
            [.safari, .claudeApp, .chrome, .firefox])
        XCTAssertEqual(
            ClaudeBrowserLoginDetector.orderedFamilies(defaultFamily: nil, isInstalled: installed.contains),
            [.claudeApp, .chrome, .firefox])
    }

    func testSourceDetailKeepsChromeFormatAndNamesOtherBrowsers() {
        let chrome = ClaudeBrowserImportedSession(family: .chrome, profileName: "Default", sessionKey: "sk-ant-a")
        let brave = ClaudeBrowserImportedSession(family: .brave, profileName: "Profile 2", sessionKey: "sk-ant-b")
        let app = ClaudeBrowserImportedSession(family: .claudeApp, profileName: "Default", sessionKey: "sk-ant-c")

        XCTAssertEqual(chrome.sourceDetail, "기본 프로필 (Default)")
        XCTAssertEqual(brave.sourceDetail, "Brave 프로필 2 (Profile 2)")
        XCTAssertEqual(app.sourceDetail, "Claude 앱")
        XCTAssertEqual(ClaudeBrowserFamily.family(fromSourceDetail: brave.sourceDetail), .brave)
        XCTAssertEqual(ClaudeBrowserFamily.family(fromSourceDetail: chrome.sourceDetail), .chrome)
        XCTAssertEqual(ClaudeBrowserFamily.family(forBundleIdentifier: "com.naver.Whale"), .whale)
    }

    /// 실제 파일과 같은 배치로 쿠키 한 페이지를 만든다.
    private static func binaryCookies(_ cookies: [(String, String, String, Date)]) -> Data {
        func le32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * $0)) & 0xff) } }
        func be32(_ value: Int) -> [UInt8] { le32(value).reversed() }
        func double(_ value: Double) -> [UInt8] { (0..<8).map { UInt8((value.bitPattern >> (8 * UInt64($0))) & 0xff) } }
        let records: [[UInt8]] = cookies.map { domain, name, value, expiry in
            let strings = [domain, name, "/", value].map { Array($0.utf8) + [0] }
            var offset = 56
            var offsets: [Int] = []
            for string in strings {
                offsets.append(offset)
                offset += string.count
            }
            var record = le32(offset) + le32(0) + le32(1) + le32(0)
            record += le32(offsets[0]) + le32(offsets[1]) + le32(offsets[2]) + le32(offsets[3])
            record += [UInt8](repeating: 0, count: 8) + double(expiry.timeIntervalSinceReferenceDate) + double(0)
            return record + strings.flatMap { $0 }
        }
        var page: [UInt8] = [0, 0, 1, 0] + le32(records.count)
        var cursor = 8 + records.count * 4 + 4
        for record in records {
            page += le32(cursor)
            cursor += record.count
        }
        page += le32(0) + records.flatMap { $0 }
        return Data(Array("cook".utf8) + be32(1) + be32(page.count) + page + [UInt8](repeating: 0, count: 8))
    }
}

final class ClaudeCodeLoginDetectorTests: XCTestCase {
    func testCredentialFileInConfigDirectoryCountsAsLogin() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "claude-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = ["CLAUDE_CONFIG_DIR": directory.path]

        XCTAssertFalse(ClaudeCodeLoginDetector.credentialFileExists(environment: environment))
        try Data("{}".utf8).write(to: directory.appendingPathComponent(".credentials.json"))
        XCTAssertTrue(ClaudeCodeLoginDetector.credentialFileExists(environment: environment))
    }

    func testMissingKeychainServiceIsNotALogin() {
        XCTAssertFalse(
            ClaudeCodeLoginDetector.keychainItemExists(service: "claudeusage.test.missing.\(UUID().uuidString)"))
    }
}
