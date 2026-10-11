import Foundation
import XCTest
@testable import ClaudeUsage

/// 임시 폴더와 가짜 Keychain만 쓴다. 실제 Claude Code 로그인과 Keychain은 건드리지 않는다.
final class ClaudeCodeFolderKeychainTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-keychain-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func folder(_ name: String, accountID: String? = "acc-1") throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let account: [String: Any] = accountID.map { ["accountUuid": $0] } ?? [:]
        try JSONSerialization.data(withJSONObject: ["oauthAccount": account])
            .write(to: directory.appendingPathComponent(".claude.json"))
        return directory
    }

    private func name(_ value: String) -> String {
        ClaudeCodeCredentialReader.scopedKeychainServiceName(configDirectoryValue: value)
    }

    private func payload(_ token: String, expiresAt: Date = .distantFuture) -> String {
        #"{"claudeAiOauth":{"accessToken":"\#(token)","expiresAt":\#(Int(expiresAt.timeIntervalSince1970 * 1000))}}"#
    }

    private func keychain(
        _ items: [String: String], names: [String]? = nil, failing: Set<String> = []
    ) -> ClaudeCodeKeychain {
        var keychain = ClaudeCodeKeychain.none
        keychain.read = { service in
            if failing.contains(service) { return .failed }
            return items[service].map(ClaudeCodeKeychainCLI.Outcome.payload) ?? .notFound
        }
        keychain.credentialServiceNames = { names }
        return keychain
    }

    private static let noOwnerLookup: ClaudeCodeFolderKeychain.TokenOwner = { _ in
        XCTFail("표기로 찾았으면 서버에 묻지 않습니다")
        return nil
    }

    func testLoginUnderTheCleanPathIsFoundByName() async throws {
        let directory = try folder(".claude-work")
        let slot = await ClaudeCodeFolderKeychain.resolve(
            directory, keychain: keychain([name(directory.path): payload("t")]), tokenOwner: Self.noOwnerLookup)
        XCTAssertEqual(slot.keychainService, name(directory.path))
        XCTAssertEqual(slot.cliConfigDirectoryValue, directory.path)
    }

    func testLoginMadeWithTrailingSlashIsFoundAndRefreshedWithTheSameSpelling() async throws {
        let directory = try folder(".claude-work")
        let spelled = directory.path + "/"
        let slot = await ClaudeCodeFolderKeychain.resolve(
            directory, keychain: keychain([name(spelled): payload("t")]), tokenOwner: Self.noOwnerLookup)
        XCTAssertEqual(slot.keychainService, name(spelled))
        XCTAssertEqual(slot.cliConfigDirectoryValue, spelled, "다른 표기로 갱신하면 두 항목이 갈라집니다")
        XCTAssertTrue(slot.canRunCLI)
    }

    func testLoginMadeThroughALinkedPathIsFound() async throws {
        let target = try folder("real-claude")
        let link = root.appendingPathComponent(".claude-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let slot = await ClaudeCodeFolderKeychain.resolve(
            link, keychain: keychain([name(target.path): payload("t")]), tokenOwner: Self.noOwnerLookup)
        XCTAssertEqual(slot.keychainService, name(target.path))
        XCTAssertEqual(slot.cliConfigDirectoryValue, target.path)
    }

    func testWhenTwoSpellingsExistTheLaterExpiryWins() async throws {
        let directory = try folder(".claude-work")
        let items = [
            name(directory.path): payload("old", expiresAt: Date(timeIntervalSince1970: 2_000_000_000)),
            name(directory.path + "/"): payload("new", expiresAt: Date(timeIntervalSince1970: 3_000_000_000)),
        ]
        let slot = await ClaudeCodeFolderKeychain.resolve(
            directory, keychain: keychain(items), tokenOwner: Self.noOwnerLookup)
        XCTAssertEqual(slot.cliConfigDirectoryValue, directory.path + "/")
    }

    func testCredentialFileWithoutKeychainItemKeepsTheCleanPath() async throws {
        let directory = try folder(".claude-work")
        try Data(payload("file").utf8).write(to: directory.appendingPathComponent(".credentials.json"))
        let slot = await ClaudeCodeFolderKeychain.resolve(
            directory, keychain: keychain([:], names: [name("/elsewhere")]), tokenOwner: Self.noOwnerLookup)
        XCTAssertEqual(slot.keychainMatch, .configDirectoryValue(directory.path))
    }

    func testUnclaimedItemOwnedByTheFolderAccountIsMatched() async throws {
        let directory = try folder(".claude-work", accountID: "acc-1")
        let other = name("relative/.claude-other")
        let mine = name("relative/.claude-work")
        let slot = await ClaudeCodeFolderKeychain.resolve(
            directory,
            keychain: keychain([other: payload("token-other"), mine: payload("token-mine")], names: [other, mine]),
            tokenOwner: { token in
                UsageAccountIdentity(accountID: token == "token-mine" ? "acc-1" : "acc-2")
            })
        XCTAssertEqual(slot.keychainService, mine)
        XCTAssertEqual(slot.keychainMatch, .accountOwner)
        XCTAssertNil(slot.cliConfigDirectoryValue)
        XCTAssertFalse(slot.canRunCLI, "표기를 모르면 claude가 다른 항목을 봅니다")
    }

    func testTwoItemsOwnedByTheSameAccountAreNotGuessed() async throws {
        let directory = try folder(".claude-work", accountID: "acc-1")
        let first = name("a/.claude-work")
        let second = name("b/.claude-work")
        let slot = await ClaudeCodeFolderKeychain.resolve(
            directory, keychain: keychain([first: payload("one"), second: payload("two")], names: [first, second]),
            tokenOwner: { _ in UsageAccountIdentity(accountID: "acc-1") })
        XCTAssertEqual(slot.keychainMatch, .configDirectoryValue(directory.path))
    }

    func testUnknownOwnerStopsMatchingInsteadOfGuessing() async throws {
        let directory = try folder(".claude-work", accountID: "acc-1")
        let unknown = name("a/.claude-x")
        let mine = name("b/.claude-work")
        let slot = await ClaudeCodeFolderKeychain.resolve(
            directory,
            keychain: keychain([unknown: payload("offline"), mine: payload("mine")], names: [unknown, mine]),
            tokenOwner: { token in token == "mine" ? UsageAccountIdentity(accountID: "acc-1") : nil })
        XCTAssertEqual(slot.keychainMatch, .configDirectoryValue(directory.path))
    }

    func testItemsOfOtherKnownFoldersAreNotConsidered() async throws {
        let directory = try folder(".claude-work", accountID: "acc-1")
        let sibling = try folder(".claude-home", accountID: "acc-1")
        let siblingItem = name(sibling.path)
        let mine = name("relative/.claude-work")
        let asked = AskedTokens()
        let slot = await ClaudeCodeFolderKeychain.resolve(
            directory, excluding: [sibling],
            keychain: keychain([siblingItem: payload("sibling"), mine: payload("mine")], names: [siblingItem, mine]),
            tokenOwner: { token in
                asked.record(token)
                return UsageAccountIdentity(accountID: "acc-1")
            })
        XCTAssertEqual(slot.keychainService, mine)
        XCTAssertEqual(asked.values, ["mine"])
    }

    func testExpiredUnclaimedTokenIsSkippedWithoutAskingTheServer() async throws {
        let directory = try folder(".claude-work", accountID: "acc-1")
        let expired = name("a/.claude-work")
        let slot = await ClaudeCodeFolderKeychain.resolve(
            directory,
            keychain: keychain(
                [expired: payload("expired", expiresAt: Date(timeIntervalSince1970: 1_000_000_000))], names: [expired]),
            tokenOwner: Self.noOwnerLookup)
        XCTAssertEqual(slot.keychainMatch, .configDirectoryValue(directory.path))
    }

    func testReadFailureDoesNotFallThroughToGuessing() async throws {
        let directory = try folder(".claude-work", accountID: "acc-1")
        var keychain = keychain([:], failing: [name(directory.path)])
        keychain.credentialServiceNames = {
            XCTFail("이름으로 읽지 못했으면 다른 항목을 고르지 않습니다")
            return nil
        }
        let slot = await ClaudeCodeFolderKeychain.resolve(directory, keychain: keychain, tokenOwner: Self.noOwnerLookup)
        XCTAssertEqual(slot.keychainMatch, .configDirectoryValue(directory.path))
    }

    func testFolderServiceNamesExcludeDefaultAndOtherProducts() {
        XCTAssertTrue(ClaudeCodeFolderKeychain.isFolderServiceName("Claude Code-credentials-315f618e"))
        XCTAssertFalse(ClaudeCodeFolderKeychain.isFolderServiceName("Claude Code-credentials"))
        XCTAssertFalse(ClaudeCodeFolderKeychain.isFolderServiceName("Claude Code-credentials-315F618E"))
        XCTAssertFalse(ClaudeCodeFolderKeychain.isFolderServiceName("Claude Code-credentials-315f618e-x"))
        XCTAssertFalse(ClaudeCodeFolderKeychain.isFolderServiceName("Other-credentials-315f618e"))
    }

    func testClaudeCodeHashesTheRawValueAfterNFC() {
        // Claude Code 2.1.288: sha256((CLAUDE_CONFIG_DIR).normalize("NFC")) 앞 8자리
        XCTAssertEqual(name("/Users/seongmin/.claude"), "Claude Code-credentials-315f618e")
        XCTAssertNotEqual(name("/Users/seongmin/.claude"), name("/Users/seongmin/.claude/"))
        XCTAssertEqual(name("/tmp/s\u{0065}\u{0301}"), name("/tmp/s\u{00E9}"))
    }

    func testExpiredLoginMatchedOnlyByOwnerIsNotRefreshedThroughClaude() async throws {
        let directory = try folder(".claude-work")
        let slot = ClaudeCodeLoginSlot(
            configDirectory: directory, profileFile: directory.appendingPathComponent(".claude.json"),
            keychainService: name("relative/.claude-work"), keychainMatch: .accountOwner)
        let expired = payload("expired", expiresAt: Date(timeIntervalSince1970: 1_000_000_000))
        var keychain = ClaudeCodeKeychain.none
        keychain.read = { _ in .payload(expired) }
        do {
            _ = try await ClaudeUsageAccountProvider.fetchOwnedClaudeCodeUsage(
                slot: slot, interactive: false, keychain: keychain,
                cliRefresher: { _ in
                    XCTFail("표기를 모르는 로그인을 claude로 갱신하면 다른 항목을 봅니다")
                    return .unavailable
                })
            XCTFail("갱신할 수 없으면 일시 실패입니다")
        } catch {
            XCTAssertEqual(error as? UsageAccountFetchError, .unavailable)
        }
    }
}

private final class AskedTokens: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func record(_ token: String) { lock.withLock { recorded.append(token) } }
    var values: [String] { lock.withLock { recorded } }
}
