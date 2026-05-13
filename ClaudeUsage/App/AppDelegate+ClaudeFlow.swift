import AppKit
import SwiftUI
import WebKit

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

    var hasChromeApp: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") != nil
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
            hasChromeApp: hasChromeApp,
            credentialStepOverride: setupWizardCredentialStepOverride
        )
    }

    private var activeClaudePreferredOrganizationID: String {
        ClaudeAccountStore.shared.activeWebAccount()?.preferredOrganizationID ?? ""
    }

    func applyClaudeSetupLandingTabsIfNeeded() {
        guard shouldShowStandaloneSetupWizard else { return }

        AppSettings.shared.settingsLastTab = "claude"
    }

    func clearClaudePresentationState(markSetupIncomplete: Bool) {
        _ = markSetupIncomplete
        withRuntimeState {
            $0.clearClaudePresentationState()
        }
        popoverViewModel.nextUsageRetryAt = nil
    }

    // MARK: - Settings Window

    func showSettingsWindow() {
        setupWizardWindowCoordinator.close()
        if setupWizardCredentialStepOverride == .manualSessionKey {
            setupWizardCredentialStepOverride = nil
        }

        if settingsWindowCoordinator.focusIfVisible() {
            return
        }

        applyClaudeSetupLandingTabsIfNeeded()

        let settingsView = SettingsView(
            onOpenLogin: { [weak self] in
                self?.settingsWindowCoordinator.close()
                self?.showLoginWindow(clearCookies: true)
            },
            onImportClaudeFromChrome: { [weak self] in
                self?.settingsWindowCoordinator.close()
                self?.showLoginWindow(startChromeImportOnOpen: true)
            },
            onClearBrowserSession: { [weak self] in
                guard let self else { return }
                Task {
                    let result = await ClaudeSettingsApplyCoordinator.deleteBrowserSession(
                        apiService: self.apiService,
                        preferredOrganizationID: "",
                        providerEnabled: ServiceSelectionHelper.isEnabled(.claude, settings: AppSettings.shared)
                    )
                    await MainActor.run {
                        self.resetClaudeRuntimeAfterAccountBoundaryChange()
                        self.applyUsageHealthSnapshot(result.snapshot)
                        if result.shouldStartMonitoring {
                            self.startMonitoring()
                        } else if !result.snapshot.runtime.credentialAvailability.hasAnyCredential {
                            self.clearClaudePresentationState(markSetupIncomplete: false)
                            self.updateMenuBar()
                            self.updatePopoverViewModel(overage: self.currentOverage)
                            self.syncRefreshTimerState()
                        } else {
                            self.updateMenuBar()
                            self.updatePopoverViewModel(overage: self.currentOverage)
                            self.syncRefreshTimerState()
                        }
                    }
                }
                self.clearWebSessionData()
                Logger.info("브라우저 로그인 값 삭제 완료")
            },
            onRefreshClaudeUsage: { [weak self] in
                guard let self else { return }
                self.syncUsageHealthSnapshotToUI()
                self.refreshUsage(force: true)
            },
            onCodexLogout: { [weak self] in
                guard let self else { return }
                CodexAuthManager.shared.clearCache()
                self.setRuntimeProviderState(RuntimeProviderState(), for: .codex)
                self.updateMenuBar()
                self.updatePopoverViewModel(overage: self.currentOverage)
            }
        )
        settingsWindowCoordinator.present(rootView: settingsView)
    }

    // MARK: - Login Window

    func showLoginWindow(clearCookies: Bool = false, startChromeImportOnOpen: Bool = false) {
        setupWizardWindowCoordinator.close()

        if loginWindowCoordinator.focusIfVisible() {
            if clearCookies || startChromeImportOnOpen {
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
                        self.updatePopoverViewModel(overage: self.currentOverage)
                    }

                    do {
                        let result = try await ClaudeSettingsApplyCoordinator.activateSessionKey(
                            key,
                            apiService: self.apiService,
                            preferredOrganizationID: self.activeClaudePreferredOrganizationID,
                            providerEnabled: ServiceSelectionHelper.isEnabled(.claude, settings: AppSettings.shared),
                            displayName: displayName,
                            source: source,
                            sourceDetail: sourceDetail
                        )
                        await MainActor.run {
                            self.applyUsageHealthSnapshot(result.snapshot)
                            self.hasAuthError = false
                            if result.shouldStartMonitoring {
                                self.startMonitoring()
                            } else {
                                self.updateMenuBar()
                                self.updatePopoverViewModel(overage: self.currentOverage)
                            }
                            // wizard 의 success step 이 사용자에게 결과를 보여줄 시간을 확보하기 위해
                            // 즉시 close 하지 않는다. 사용자가 "완료" 버튼을 누르면 onCancel → close.
                        }
                        Logger.info("로그인 완료, 모니터링 시작")
                    } catch {
                        await MainActor.run {
                            self.isLoading = false
                            self.loadingStartedAt = nil
                            self.updateMenuBar()
                            self.updatePopoverViewModel(overage: self.currentOverage)
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
                    AppSettings.shared.settingsLastTab = "claude"
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

        if clearCookies {
            clearWebSessionData(completion: presentLoginWindow)
        } else {
            presentLoginWindow()
        }
    }

    func showSetupWizardWindow() {
        if setupWizardWindowCoordinator.focusIfVisible() {
            return
        }

        let rootView = SetupWizardWindowView(
            currentStep: currentSetupWizardStep,
            progress: setupWizardProgress,
            isVerifyingFetch: isLoading,
            onOpenChrome: { [weak self] in
                self?.setupWizardCredentialStepOverride = .chromeImport
                self?.openClaudeUsageInChrome()
            },
            onOpenWebLogin: { [weak self] in
                self?.setupWizardCredentialStepOverride = .webLogin
                self?.setupWizardWindowCoordinator.close()
                self?.showLoginWindow(clearCookies: true)
            },
            onOpenAdvancedSettings: { [weak self] in
                self?.setupWizardCredentialStepOverride = nil
                AppSettings.shared.settingsLastTab = "claude"
                AppSettings.shared.shouldRevealClaudeAdvancedAuth = true
                self?.setupWizardWindowCoordinator.close()
                self?.showSettingsWindow()
            },
            onOpenOrganizations: { [weak self] in
                AppSettings.shared.settingsLastTab = "claude"
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
                            self.updatePopoverViewModel(overage: self.currentOverage)
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

    func clearWebSessionData(completion: (() -> Void)? = nil) {
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(ofTypes: dataTypes, modifiedSince: .distantPast) {
            URLCache.shared.removeAllCachedResponses()
            Logger.info("웹 데이터 삭제 완료")
            completion?()
        }
    }

    func openClaudeUsageInChrome() {
        let targetURL = URL(string: "https://claude.ai/settings/usage")!
        if let chromeAppURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([targetURL], withApplicationAt: chromeAppURL, configuration: configuration)
            return
        }

        NSWorkspace.shared.open(targetURL)
    }

    // MARK: - LoginWindow CLI Bridge

    /// 로그인 윈도우 Step 1 의 "Claude Code 로그인 사용" 카드 미리보기.
    /// 토큰이 없거나 만료 + refresh 불가면 nil → 카드가 disabled 상태로 표시된다.
    /// 빠르게 응답해야 하므로 메타데이터(file cache)만 읽고 네트워크는 안 친다.
    @MainActor
    func loadClaudeCodeCLIPreview() async -> LoginWindowView.CLIPreview? {
        guard await apiService.peekClaudeCodeCredentialAvailable() else { return nil }
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
    /// 2) 사용량 fetch 로 검증
    /// 3) 성공 요약을 wizard 에 반환 (이메일/조직/플랜 표시)
    @MainActor
    func activateClaudeCodeCLI() async throws -> LoginWindowView.ActivationSummary {
        let store = ClaudeAccountStore.shared
        // 1. CLI external account 등록을 보장하고 active 로 설정.
        //    OAuth credential 자체는 fetchUsage 가 첫 호출에서 자체적으로 검사하므로 여기서는
        //    "최소 1개의 CLI 계정이 store 에 존재" 만 보장한다.
        _ = store.upsertClaudeCodeExternalAccount(
            identity: ClaudeAccountIdentity(),
            validationState: .detected,
            setActiveIfMissing: false
        )
        store.setActiveAccountID(ClaudeAccountStore.claudeCodeExternalAccountID)

        // 2. 검증: 실제 사용량 호출. 실패하면 throw → wizard 가 .failure step 으로.
        currentError = nil
        hasAuthError = false
        if ServiceSelectionHelper.isEnabled(.claude, settings: AppSettings.shared) {
            isLoading = true
            loadingStartedAt = Date()
        }
        updateMenuBar()
        updatePopoverViewModel(overage: currentOverage)

        await apiService.reloadActiveAccount()
        do {
            let usage = try await apiService.fetchUsage()
            // OAuth profile 도 함께 가져와 store identity / metadata 를 채운다.
            // 실패해도 사용량 자체는 정상이므로 silent return.
            await apiService.refreshClaudeCodeAccountProfile()
            let snapshot = await apiService.fetchUsageHealthSnapshot()
            applyUsageHealthSnapshot(snapshot)
            hasAuthError = false
            if ServiceSelectionHelper.isEnabled(.claude, settings: AppSettings.shared), hasRefreshableService {
                startMonitoring()
            } else {
                updateMenuBar()
                updatePopoverViewModel(overage: currentOverage)
            }
            Logger.info("Claude Code CLI 활성화 성공 (5시간 utilization=\(usage.fiveHour.utilization))")

            // 3. 사용자에게 보여줄 요약 라인 구성. (refresh 후의 최신 identity 사용)
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
        } catch {
            isLoading = false
            loadingStartedAt = nil
            updateMenuBar()
            updatePopoverViewModel(overage: currentOverage)
            throw error
        }
    }
}
