import AppKit

extension AppDelegate {
    var hasWebAuthenticationFailure: Bool {
        guard ClaudeAccountStore.shared.activeWebAccount() != nil else { return false }
        if case .invalidSessionKey = currentError { return true }
        return false
    }

    func webRecoveryRequest(account: UsageAccount? = nil) -> ClaudeWebSessionRecoveryCoordinator.Request? {
        let state = ClaudeAccountStore.shared.state()
        let reference = account.flatMap {
            ClaudeUsageAccountProvider.webRecoveryReference(in: $0, activeAccountID: state.activeAccountID)
        } ?? state.activeAccount?.id
        guard let stored = state.accounts.first(where: { $0.id == reference }), stored.isWebSession,
              let activeID = state.activeAccountID else { return nil }
        let identity = usageAccountsController.preferences.knownIdentities[stored.id]
        let source = UsageAccountSource(role: .web, reference: stored.id)
        return .init(account: stored, expectedIdentity: identity,
            previousAccountID: account?.id ?? UsageAccount.id(service: .claude,
                identity: identity ?? .init(), source: source), activeAccountID: activeID)
    }

    /// Only explicit user actions enter this path. Periodic refresh never reads browser credentials.
    func retryClaudeUsageFromUser(reconnect: Bool = false, account: UsageAccount? = nil) {
        guard claudeWebRetryTask == nil else { return }
        claudeWebRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { claudeWebRetryTask = nil }
            if !reconnect, !hasWebAuthenticationFailure {
                await refreshUsage(force: true)?.value
                guard hasWebAuthenticationFailure else { return }
            }
            guard let request = webRecoveryRequest(account: account) else {
                if reconnect { showLoginWindow() }
                return
            }
            claudeManualSessionIntent = .recoverExisting
            do {
                try await claudeWebRecovery.recover(request)
            } catch is CancellationError { return }
            catch ClaudeWebSessionRecoveryCoordinator.Failure.loginRequired {
                guard ClaudeAccountStore.shared.state().activeAccountID == request.activeAccountID else { return }
                if request.account.source == .embeddedWebLogin {
                    showLoginWindow(startEmbeddedWebOnOpen: true, replacingWebConnection: request)
                } else if request.account.source == .manualInput {
                    pendingClaudeWebRecovery = request
                    AppSettings.shared.shouldRevealClaudeAdvancedAuth = true
                    showSettingsWindow(settingsPanelRawValue: SettingsProviderPanel.claude.rawValue)
                } else {
                    showWebRecoveryError(ClaudeWebSessionRecoveryCoordinator.Failure.loginRequired)
                }
            } catch { showWebRecoveryError(error) }
        }
    }

    func makeClaudeWebRecovery() -> ClaudeWebSessionRecoveryCoordinator {
        ClaudeWebSessionRecoveryCoordinator(dependencies: .init(
            load: { KeychainManager.shared.load(for: $0, bypassCache: true) },
            importSession: { try ClaudeBrowserLoginDetector.importer(for: $0.family).attemptImport(source: $0) },
            validate: { key, organization in
                let validator = ClaudeAPIService(sessionKey: key)
                await validator.updatePreferredOrganizationID(organization ?? "")
                return try await validator.validateWebSession()
            },
            selectSource: { await Self.selectWebRecoverySource() },
            confirmIdentity: { identity in
                let alert = NSAlert()
                alert.messageText = "이 계정으로 기존 웹 연결을 복구할까요?"
                alert.informativeText = "기존 연결에는 확인된 계정 정보가 없습니다.\n\(identity.email ?? "")\n\(identity.organizationName ?? "")"
                alert.addButton(withTitle: "연결")
                alert.addButton(withTitle: "취소")
                return alert.runModal() == .alertFirstButtonReturn
            },
            isCurrent: { [weak self] request in
                let state = ClaudeAccountStore.shared.state()
                return self?.isTerminating == false && state.activeAccountID == request.activeAccountID
                    && state.accounts.contains(request.account)
            },
            commit: { [weak self] request, candidate in
                guard let self else { throw CancellationError() }
                let replacement = try ClaudeWebSessionReplacement(store: .shared, vault: ClaudeKeychainStore.shared).replace(
                    account: request.account, sessionKey: candidate.sessionKey, validation: candidate.validation,
                    browserSource: candidate.browserSource,
                    expectedPreferences: UsageAccountPreferences.load(), previousAccountID: request.previousAccountID,
                    expectedActiveAccountID: request.activeAccountID)
                KeychainManager.shared.invalidateSessionCache(for: [request.account.id])
                await usageAccountsController.adoptWebSessionReplacement(oldReference: request.account.id,
                    newReference: replacement.id)
                await apiService.reloadActiveAccount()
                refreshUsage(force: true)
            }))
    }

    private static func selectWebRecoverySource() async -> ClaudeBrowserSource? {
        let candidates = await Task.detached(priority: .utility) {
            ClaudeBrowserFamily.allCases.flatMap { ClaudeBrowserLoginDetector.importer(for: $0).discoverCandidates() }
        }.value
        guard !candidates.isEmpty, !Task.isCancelled else { return nil }
        let alert = NSAlert()
        alert.messageText = "기존 계정으로 로그인한 브라우저 프로필을 선택하세요"
        alert.informativeText = "선택한 프로필만 읽고, 실제 계정과 조직이 일치할 때 연결을 교체합니다."
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
        picker.addItems(withTitles: candidates.map { "\($0.family.displayName) / \($0.readableProfileName)" })
        alert.accessoryView = picker
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let candidate = candidates[picker.indexOfSelectedItem]
        return .init(family: candidate.family, profileName: candidate.profileName)
    }

    private func showWebRecoveryError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "웹 연결을 복구하지 못했습니다"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }
}
