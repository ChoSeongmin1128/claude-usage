import Foundation

/// Codex 계정: 기본 로그인(`~/.codex`, CLI와 ChatGPT 앱이 함께 씀), 다른 CODEX_HOME 폴더, 앱이 만든 계정 폴더.
/// 메뉴바에는 기본 로그인만 오므로 다른 계정은 기본 로그인을 전환해야 메뉴바에 나온다.
@MainActor
final class CodexUsageAccountProvider: UsageAccountProvider {
    let service = PopoverService.codex
    let cliName = "Codex"
    let configDirectoryVariable = "CODEX_HOME"
    let addMethods: [UsageAccountAddMethod] = [.deviceLogin, .folder]
    var managedDirectoryRoot: URL? { AppStoragePaths.codexAccountsDirectory() }
    let menuBar: (any UsageAccountMenuBarPolicy)? = nil
    private let owner: any CodexOwnedRateLimitsReading

    init(owner: any CodexOwnedRateLimitsReading = CodexOwnerCLI()) {
        self.owner = owner
    }

    func discoveryInput(directories: [String], knownIdentities: [String: UsageAccountIdentity])
        -> UsageAccountDiscoveryInput
    {
        UsageAccountDiscoveryInput(directories: directories)
    }

    nonisolated func candidates(_ input: UsageAccountDiscoveryInput) -> [UsageAccountCandidate] {
        var result: [UsageAccountCandidate] = []
        let defaultHome = CodexAuthManager.defaultHomeURL
        if let identity = CodexHomeAccount.identity(home: defaultHome) {
            result.append(.init(source: .init(role: .defaultLogin, reference: defaultHome.path), identity: identity))
        }
        let homes =
            CodexHomeAccount.discoverHomes(managedRoot: AppStoragePaths.codexAccountsDirectory()).map(\.path)
            + input.directories
        var seen: Set<String> = [defaultHome.path]
        for path in homes where seen.insert(path).inserted {
            guard let identity = CodexHomeAccount.identity(home: URL(fileURLWithPath: path)) else { continue }
            result.append(.init(source: .init(role: .directory, reference: path), identity: identity))
        }
        return result
    }

    func badgeHelp(for role: UsageAccountSource.Role) -> String {
        switch role {
        case .defaultLogin: return "CLI와 ChatGPT 앱이 함께 쓰는 기본 로그인(~/.codex)"
        case .directory: return "다른 폴더의 Codex 로그인"
        case .web: return "앱에 저장된 웹 로그인"
        }
    }

    func isRuntime(_ account: UsageAccount) -> Bool { account.isDefaultLogin }

    /// 읽고 검증한 credential snapshot을 사용한다. 디스크를 다시 읽으면 다른 로그인일 수 있다.
    nonisolated static func runtimeAccount(for result: CodexUsageSnapshot) -> UsageAccountCandidate {
        let email = result.credential.token.idToken.flatMap(JWTClaims.decode)?["email"] as? String
        let identity = UsageAccountIdentity(
            accountID: email, organizationID: result.usage.accountID ?? result.credential.token.accountID,
            email: email)
        return UsageAccountCandidate(
            source: .init(role: .defaultLogin, reference: result.credential.sourceURL.deletingLastPathComponent().path),
            identity: identity)
    }

    func runtimeUsage(from snapshot: RuntimeProviderSnapshot) -> UsageAccountUsage? {
        snapshot.codexUsage.map(UsageAccountUsage.init(codex:))
    }

    func fetchUsage(for account: UsageAccount, interactive: Bool) async throws -> UsageAccountFetchResult {
        guard let directory = account.source(.directory) else { throw UsageAccountFetchError.unavailable }
        let result = try await CodexHomeAccount.fetchOwnedUsage(
            home: URL(fileURLWithPath: directory.reference), expectedIdentity: account.identity, owner: owner)
        return UsageAccountFetchResult(
            usage: UsageAccountUsage(codex: result.usage),
            binding: .init(
                account: .init(source: directory, identity: result.identity),
                credentialRevision: result.credentialRevision))
    }

    func validateFetchBinding(_ binding: UsageAccountFetchBinding) async throws {
        guard binding.account.source.role == .directory else { throw UsageAccountFetchError.accountChanged }
        let revision: String
        do {
            revision = try await CodexHomeAccount.currentCredentialRevision(
                home: URL(fileURLWithPath: binding.account.source.reference))
        } catch is CancellationError { throw CancellationError() } catch {
            throw UsageAccountFetchError.accountChanged
        }
        try Task.checkCancellation()
        guard revision == binding.credentialRevision else { throw UsageAccountFetchError.accountChanged }
    }

    func canSwitch(to account: UsageAccount) -> Bool {
        !account.isDefaultLogin && account.source(.directory) != nil && account.identity.organizationID != nil
    }

    func switchPlan(for account: UsageAccount, name: String) -> UsageAccountSwitchPlan {
        let running = CodexAccountSwitcher.runningCodex()
        let moved = "지금 로그인은 그 계정이 있던 폴더로 옮깁니다."
        guard !running.isEmpty else {
            return UsageAccountSwitchPlan(
                message: "\(name) 계정으로 기본 Codex 로그인을 전환합니다. \(moved)", confirmTitle: "전환",
                terminatesRunningApps: false)
        }
        let parts = [
            running.applications.isEmpty ? nil : "ChatGPT 앱",
            running.processes.isEmpty ? nil : "터미널의 codex \(running.processes.count)개",
        ].compactMap { $0 }
        return UsageAccountSwitchPlan(
            message: "실행 중인 \(parts.joined(separator: ", "))를 종료하고 \(name) 계정으로 기본 Codex 로그인을 전환합니다. \(moved)",
            confirmTitle: "종료하고 전환", terminatesRunningApps: true)
    }

    func switchDefault(to account: UsageAccount, plan: UsageAccountSwitchPlan) async throws {
        guard let directory = account.source(.directory), let workspace = account.identity.organizationID else {
            throw AccountSwitchError.unavailable
        }
        // 확인 창을 띄운 사이 실행 상태가 바뀌었을 수 있어 다시 본다.
        let running = await Task.detached { CodexAccountSwitcher.runningCodex() }.value
        if !running.isEmpty {
            guard plan.terminatesRunningApps else { throw AccountSwitchError.runningAppsStarted }
            guard await CodexAccountSwitcher.terminate(running) else {
                throw AccountSwitchError.runningAppsNotTerminated
            }
        }
        try await CodexAccountSwitcher.switchDefault(
            to: URL(fileURLWithPath: directory.reference), expectedWorkspaceID: workspace)
    }
}
