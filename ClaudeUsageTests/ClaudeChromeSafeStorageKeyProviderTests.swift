import Foundation
import XCTest
@testable import ClaudeUsage

final class ClaudeChromeSafeStorageKeyProviderTests: XCTestCase {
    func testAlreadyAuthorizedSafeStorageUsesNoUIReadOnly() throws {
        let spy = SafeStorageReaderSpy(
            noninteractive: { _, _ in .value("safe-storage-password") },
            interactive: { _, _, _ in .failure(Int(errSecInternalError)) }
        )
        let provider = ClaudeChromeSafeStorageKeyProvider(
            labels: [ClaudeChromeSafeStorageLabel(service: "Chrome Safe Storage", account: "Chrome")],
            payloadReader: { service, account in
                spy.readWithoutUI(service: service, account: account)
            },
            interactivePayloadReader: { service, account, reason in
                spy.readInteractively(service: service, account: account, reason: reason)
            }
        )

        let keys = try provider.loadDerivedKeysForUserInitiatedImport()

        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(spy.noninteractiveCallCount, 1)
        XCTAssertEqual(spy.interactiveCallCount, 0)
    }

    func testInteractionRequiredPromptsExactItemOnce() throws {
        let spy = SafeStorageReaderSpy(
            noninteractive: { service, _ in
                service == "Legacy Safe Storage" ? .notFound : .interactionRequired
            },
            interactive: { _, _, _ in .value("safe-storage-password") }
        )
        let provider = ClaudeChromeSafeStorageKeyProvider(
            labels: [
                ClaudeChromeSafeStorageLabel(service: "Legacy Safe Storage", account: "Chrome"),
                ClaudeChromeSafeStorageLabel(service: "Chrome Safe Storage", account: "Chrome"),
                ClaudeChromeSafeStorageLabel(service: "Unused Safe Storage", account: "Chrome"),
            ],
            payloadReader: { service, account in
                spy.readWithoutUI(service: service, account: account)
            },
            interactivePayloadReader: { service, account, reason in
                spy.readInteractively(service: service, account: account, reason: reason)
            }
        )

        let keys = try provider.loadDerivedKeysForUserInitiatedImport()

        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(spy.noninteractiveServices, ["Legacy Safe Storage", "Chrome Safe Storage"])
        XCTAssertEqual(spy.interactiveServices, ["Chrome Safe Storage"])
    }

    func testCancelledPromptStopsCandidateFallback() {
        let spy = SafeStorageReaderSpy(
            noninteractive: { _, _ in .interactionRequired },
            interactive: { _, _, _ in .cancelled }
        )
        let provider = ClaudeChromeSafeStorageKeyProvider(
            labels: [
                ClaudeChromeSafeStorageLabel(service: "Chrome Safe Storage", account: "Chrome"),
                ClaudeChromeSafeStorageLabel(service: "Unused Safe Storage", account: "Chrome"),
            ],
            payloadReader: { service, account in
                spy.readWithoutUI(service: service, account: account)
            },
            interactivePayloadReader: { service, account, reason in
                spy.readInteractively(service: service, account: account, reason: reason)
            }
        )

        XCTAssertThrowsError(try provider.loadDerivedKeysForUserInitiatedImport()) { error in
            XCTAssertEqual(error as? ClaudeChromeSafeStorageKeyError, .cancelled)
        }
        XCTAssertEqual(spy.noninteractiveCallCount, 1)
        XCTAssertEqual(spy.interactiveCallCount, 1)
    }

    func testMultipleProfilesShareOneSafeStorageKeyLoad() throws {
        let pipeline = ChromeImportPipelineSpy()
        let candidates = [
            ClaudeBrowserSessionCandidate(
                family: .chrome,
                profileName: "Default",
                cookiesPath: URL(fileURLWithPath: "/tmp/Default/Cookies"),
                supportsAutomaticImport: true
            ),
            ClaudeBrowserSessionCandidate(
                family: .chrome,
                profileName: "Profile 1",
                cookiesPath: URL(fileURLWithPath: "/tmp/Profile 1/Cookies"),
                supportsAutomaticImport: true
            ),
        ]
        let service = ClaudeChromeCookieImportService(
            candidateProvider: { candidates },
            decryptionKeyProvider: {
                try pipeline.loadKeys()
            },
            cookieReader: { cookiesURL, profileName, decryptionKeys in
                try pipeline.readCookies(
                    cookiesURL: cookiesURL,
                    profileName: profileName,
                    decryptionKeys: decryptionKeys
                )
            }
        )

        let outcome = try service.attemptImport()

        guard case .importedSessionCandidates(let sessions) = outcome else {
            return XCTFail("두 프로필의 가져오기 결과가 필요합니다.")
        }
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(pipeline.keyLoadCount, 1)
        XCTAssertEqual(pipeline.cookieReadCount, 2)
        XCTAssertTrue(pipeline.allCookieReadsReceivedSharedKey)
    }

    func testImportIgnoresLookalikeClaudeDomains() throws {
        let candidate = ClaudeBrowserSessionCandidate(
            family: .chrome,
            profileName: "Default",
            cookiesPath: URL(fileURLWithPath: "/tmp/Default/Cookies"),
            supportsAutomaticImport: true
        )
        let service = ClaudeChromeCookieImportService(
            candidateProvider: { [candidate] },
            decryptionKeyProvider: { [] },
            cookieReader: { _, _, _ in
                [
                    ClaudeChromiumCookieRecord(
                        domain: "evilclaude.ai",
                        name: "sessionKey",
                        path: "/",
                        value: "sk-ant-lookalike-domain-0123456789",
                        expiresAt: nil,
                        isSecure: true
                    ),
                    ClaudeChromiumCookieRecord(
                        domain: "claude.ai.evil.example",
                        name: "sessionKey",
                        path: "/",
                        value: "sk-ant-suffix-lookalike-0123456789",
                        expiresAt: nil,
                        isSecure: true
                    ),
                    ClaudeChromiumCookieRecord(
                        domain: ".claude.ai",
                        name: "sessionKey",
                        path: "/",
                        value: "sk-ant-valid-claude-domain-0123456789",
                        expiresAt: nil,
                        isSecure: true
                    ),
                ]
            }
        )

        let outcome = try service.attemptImport()

        guard case .importedSession(let session) = outcome else {
            return XCTFail("실제 Claude 도메인의 세션만 가져와야 합니다.")
        }
        XCTAssertEqual(session.sessionKey, "sk-ant-valid-claude-domain-0123456789")
    }
}

private final class SafeStorageReaderSpy: @unchecked Sendable {
    typealias NoninteractiveHandler = @Sendable (
        String,
        String?
    ) -> KeychainAccessPreflight.ReadOutcome
    typealias InteractiveHandler = @Sendable (
        String,
        String?,
        String
    ) -> KeychainAccessPreflight.ReadOutcome

    private let lock = NSLock()
    private let noninteractive: NoninteractiveHandler
    private let interactive: InteractiveHandler
    private var noninteractiveCalls: [String] = []
    private var interactiveCalls: [String] = []

    init(
        noninteractive: @escaping NoninteractiveHandler,
        interactive: @escaping InteractiveHandler
    ) {
        self.noninteractive = noninteractive
        self.interactive = interactive
    }

    var noninteractiveCallCount: Int {
        lock.withLock { noninteractiveCalls.count }
    }

    var interactiveCallCount: Int {
        lock.withLock { interactiveCalls.count }
    }

    var noninteractiveServices: [String] {
        lock.withLock { noninteractiveCalls }
    }

    var interactiveServices: [String] {
        lock.withLock { interactiveCalls }
    }

    func readWithoutUI(
        service: String,
        account: String?
    ) -> KeychainAccessPreflight.ReadOutcome {
        lock.withLock {
            noninteractiveCalls.append(service)
        }
        return noninteractive(service, account)
    }

    func readInteractively(
        service: String,
        account: String?,
        reason: String
    ) -> KeychainAccessPreflight.ReadOutcome {
        lock.withLock {
            interactiveCalls.append(service)
        }
        return interactive(service, account, reason)
    }
}

private final class ChromeImportPipelineSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var keyLoads = 0
    private var cookieReads = 0
    private var receivedKeys: [[Data]] = []
    private let sharedKey = Data([0x01, 0x02, 0x03])

    var keyLoadCount: Int {
        lock.withLock { keyLoads }
    }

    var cookieReadCount: Int {
        lock.withLock { cookieReads }
    }

    var allCookieReadsReceivedSharedKey: Bool {
        lock.withLock {
            receivedKeys.count == cookieReads
                && receivedKeys.allSatisfy { $0 == [sharedKey] }
        }
    }

    func loadKeys() throws -> [Data] {
        lock.withLock {
            keyLoads += 1
        }
        return [sharedKey]
    }

    func readCookies(
        cookiesURL: URL,
        profileName: String,
        decryptionKeys: [Data]
    ) throws -> [ClaudeChromiumCookieRecord] {
        _ = cookiesURL
        lock.withLock {
            cookieReads += 1
            receivedKeys.append(decryptionKeys)
        }
        return [
            ClaudeChromiumCookieRecord(
                domain: ".claude.ai",
                name: "sessionKey",
                path: "/",
                value: "sk-ant-\(profileName.replacingOccurrences(of: " ", with: "-"))-0123456789",
                expiresAt: nil,
                isSecure: true
            ),
        ]
    }
}
