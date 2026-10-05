import AppKit
import SwiftUI

extension AppDelegate {
    // MARK: - Claude Flow

    func showInitialClaudeSetupFlow() {
        if shouldShowStandaloneSetupWizard {
            showSetupWizardWindow()
        } else {
            showSettingsWindow()
        }
    }

    var shouldShowStandaloneSetupWizard: Bool {
        claudeSetupPresentation.shouldShowWizard
    }

    var hasReadyClaudeCredential: Bool {
        SetupCompletionPolicy.hasReadyCredential(
            sessionCredentialAvailable: KeychainManager.shared.hasSessionKey || claudeCredentialAvailability.sessionCredentialAvailable,
            oauthCredentialAvailable: claudeCredentialAvailability.oauthCredentialAvailable
        )
    }

    var hasSuccessfulClaudeFetch: Bool {
        lastUpdated != nil
    }

    var currentSetupWizardStep: SetupWizardView.Step {
        claudeSetupPresentation.credentialStep
    }

    var setupWizardProgress: SetupCompletionPolicy.WizardProgress {
        claudeSetupPresentation.progress
    }

    var claudeSetupPresentation: ClaudeSetupPresentation {
        SetupCompletionPolicy.resolvePresentation(
            hasReadyCredential: hasReadyClaudeCredential,
            hasSuccessfulFetch: hasSuccessfulClaudeFetch,
            preferredOrganizationID: activeClaudePreferredOrganizationID,
            cachedMetadata: currentClaudeProfileMetadata,
            credentialStepOverride: setupWizardCredentialStepOverride
        )
    }

    private var activeClaudePreferredOrganizationID: String {
        ClaudeAccountStore.shared.activeWebAccount()?.userSelectedPreferredOrganizationID ?? ""
    }

    private func userSelectedPreferredOrganizationID(forSessionKey sessionKey: String) -> String {
        let accountID = ClaudeAccountStore.webSessionAccountID(
            fingerprint: ClaudeAccountStore.fingerprint(for: sessionKey)
        )
        return ClaudeAccountStore.shared.accounts()
            .first(where: { $0.id == accountID })?
            .userSelectedPreferredOrganizationID ?? ""
    }

    func applyClaudeSetupLandingTabsIfNeeded() {
        guard shouldShowStandaloneSetupWizard else { return }

        AppSettings.shared.settingsLastTab = ServiceSelectionHelper.settingsRootTab(for: .claude)
    }

    func clearClaudePresentationState(markSetupIncomplete: Bool) {
        _ = markSetupIncomplete
        withRuntimeState {
            $0.clearClaudePresentationState()
        }
        popoverViewModel.nextUsageRetryAt = nil
    }

    // MARK: - Settings Window

    func makeSettingsView(
        antigravityRuntimeController:
            AntigravityRuntimeController,
        initialPanel: SettingsProviderPanel? = nil,
        initialSection: SettingsSection? = nil
    ) -> SettingsView {
        SettingsView(
            claudeAPIService: apiService,
            antigravitySettings: AntigravitySettingsViewModel(runtimeController: antigravityRuntimeController),
            onOpenLogin: { [weak self] in
                if AppSettings.shared.settingsLastTab != SettingsProviderPanel.welcome.rawValue {
                    self?.settingsWindowCoordinator.close()
                }
                self?.showLoginWindow(clearCookies: true, startEmbeddedWebOnOpen: true)
            },
            onReconnectClaudeCode: { [weak self] in
                if AppSettings.shared.settingsLastTab != SettingsProviderPanel.welcome.rawValue {
                    self?.settingsWindowCoordinator.close()
                }
                self?.showLoginWindow(startCLIActivationOnOpen: true)
            },
            onImportClaudeFromChrome: { [weak self] in
                if AppSettings.shared.settingsLastTab != SettingsProviderPanel.welcome.rawValue {
                    self?.settingsWindowCoordinator.close()
                }
                self?.showLoginWindow(startChromeImportOnOpen: true)
            },
            onRefreshClaudeUsage: { [weak self] in
                guard let self else { return }
                self.syncUsageHealthSnapshotToUI()
                self.refreshUsage(force: true)
            },
            onClaudeOAuthMigrationCompleted: { [weak self] in
                self?.handleClaudeCredentialContextChanged(refreshOAuthCredentialInventory: true)
            },
            onCodexLogout: { [weak self] in
                guard let self else { return }
                CodexAuthManager.shared.clearCache()
                self.setRuntimeProviderState(RuntimeProviderState(), for: .codex)
                self.updateMenuBar()
                self.updatePopoverViewModel()
            },
            claudeLastUsage: { [weak self] in
                self?.currentUsage
            },
            claudeLastOverage: { [weak self] in
                self?.currentOverage
            },
            codexLastUsage: { [weak self] in
                self?.currentCodexUsage
            },
            codexLastError: { [weak self] in
                self?.runtimeProviderState(for: .codex).error
            },
            initialPanel: initialPanel,
            initialSection: initialSection,
            welcomeStatuses: { [weak self] in
                guard let self else { return [:] }
                return Dictionary(
                    uniqueKeysWithValues: AppProviderKind.allCases.compactMap { provider in
                        guard let service = provider.runtimeService else { return nil }
                        return (
                            provider,
                            WelcomeServiceStatus.resolve(
                                snapshot: self.runtimeProviderSnapshot(for: service),
                                antigravity: self.currentAntigravityRuntimeSnapshot)
                        )
                    })
            },
            onVerifyService: { [weak self] service in self?.refresh(service: service, force: true) },
            onShowWhatsNew: { [weak self] in self?.presentLatestWhatsNew() },
            onImportClaudeFromBrowser: { [weak self] family in
                self?.showLoginWindow(startChromeImportOnOpen: true, importFamily: family)
            },
            onOpenEmbeddedLogin: { [weak self] in self?.showLoginWindow(startEmbeddedWebOnOpen: true) },
            usageAccounts: usageAccountsController
        )
    }

    func showSettingsWindow(destination: SettingsDestination) {
        showSettingsWindow(settingsPanelRawValue: destination.panel.rawValue, section: destination.section)
    }

    func showSettingsWindow(settingsPanelRawValue: String? = nil, section: SettingsSection? = nil) {
        setupWizardWindowCoordinator.close()
        if setupWizardCredentialStepOverride == .manualSessionKey { setupWizardCredentialStepOverride = nil }
        let settings = AppSettings.shared
        if settingsPanelRawValue == nil && settings.welcomeState == .pending {
            settings.settingsLastTab = SettingsProviderPanel.welcome.rawValue
        } else if settingsPanelRawValue == nil {
            applyClaudeSetupLandingTabsIfNeeded()
        } else if let settingsPanelRawValue,
            let resolved = SettingsProviderPanel.resolve(
                storedValue: settingsPanelRawValue, fallbackProvider: settings.activeProviderKind ?? .claude)
        {
            settings.settingsLastTab = resolved.panel.rawValue
        }
        pendingSettingsSection = section
        if settingsWindowCoordinator.focusIfVisible() {
            deliverPendingSettingsDestination()
            return
        }
        guard settingsWindowPresentationTask == nil else { return }
        settingsWindowPresentationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let runtime = await antigravityRuntimeTask.value
            guard !Task.isCancelled else {
                settingsWindowPresentationTask = nil
                pendingSettingsSection = nil
                return
            }
            defer { settingsWindowPresentationTask = nil }
            if settingsWindowCoordinator.focusIfVisible() {
                deliverPendingSettingsDestination()
                return
            }
            let initialPanel = SettingsProviderPanel.resolve(
                storedValue: settings.settingsLastTab,
                fallbackProvider: settings.activeProviderKind ?? .claude)?.panel
            let settingsView = makeSettingsView(
                antigravityRuntimeController: runtime.runtimeController,
                initialPanel: initialPanel, initialSection: pendingSettingsSection)
            pendingSettingsSection = nil
            settingsWindowCoordinator.present(rootView: settingsView)
        }
    }

    private func deliverPendingSettingsDestination() {
        guard
            let resolved = SettingsProviderPanel.resolve(
                storedValue: AppSettings.shared.settingsLastTab,
                fallbackProvider: AppSettings.shared.activeProviderKind ?? .claude)
        else { return }
        NotificationCenter.default.post(
            name: .settingsDestinationRequested,
            object: SettingsDestination(panel: resolved.panel, section: pendingSettingsSection))
        pendingSettingsSection = nil
    }

    /// 처음 설정과 같은 순서: Claude Code 로그인, 브라우저 로그인 가져오기, 없으면 로그인 방법 선택.
    func reconnectClaude() {
        Task { @MainActor [weak self] in
            let (claudeCode, finding) = await Task.detached(priority: .userInitiated) {
                (await ClaudeCodeLoginDetector.hasLogin(), ClaudeBrowserLoginDetector.findLogin())
            }.value
            guard let self else { return }
            let activeKind = ClaudeAccountStore.shared.state().activeAccount?.kind
            if claudeCode, activeKind != .webSession {
                self.showLoginWindow(startCLIActivationOnOpen: true)
            } else if let finding, finding.presence != .absent {
                self.showLoginWindow(startChromeImportOnOpen: true, importFamily: finding.family)
            } else {
                self.showLoginWindow()
            }
        }
    }

    // MARK: - Login Window

    func showLoginWindow(
        clearCookies: Bool = false,
        startChromeImportOnOpen: Bool = false,
        startCLIActivationOnOpen: Bool = false,
        startEmbeddedWebOnOpen: Bool = false,
        importFamily: ClaudeBrowserFamily? = nil
    ) {
        setupWizardWindowCoordinator.close()

        if loginWindowCoordinator.focusIfVisible() {
            if clearCookies || startChromeImportOnOpen || startCLIActivationOnOpen || startEmbeddedWebOnOpen {
                loginWindowCoordinator.close()
            } else {
                return
            }
        }

        let presentLoginWindow = { [weak self] in
            guard let self else { return }

            if self.loginWindowCoordinator.focusIfVisible() {
                return
            }

            let loginView = LoginWindowView(
                clearOnOpen: clearCookies,
                startChromeImportOnOpen: startChromeImportOnOpen,
                startCLIActivationOnOpen: startCLIActivationOnOpen,
                startEmbeddedWebOnOpen: startEmbeddedWebOnOpen,
                importFamily: importFamily,
                onSessionKeyFound: { [weak self] key, displayName, source, sourceDetail in
                    guard let self else { return }

                    await MainActor.run {
                        self.currentError = nil
                        self.hasAuthError = false
                        if ServiceSelectionHelper.isEnabled(.claude, settings: AppSettings.shared) {
                            self.isLoading = true
                            self.loadingStartedAt = Date()
                        }
                        self.updateMenuBar()
                        self.updatePopoverViewModel()
                    }

                    do {
                        try await ClaudeSettingsApplyCoordinator.activateSessionKey(
                            key,
                            apiService: self.apiService,
                            // Chrome의 다른 프로필을 연결할 때 현재 활성 계정의
                            // organization preference를 잘못 이식하지 않는다.
                            preferredOrganizationID: self.userSelectedPreferredOrganizationID(
                                forSessionKey: key
                            ),
                            displayName: displayName,
                            source: source,
                            sourceDetail: sourceDetail
                        )
                        // 저장 완료 알림이 AppRuntimeObservationCoordinator의 단일
                        // credential transaction을 시작한다. 여기서는 health/usage를
                        // 직접 다시 요청하지 않는다.
                        Logger.info("로그인 저장 완료, credential refresh transaction 요청")
                    } catch {
                        await MainActor.run {
                            self.isLoading = false
                            self.loadingStartedAt = nil
                            self.updateMenuBar()
                            self.updatePopoverViewModel()
                        }
                        throw error
                    }
                },
                onActivateCLI: { [weak self] in
                    guard let self else {
                        throw APIError.unknownError("앱 상태가 유효하지 않습니다")
                    }
                    return try await self.activateClaudeCodeCLI()
                },
                onLoadCLIPreview: { [weak self] in
                    guard let self else { return nil }
                    return await self.loadClaudeCodeCLIPreview()
                },
                onOpenAdvancedSettings: { [weak self] in
                    AppSettings.shared.settingsLastTab = ServiceSelectionHelper.settingsRootTab(for: .claude)
                    AppSettings.shared.shouldRevealClaudeAdvancedAuth = true
                    self?.loginWindowCoordinator.close()
                    self?.showSettingsWindow()
                },
                onCancel: { [weak self] in
                    self?.loginWindowCoordinator.close()
                }
            )
            self.loginWindowCoordinator.present(rootView: loginView)
        }

        // 로그인 창은 창마다 임시 세션을 써서 앱 쪽에서 지울 웹 데이터가 없다.
        presentLoginWindow()
    }

    func showSetupWizardWindow() {
        if setupWizardWindowCoordinator.focusIfVisible() {
            return
        }

        let rootView = SetupWizardWindowView(
            currentStep: currentSetupWizardStep,
            progress: setupWizardProgress,
            isVerifyingFetch: isLoading,
            onImportFromBrowser: { [weak self] in
                self?.setupWizardCredentialStepOverride = .browserImport
                self?.showLoginWindow(startChromeImportOnOpen: true)
            },
            onOpenWebLogin: { [weak self] in
                self?.setupWizardCredentialStepOverride = .webLogin
                self?.setupWizardWindowCoordinator.close()
                self?.showLoginWindow(clearCookies: true)
            },
            onOpenAdvancedSettings: { [weak self] in
                self?.setupWizardCredentialStepOverride = nil
                AppSettings.shared.settingsLastTab = ServiceSelectionHelper.settingsRootTab(for: .claude)
                AppSettings.shared.shouldRevealClaudeAdvancedAuth = true
                self?.setupWizardWindowCoordinator.close()
                self?.showSettingsWindow()
            },
            onOpenOrganizations: { [weak self] in
                AppSettings.shared.settingsLastTab = ServiceSelectionHelper.settingsRootTab(for: .claude)
                self?.setupWizardWindowCoordinator.close()
                self?.showSettingsWindow()
            },
            onUseAutomaticOrganization: { [weak self] in
                guard let self else { return }
                Task {
                    // 자동 선택으로 되돌릴 때는 store(단일 진실의 출처)를 비우고,
                    // service 의 in-memory 캐시는 store 알림 + reloadActiveAccount 가
                    // 자동으로 동기화하도록 둔다.
                    if let activeWebAccountID = ClaudeAccountStore.shared.activeWebAccount()?.id {
                        ClaudeAccountStore.shared.updatePreferredOrganizationID("", for: activeWebAccountID)
                    }
                    await self.apiService.reloadActiveAccount()
                    let snapshot = await self.apiService.fetchUsageHealthSnapshot()
                    let cachedMetadata = await self.apiService.fetchCachedProfileMetadata()
                    await MainActor.run {
                        self.setupWizardCredentialStepOverride = nil
                        self.currentClaudeProfileMetadata = cachedMetadata
                        self.applyUsageHealthSnapshot(snapshot)
                        if ServiceSelectionHelper.isEnabled(.claude, settings: AppSettings.shared),
                           self.hasRefreshableService {
                            self.refreshUsage(force: true)
                        } else {
                            self.updateMenuBar()
                            self.updatePopoverViewModel()
                        }
                        self.setupWizardWindowCoordinator.close()
                    }
                }
            },
            onVerifyFetch: { [weak self] in
                self?.refreshUsage(force: true)
            },
            onComplete: { [weak self] in
                self?.setupWizardCredentialStepOverride = nil
                self?.setupWizardWindowCoordinator.close()
            },
            onDismiss: { [weak self] in
                self?.setupWizardCredentialStepOverride = nil
                self?.setupWizardWindowCoordinator.close()
            }
        )
        setupWizardWindowCoordinator.present(rootView: rootView)
    }

    // MARK: - LoginWindow CLI Bridge

    /// 로그인 윈도우 Step 1 의 "Claude Code 로그인 사용" 카드 미리보기.
    /// 저장된 credential inventory와 메타데이터만 사용하며 외부 Keychain은 조회하지 않는다.
    /// inventory가 없어도 카드는 활성 상태로 남아 명시적 연결 액션에서 확인한다.
    @MainActor
    func loadClaudeCodeCLIPreview() async -> LoginWindowView.CLIPreview? {
        guard await apiService.hasStoredClaudeCodeCredentialInventory() else { return nil }
        let metadata = await apiService.fetchCachedClaudeCodeProfileMetadata()
        // 이전에 CLI 활성화 경험이 있으면 store 의 identity 에 email/조직 이름이 있을 수 있다.
        let existing = ClaudeAccountStore.shared.accounts()
            .first(where: { $0.id == ClaudeAccountStore.claudeCodeExternalAccountID })
        return LoginWindowView.CLIPreview(
            email: existing?.identity.email,
            organizationName: existing?.identity.organizationName,
            planLabel: metadata?.subscriptionType ?? metadata?.rateLimitTier
        )
    }

    /// 로그인 윈도우의 "Claude Code 로그인 사용" 카드 활성화 액션.
    /// 1) CLI external account 를 active 로 강제 전환 (이미 있으면 setActiveAccountID 만)
    /// 2) 공용 credential transaction 의 사용량 fetch 로 검증
    /// 3) 성공 요약을 wizard 에 반환 (이메일/조직/플랜 표시)
    @MainActor
    func activateClaudeCodeCLI() async throws -> LoginWindowView.ActivationSummary {
        // 사용자가 이 카드를 누른 시점에만 CLI Keychain 항목의 대화형 읽기를
        // 허용한다. 성공한 payload는 앱 vault로 복사되므로 이후 전환은 무프롬프트다.
        try await apiService.importClaudeCodeCredentialForActivation()

        let store = ClaudeAccountStore.shared
        let previousActiveAccountID = store.state().activeAccountID
        // 1. CLI external account 등록을 보장하고 active 로 설정.
        //    OAuth credential 자체는 fetchUsage 가 첫 호출에서 자체적으로 검사하므로 여기서는
        //    "최소 1개의 CLI 계정이 store 에 존재" 만 보장한다.
        _ = store.upsertClaudeCodeExternalAccount(
            identity: ClaudeAccountIdentity(),
            validationState: .detected,
            setActiveIfMissing: false
        )
        store.setActiveAccountID(ClaudeAccountStore.claudeCodeExternalAccountID)

        // 2. account 변경 알림도 같은 request 에 합류한다. provider 가 꺼져 있어도
        // 연결 액션 자체는 실제 사용량 1회로 검증한다.
        let transaction = handleClaudeCredentialContextChanged(
            refreshOAuthCredentialInventory: true,
            requireUsageValidation: true
        )
        await transaction.value

        let snapshot = runtimeProviderSnapshot(for: .claude)
        let expectedAccountID = ClaudeAccountStore.claudeCodeExternalAccountID
        guard snapshot.lastSuccessfulMetadata?.accountID == expectedAccountID,
              let usage = currentUsage else {
            // 확인하지 못했으면 쓰던 계정으로 되돌려 메뉴바가 확인되지 않은 계정을 따라가지 않게 한다.
            if let previousActiveAccountID, previousActiveAccountID != expectedAccountID {
                store.setActiveAccountID(previousActiveAccountID)
            }
            throw snapshot.error ?? APIError.unknownError("Claude Code 사용량을 확인하지 못했습니다")
        }
        Logger.info("Claude Code CLI 활성화 성공 (\(usage.usageSummaryText))")

        // 3. 사용자에게 보여줄 요약 라인 구성. OAuth 사용량 성공 뒤 시작된
        // profile 동기화가 아직 끝나지 않았으면 안전하게 제목만 표시한다.
        let activeAccount = ClaudeAccountStore.shared.activeAccount()
        let metadata = await apiService.fetchCachedClaudeCodeProfileMetadata()
        let email = activeAccount?.identity.email
        let organizationName = activeAccount?.identity.organizationName
        let plan = metadata?.subscriptionType ?? metadata?.rateLimitTier
        let detailParts = [email, organizationName, plan].compactMap { $0?.isEmpty == false ? $0 : nil }
        return LoginWindowView.ActivationSummary(
            title: "Claude Code 로그인을 연결했습니다",
            detail: detailParts.isEmpty ? nil : detailParts.joined(separator: " · "),
            methodLabel: "Claude Code CLI"
        )
    }
}
