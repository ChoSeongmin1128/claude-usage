import XCTest
@testable import ClaudeUsage

@MainActor
final class AntigravityOAuthSettingsViewModelTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var credentialURL: URL!
    private var accountURL: URL!
    private var credentialStore: AntigravityOAuthCredentialsStore!
    private var accountStore: AntigravityOAuthAccountStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeUsageTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        credentialURL = AntigravityOAuthCredentialsStore.defaultURL(home: temporaryDirectory)
        accountURL = AntigravityOAuthAccountStore.defaultURL(home: temporaryDirectory)
        credentialStore = AntigravityOAuthCredentialsStore(
            fileURL: credentialURL,
            fileManager: .default,
            legacyKeychainStore: nil
        )
        accountStore = AntigravityOAuthAccountStore(
            fileURL: accountURL,
            fileManager: .default,
            activeCredentialStore: credentialStore
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        accountStore = nil
        credentialStore = nil
        accountURL = nil
        credentialURL = nil
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    func testConnectSuccessStoresAccountSelectsAutoSourceAndRefreshesEnvironment() async throws {
        let settings = AppSettings.shared
        let snapshot = settings.createSnapshot()
        defer { settings.restore(from: snapshot) }
        settings.antigravityUsageDataSource = .localIDE
        var refreshCount = 0
        let credentials = makeCredentials(email: "new@example.com")
        let viewModel = AntigravityOAuthSettingsViewModel(
            loginRunner: {
                AntigravityOAuthLoginRunner.Result(outcome: .success(credentials))
            },
            accountStore: accountStore
        )

        viewModel.connect(settings: settings) {
            refreshCount += 1
        }

        try await waitUntil {
            !viewModel.isLoggingIn && viewModel.accounts.count == 1
        }

        XCTAssertEqual(viewModel.accounts.map(\.email), ["new@example.com"])
        XCTAssertEqual(viewModel.activeAccountID, viewModel.accounts.first?.id)
        XCTAssertEqual(try credentialStore.load()?.email, "new@example.com")
        XCTAssertEqual(settings.antigravityUsageDataSource, .auto)
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(viewModel.message, "new@example.com 계정을 연결했습니다.")
    }

    func testSelectAccountSwitchesActiveCredentialAndRefreshesEnvironment() async throws {
        let first = makeCredentials(email: "first@example.com")
        let second = makeCredentials(email: "second@example.com")
        try accountStore.upsert(first, makeActive: true)
        try accountStore.upsert(second, makeActive: true)
        let viewModel = AntigravityOAuthSettingsViewModel(
            loginRunner: { AntigravityOAuthLoginRunner.Result(outcome: .cancelled) },
            accountStore: accountStore
        )
        let firstID = try XCTUnwrap(viewModel.accounts.first(where: { $0.email == "first@example.com" })?.id)
        var refreshCount = 0

        viewModel.selectAccount(id: firstID) {
            refreshCount += 1
        }

        XCTAssertEqual(viewModel.activeAccountID, firstID)
        XCTAssertEqual(try credentialStore.load()?.email, "first@example.com")
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(viewModel.message, "first@example.com 계정으로 전환했습니다.")
    }

    func testDisconnectRemovesSelectedAccountThenClearsLastAccount() async throws {
        try accountStore.upsert(makeCredentials(email: "first@example.com"), makeActive: true)
        try accountStore.upsert(makeCredentials(email: "second@example.com"), makeActive: true)
        let viewModel = AntigravityOAuthSettingsViewModel(
            loginRunner: { AntigravityOAuthLoginRunner.Result(outcome: .cancelled) },
            accountStore: accountStore
        )
        var refreshCount = 0

        viewModel.disconnect {
            refreshCount += 1
        }

        XCTAssertEqual(viewModel.accounts.map(\.email), ["first@example.com"])
        XCTAssertEqual(try credentialStore.load()?.email, "first@example.com")
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(viewModel.message, "선택한 Antigravity Google 계정 연결을 해제했습니다.")

        viewModel.disconnect {
            refreshCount += 1
        }

        XCTAssertTrue(viewModel.accounts.isEmpty)
        XCTAssertNil(viewModel.activeAccountID)
        XCTAssertNil(try credentialStore.load())
        XCTAssertEqual(refreshCount, 2)
    }

    func testDisconnectAllRemovesEveryAccountAndRefreshesEnvironmentOnce() async throws {
        try accountStore.upsert(makeCredentials(email: "first@example.com"), makeActive: true)
        try accountStore.upsert(makeCredentials(email: "second@example.com"), makeActive: true)
        let viewModel = AntigravityOAuthSettingsViewModel(
            loginRunner: { AntigravityOAuthLoginRunner.Result(outcome: .cancelled) },
            accountStore: accountStore
        )
        var refreshCount = 0

        viewModel.disconnectAll {
            refreshCount += 1
        }

        XCTAssertTrue(viewModel.accounts.isEmpty)
        XCTAssertNil(viewModel.activeAccountID)
        XCTAssertNil(try credentialStore.load())
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(viewModel.message, "ClaudeUsage에 저장된 모든 Antigravity Google 계정 연결을 해제했습니다.")
    }

    func testCancelLoginIgnoresLateSuccess() async throws {
        let settings = AppSettings.shared
        let snapshot = settings.createSnapshot()
        defer { settings.restore(from: snapshot) }
        var continuation: CheckedContinuation<AntigravityOAuthLoginRunner.Result, Never>?
        var refreshCount = 0
        let viewModel = AntigravityOAuthSettingsViewModel(
            loginRunner: {
                await withCheckedContinuation { pending in
                    continuation = pending
                }
            },
            accountStore: accountStore
        )

        viewModel.connect(settings: settings) {
            refreshCount += 1
        }
        XCTAssertTrue(viewModel.isLoggingIn)

        viewModel.cancelLogin()
        XCTAssertFalse(viewModel.isLoggingIn)
        XCTAssertEqual(viewModel.message, "Google 로그인을 취소했습니다.")

        continuation?.resume(returning: AntigravityOAuthLoginRunner.Result(
            outcome: .success(makeCredentials(email: "late@example.com"))
        ))
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertTrue(viewModel.accounts.isEmpty)
        XCTAssertNil(try credentialStore.load())
        XCTAssertEqual(refreshCount, 0)
        XCTAssertEqual(viewModel.message, "Google 로그인을 취소했습니다.")
    }

    private func makeCredentials(email: String) -> AntigravityOAuthCredentials {
        AntigravityOAuthCredentials(
            accessToken: "access-\(email)",
            refreshToken: "refresh-\(email)",
            expiryDate: Date(timeIntervalSince1970: 1_800_000_000),
            idToken: "id-\(email)",
            email: email,
            projectID: "project-\(email)",
            clientID: "client-id",
            clientSecret: "client-secret"
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("조건이 시간 내 충족되지 않았습니다")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
