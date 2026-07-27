import Foundation
import Combine

@MainActor
final class AntigravityOAuthSettingsViewModel: ObservableObject {
    @Published private(set) var isLoggingIn = false
    @Published private(set) var accounts: [AntigravityOAuthAccount] = []
    @Published private(set) var activeAccountID: String?
    @Published var message: String?

    private var loginTask: Task<Void, Never>?
    private var activeLoginID: UUID?
    private let loginRunner: () async -> AntigravityOAuthLoginRunner.Result
    private let accountStore: AntigravityOAuthAccountStore

    init(
        loginRunner: @escaping () async -> AntigravityOAuthLoginRunner.Result = {
            await AntigravityOAuthLoginRunner.run()
        },
        accountStore: AntigravityOAuthAccountStore = AntigravityOAuthAccountStore()
    ) {
        self.loginRunner = loginRunner
        self.accountStore = accountStore
        refreshAccounts()
    }

    func connect(
        settings: AppSettings,
        refreshEnvironment: @escaping @MainActor () -> Void
    ) {
        guard !isLoggingIn else { return }
        isLoggingIn = true
        message = "Google 로그인 창을 준비하는 중입니다. 창이 뜨면 브라우저에서 로그인을 완료해 주세요."
        loginTask?.cancel()
        let loginID = UUID()
        activeLoginID = loginID
        loginTask = Task { @MainActor [weak self, settings, loginRunner] in
            let result = await loginRunner()
            guard let self, self.activeLoginID == loginID else { return }
            self.finishLogin(
                result,
                settings: settings,
                refreshEnvironment: refreshEnvironment
            )
        }
    }

    func disconnect(refreshEnvironment: @escaping @MainActor () -> Void) {
        do {
            if let activeAccountID {
                try accountStore.deleteAccount(id: activeAccountID)
                message = "선택한 Antigravity Google 계정 연결을 해제했습니다."
            } else {
                try accountStore.deleteAll()
                message = "ClaudeUsage에 저장된 Antigravity Google 계정 연결을 해제했습니다."
            }
            refreshAccounts()
            refreshEnvironment()
        } catch {
            message = "Google 계정 연결 해제 실패: \(error.localizedDescription)"
        }
    }

    func disconnectAll(refreshEnvironment: @escaping @MainActor () -> Void) {
        do {
            try accountStore.deleteAll()
            refreshAccounts()
            message = "ClaudeUsage에 저장된 모든 Antigravity Google 계정 연결을 해제했습니다."
            refreshEnvironment()
        } catch {
            message = "Google 계정 연결 전체 해제 실패: \(error.localizedDescription)"
        }
    }

    func selectAccount(
        id: String,
        refreshEnvironment: @escaping @MainActor () -> Void
    ) {
        do {
            let state = try accountStore.setActiveAccountID(id)
            apply(state)
            let label = state.activeAccount?.label ?? "선택한 계정"
            message = "\(label) 계정으로 전환했습니다."
            refreshEnvironment()
        } catch {
            message = "Google 계정 전환 실패: \(error.localizedDescription)"
        }
    }

    func refreshAccounts() {
        do {
            apply(try accountStore.syncActiveCredentialIfNeeded())
        } catch {
            apply(accountStore.state())
        }
    }

    func cancelLogin() {
        loginTask?.cancel()
        loginTask = nil
        activeLoginID = nil
        if isLoggingIn {
            message = "Google 로그인을 취소했습니다."
        }
        isLoggingIn = false
    }

    private func finishLogin(
        _ result: AntigravityOAuthLoginRunner.Result,
        settings: AppSettings,
        refreshEnvironment: @escaping @MainActor () -> Void
    ) {
        isLoggingIn = false
        loginTask = nil
        activeLoginID = nil

        switch result.outcome {
        case .success(let credentials):
            do {
                let state = try accountStore.upsert(credentials, makeActive: true)
                apply(state)
            } catch {
                message = "Google 계정 저장 실패: \(error.localizedDescription)"
                return
            }
            message = credentials.email.map { "\($0) 계정을 연결했습니다." }
                ?? "Google 계정을 연결했습니다."
            refreshEnvironment()
        case .cancelled:
            message = "Google 로그인을 취소했습니다."
        case .timedOut:
            message = "Google 로그인이 시간 초과되었습니다."
        case .launchFailed(let url):
            message = "브라우저를 열지 못했습니다: \(url)"
        case .failed(let message):
            self.message = message
        }
    }

    private func apply(_ state: AntigravityOAuthAccountState) {
        accounts = state.accounts
        activeAccountID = state.activeAccountID
    }
}
