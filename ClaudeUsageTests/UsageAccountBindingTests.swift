import Foundation
import XCTest
import os
@testable import ClaudeUsage

@MainActor
final class UsageAccountBindingTests: XCTestCase {
    override func tearDown() {
        BindingURLProtocol.handler = nil
        super.tearDown()
    }

    func testClaudeQuotaOwnerComesFromTheSameTokenProfileRatherThanTheSlotLabel() async throws {
        let fixture = try BindingAccountFixture()
        defer { fixture.remove() }
        try fixture.writeClaude(token: "fixture-a")
        try Data(
            #"{"oauthAccount":{"accountUuid":"stale-b","organizationUuid":"team","emailAddress":"b@example.com"}}"#.utf8
        )
        .write(to: fixture.claudeSlot.profileFile)
        let requests = BindingRequestCounter()
        let session = session { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-a")
            requests.increment()
            return Self.response(
                request, body: request.url!.path.hasSuffix("profile") ? Self.claudeProfile("a") : Self.claudeUsage)
        }
        let result = try await ClaudeUsageAccountProvider.fetchOwnedClaudeCodeUsage(
            slot: fixture.claudeSlot, interactive: false, expectedIdentity: Self.claudeIdentity("a"),
            keychain: .none, session: session, cliRefresher: Self.noClaudeRefresh)
        XCTAssertEqual(result.identity, Self.claudeIdentity("a"))
        XCTAssertEqual(result.usage.fiveHour?.utilization, 42)
        XCTAssertEqual(requests.count, 2)
    }

    func testClaudeProfileRejectsAnotherUserInTheSameOrganizationBeforeQuota() async throws {
        let fixture = try BindingAccountFixture()
        defer { fixture.remove() }
        try fixture.writeClaude(token: "fixture-b")
        let requests = BindingRequestCounter()
        let session = session { request in
            requests.increment()
            XCTAssertTrue(request.url!.path.hasSuffix("profile"))
            return Self.response(request, body: Self.claudeProfile("b"))
        }
        do {
            _ = try await ClaudeUsageAccountProvider.fetchOwnedClaudeCodeUsage(
                slot: fixture.claudeSlot, interactive: false, expectedIdentity: Self.claudeIdentity("a"),
                keychain: .none, session: session, cliRefresher: Self.noClaudeRefresh)
            XCTFail("A's row must not receive B's quota")
        } catch { XCTAssertEqual(error as? UsageAccountFetchError, .accountChanged) }
        XCTAssertEqual(requests.count, 1)
    }

    func testPartialClaudeEmailCannotBeReplacedByAnotherProfilesOwner() async throws {
        let fixture = try BindingAccountFixture()
        defer { fixture.remove() }
        try fixture.writeClaude(token: "fixture-b")
        let session = session { Self.response($0, body: Self.claudeProfile("b")) }
        do {
            _ = try await ClaudeUsageAccountProvider.fetchOwnedClaudeCodeUsage(
                slot: fixture.claudeSlot, interactive: false, expectedIdentity: .init(email: "a@example.com"),
                keychain: .none, session: session, cliRefresher: Self.noClaudeRefresh)
            XCTFail("A known email remains an owner boundary")
        } catch { XCTAssertEqual(error as? UsageAccountFetchError, .accountChanged) }
    }

    func testClaudeSourceReplacementDuringQuotaRejectsTheOldResponse() async throws {
        let fixture = try BindingAccountFixture()
        defer { fixture.remove() }
        try fixture.writeClaude(token: "fixture-a")
        let session = session { request in
            if request.url!.path.hasSuffix("profile") { return Self.response(request, body: Self.claudeProfile("a")) }
            try fixture.writeClaude(token: "fixture-b")
            return Self.response(request, body: Self.claudeUsage)
        }
        do {
            _ = try await ClaudeUsageAccountProvider.fetchOwnedClaudeCodeUsage(
                slot: fixture.claudeSlot, interactive: false, expectedIdentity: Self.claudeIdentity("a"),
                keychain: .none, session: session, cliRefresher: Self.noClaudeRefresh)
            XCTFail("A changed source invalidates an otherwise valid A response")
        } catch { XCTAssertEqual(error as? UsageAccountFetchError, .accountChanged) }
    }

    func testMissingClaudeProfileOwnerDoesNotBorrowTheSlotIdentity() async throws {
        let fixture = try BindingAccountFixture()
        defer { fixture.remove() }
        try fixture.writeClaude(token: "fixture-a")
        let session = session {
            Self.response($0, body: #"{"account":{"email":"a@example.com"},"organization":{"uuid":"team"}}"#)
        }
        do {
            _ = try await ClaudeUsageAccountProvider.fetchOwnedClaudeCodeUsage(
                slot: fixture.claudeSlot, interactive: false, expectedIdentity: Self.claudeIdentity("a"),
                keychain: .none, session: session, cliRefresher: Self.noClaudeRefresh)
            XCTFail("The credential's canonical owner is unknown")
        } catch { XCTAssertEqual(error as? UsageAccountFetchError, .unavailable) }
    }

    func testClaudeBindingIsRecheckedAfterTheProviderReturns() async throws {
        let fixture = try BindingAccountFixture()
        defer { fixture.remove() }
        try fixture.writeClaude(token: "fixture-a")
        let session = session { request in
            Self.response(
                request, body: request.url!.path.hasSuffix("profile") ? Self.claudeProfile("a") : Self.claudeUsage)
        }
        let source = UsageAccountSource(role: .directory, reference: fixture.claudeSlot.configDirectory.path)
        let account = UsageAccount(
            id: UsageAccount.id(service: .claude, identity: Self.claudeIdentity("a"), source: source),
            service: .claude, identity: Self.claudeIdentity("a"), sources: [source])
        let suite = "UsageAccountBindingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = ClaudeUsageAccountProvider(
            store: ClaudeAccountStore(
                defaults: defaults, keychainVault: BindingEmptyVault(), postsNotifications: false),
            keychain: .none, session: session, cliRefresher: Self.noClaudeRefresh)
        let result = try await provider.fetchUsage(for: account, interactive: false)
        try await provider.validateFetchBinding(result.binding)
        try fixture.writeClaude(token: "fixture-b")
        do {
            try await provider.validateFetchBinding(result.binding)
            XCTFail("A provider response cannot outlive its credential source")
        } catch { XCTAssertEqual(error as? UsageAccountFetchError, .accountChanged) }
    }

    func testCodexRPCUserMustMatchTheFileEvenWhenTheWorkspaceMatches() async throws {
        let fixture = try BindingAccountFixture()
        defer { fixture.remove() }
        try fixture.writeCodex(email: "a@example.com")
        let owner = BindingCodexOwner { _, workspace, _ in Self.codexQuota(email: "b@example.com", workspace: workspace)
        }
        do {
            _ = try await CodexHomeAccount.fetchOwnedUsage(
                home: fixture.codexHome, expectedIdentity: Self.codexIdentity("a"), owner: owner)
            XCTFail("A workspace ID alone cannot bind the user")
        } catch { XCTAssertEqual(error as? UsageAccountFetchError, .accountChanged) }
    }

    func testCodexSourceReplacementDuringRPCRejectsItsOldOwner() async throws {
        let fixture = try BindingAccountFixture()
        defer { fixture.remove() }
        try fixture.writeCodex(email: "a@example.com")
        let owner = BindingCodexOwner { _, workspace, _ in
            try fixture.writeCodex(email: "b@example.com")
            return Self.codexQuota(email: "a@example.com", workspace: workspace)
        }
        do {
            _ = try await CodexHomeAccount.fetchOwnedUsage(
                home: fixture.codexHome, expectedIdentity: Self.codexIdentity("a"), owner: owner)
            XCTFail("The RPC result does not belong to the current source")
        } catch { XCTAssertEqual(error as? UsageAccountFetchError, .accountChanged) }
    }

    func testCodexOwnerMayRotateTokensWithoutChangingItsVerifiedUser() async throws {
        let fixture = try BindingAccountFixture()
        defer { fixture.remove() }
        try fixture.writeCodex(email: "a@example.com", token: "fixture-old")
        let owner = BindingCodexOwner { _, workspace, _ in
            try fixture.writeCodex(email: "a@example.com", token: "fixture-rotated")
            return Self.codexQuota(email: "a@example.com", workspace: workspace)
        }
        let result = try await CodexHomeAccount.fetchOwnedUsage(
            home: fixture.codexHome, expectedIdentity: Self.codexIdentity("a"), owner: owner)
        XCTAssertEqual(result.identity, Self.codexIdentity("a"))
        XCTAssertEqual(result.usage.sessionWindow?.utilization, 42)
        let provider = CodexUsageAccountProvider(owner: owner)
        let binding = UsageAccountFetchBinding(
            account: .init(
                source: .init(role: .directory, reference: fixture.codexHome.path), identity: result.identity),
            credentialRevision: result.credentialRevision)
        try await provider.validateFetchBinding(binding)
        try fixture.writeCodex(email: "b@example.com", token: "fixture-other")
        do {
            try await provider.validateFetchBinding(binding)
            XCTFail("The returned source proof cannot match a replacement login")
        } catch { XCTAssertEqual(error as? UsageAccountFetchError, .accountChanged) }
    }

    func testCodexCapturedPartialEmailAndWorkspaceMismatchStopBeforeRPC() async throws {
        for expected in [
            UsageAccountIdentity(email: "b@example.com"), .init(organizationID: "other", email: "a@example.com"),
        ] {
            let fixture = try BindingAccountFixture()
            defer { fixture.remove() }
            try fixture.writeCodex(email: "a@example.com")
            let owner = BindingCodexOwner { _, _, _ in
                XCTFail("A known owner mismatch must not query another login")
                throw CodexOwnerError.invalidResponse
            }
            do {
                _ = try await CodexHomeAccount.fetchOwnedUsage(
                    home: fixture.codexHome, expectedIdentity: expected, owner: owner)
                XCTFail("A contradictory captured identity must stop")
            } catch { XCTAssertEqual(error as? UsageAccountFetchError, .accountChanged) }
        }
    }

    func testCodexMissingFileEmailIsUnknownRatherThanAWorkspaceOwner() async throws {
        let fixture = try BindingAccountFixture()
        defer { fixture.remove() }
        try fixture.writeCodex(email: nil)
        let owner = BindingCodexOwner { _, _, _ in
            XCTFail("An unidentified credential must not borrow the row owner")
            throw CodexOwnerError.invalidResponse
        }
        do {
            _ = try await CodexHomeAccount.fetchOwnedUsage(
                home: fixture.codexHome, expectedIdentity: Self.codexIdentity("a"), owner: owner)
            XCTFail("The source user is unknown")
        } catch { XCTAssertEqual(error as? UsageAccountFetchError, .unavailable) }
    }

    private func session(_ handler: @escaping BindingURLProtocol.Handler) -> URLSession {
        BindingURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BindingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    nonisolated private static var noClaudeRefresh: ClaudeCodeCredentialReader.CLIRefresher {
        { _ in
            XCTFail("Unexpired fixture credentials must not run an installed CLI"); return .unavailable
        }
    }
    nonisolated private static func claudeIdentity(_ user: String) -> UsageAccountIdentity {
        .init(accountID: user, organizationID: "team", email: user + "@example.com")
    }
    nonisolated private static func codexIdentity(_ user: String) -> UsageAccountIdentity {
        .init(accountID: user + "@example.com", organizationID: "team", email: user + "@example.com")
    }
    nonisolated private static func claudeProfile(_ user: String) -> String {
        "{\"account\":{\"uuid\":\"\(user)\",\"email\":\"\(user)@example.com\"},\"organization\":{\"uuid\":\"team\"}}"
    }
    nonisolated private static var claudeUsage: String { #"{"five_hour":{"utilization":42,"resets_at":null}}"# }
    nonisolated private static func response(_ request: URLRequest, body: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
    }
    nonisolated private static func codexQuota(email: String, workspace: String) -> CodexOwnedRateLimits {
        .init(
            email: email, accountID: workspace,
            quota: .init(value: [
                "accountId": workspace,
                "rateLimits": ["primary": ["usedPercent": 42, "windowDurationMins": 300, "resetsAt": 1_790_000_000]],
            ]))
    }
}

private nonisolated struct BindingAccountFixture: Sendable {
    let root: URL
    var claudeSlot: ClaudeCodeLoginSlot { .folderSlot(root.appendingPathComponent("claude"), home: root) }
    var codexHome: URL { root.appendingPathComponent("codex") }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("UsageBinding-\(UUID().uuidString)")
        for path in [root.appendingPathComponent("claude"), root.appendingPathComponent("codex")] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
    }
    func writeClaude(token: String) throws {
        try JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["accessToken": token]])
            .write(to: claudeSlot.credentialFiles[0], options: .atomic)
    }
    func writeCodex(email: String?, token: String = "fixture") throws {
        let claims = try JSONSerialization.data(withJSONObject: email.map { ["email": $0] } ?? [:])
            .base64EncodedString().replacingOccurrences(of: "=", with: "")
        try JSONSerialization.data(withJSONObject: [
            "tokens": [
                "account_id": "team", "access_token": token, "id_token": "header." + claims + ".signature",
            ]
        ]).write(to: CodexHomeAccount.authFile(in: codexHome), options: .atomic)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private nonisolated struct BindingCodexOwner: CodexOwnedRateLimitsReading {
    let read: @Sendable (URL, String, CodexRequestBudget) async throws -> CodexOwnedRateLimits
    init(_ read: @escaping @Sendable (URL, String, CodexRequestBudget) async throws -> CodexOwnedRateLimits) {
        self.read = read
    }
    func readOwnedRateLimits(sourceURL: URL, expectedAccountID: String, budget: CodexRequestBudget) async throws
        -> CodexOwnedRateLimits
    {
        try await read(sourceURL, expectedAccountID, budget)
    }
}

private nonisolated struct BindingEmptyVault: ClaudeSessionKeyVault {
    func saveString(_ value: String, account: String) throws {}
    func loadString(account: String) throws -> String? { nil }
    func delete(account: String) throws {}
}

private nonisolated final class BindingRequestCounter: @unchecked Sendable {
    private let countLock = NSLock()
    private var value = 0
    var count: Int { countLock.withLock { value } }
    func increment() { countLock.withLock { value += 1 } }
}

private final class BindingURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> (HTTPURLResponse, Data)
    private static let handlerState = OSAllocatedUnfairLock<Handler?>(initialState: nil)
    static var handler: Handler? {
        get { handlerState.withLock { $0 } }
        set { handlerState.withLock { $0 = newValue } }
    }
    private let loading = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { return }
        let request = request
        let task = Task {
            do {
                let (response, data) = try await handler(request)
                guard !Task.isCancelled else { return }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                guard !Task.isCancelled else { return }
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
        loading.withLock { $0 = task }
    }
    override func stopLoading() {
        loading.withLock {
            $0?.cancel(); $0 = nil
        }
    }
}
