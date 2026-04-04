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
            preferredOrganizationID: AppSettings.shared.preferredOrganizationID,
            cachedMetadata: currentClaudeProfileMetadata,
            hasChromeApp: hasChromeApp,
            credentialStepOverride: setupWizardCredentialStepOverride
        )
    }

    func applyClaudeSetupLandingTabsIfNeeded() {
        guard shouldShowStandaloneSetupWizard else { return }

        AppSettings.shared.settingsLastTab = "claude"
        AppSettings.shared.claudeSettingsLastTab = claudeSetupPresentation.landingSettingsTab.rawValue
    }

    func clearClaudePresentationState(markSetupIncomplete: Bool) {
        _ = markSetupIncomplete
        withRuntimeState {
            $0.clearClaudePresentationState()
        }
        popoverViewModel.nextUsageRetryAt = nil
    }

    // MARK: - Settings Window

    func syncClaudeSettingsFromWindow() async {
        let result = await ClaudeSettingsApplyCoordinator.syncStoredCredential(
            apiService: apiService,
            preferredOrganizationID: AppSettings.shared.preferredOrganizationID,
            providerEnabled: ServiceSelectionHelper.isEnabled(.claude, settings: AppSettings.shared)
        )
        await MainActor.run {
            self.applyUsageHealthSnapshot(result.snapshot)
            if result.shouldStartMonitoring {
                self.startMonitoring()
            } else {
                self.clearClaudePresentationState(
                    markSetupIncomplete: ServiceSelectionHelper.isEnabled(.claude, settings: AppSettings.shared)
                )
                self.updateMenuBar()
                self.updatePopoverViewModel()
                self.syncRefreshTimerState()
                if self.shouldPollRuntimeProviders {
                    self.refreshAll(force: true)
                }
            }
        }
        Logger.info("설정 적용 완료")
    }

    func applySettingsFromWindow() {
        Task {
            await syncClaudeSettingsFromWindow()
        }
    }

    func showSettingsWindow() {
        setupWizardWindowCoordinator.close()
        if setupWizardCredentialStepOverride == .manualSessionKey {
            setupWizardCredentialStepOverride = nil
        }

        if settingsWindowCoordinator.focusIfVisible() {
            return
        }

        applyClaudeSetupLandingTabsIfNeeded()

        let snapshot = AppSettings.shared.createSnapshot()

        let settingsView = SettingsView(
            onSave: { [weak self] in
                guard let self else { return }
                self.settingsWindowCoordinator.close(clearSnapshot: true)
                self.applySettingsFromWindow()
            },
            onApply: { [weak self] in
                guard let self else { return }
                self.settingsWindowCoordinator.refreshSnapshot(AppSettings.shared.createSnapshot())
                self.applySettingsFromWindow()
            },
            onCancel: { [weak self] in
                self?.settingsWindowCoordinator.close()
            },
            onOpenLogin: { [weak self] in
                self?.settingsWindowCoordinator.close()
                self?.showLoginWindow(clearCookies: true)
            },
            onOpenClaudeInChrome: { [weak self] in
                self?.openClaudeUsageInChrome()
            },
            onLogout: { [weak self] in
                guard let self else { return }
                Task {
                    let result = await ClaudeSettingsApplyCoordinator.logout(
                        apiService: self.apiService,
                        preferredOrganizationID: AppSettings.shared.preferredOrganizationID,
                        providerEnabled: ServiceSelectionHelper.isEnabled(.claude, settings: AppSettings.shared)
                    )
                    await MainActor.run {
                        self.applyUsageHealthSnapshot(result.snapshot)
                    }
                }
                self.clearClaudePresentationState(markSetupIncomplete: false)
                self.updateMenuBar()
                self.updatePopoverViewModel()
                self.settingsWindowCoordinator.refreshSnapshot(AppSettings.shared.createSnapshot())
                self.syncRefreshTimerState()
                if self.shouldPollRuntimeProviders {
                    self.refreshAll(force: true)
                }
                self.clearWebSessionData()
                Logger.info("로그아웃 완료")
            },
            onCodexLogout: { [weak self] in
                guard let self else { return }
                CodexAuthManager.shared.clearCache()
                self.setRuntimeProviderState(RuntimeProviderState(), for: .codex)
                self.updateMenuBar()
                self.updatePopoverViewModel(overage: self.currentOverage)
            }
        )
        settingsWindowCoordinator.present(rootView: settingsView, snapshot: snapshot)
    }

    // MARK: - Login Window

    func showLoginWindow(clearCookies: Bool = false) {
        setupWizardWindowCoordinator.close()

        if loginWindowCoordinator.focusIfVisible() {
            if clearCookies {
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
                onSessionKeyFound: { [weak self] key in
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
                            preferredOrganizationID: AppSettings.shared.preferredOrganizationID,
                            providerEnabled: ServiceSelectionHelper.isEnabled(.claude, settings: AppSettings.shared)
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
                            self.loginWindowCoordinator.close()
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
                onOpenAdvancedSettings: { [weak self] in
                    AppSettings.shared.settingsLastTab = "claude"
                    AppSettings.shared.claudeSettingsLastTab = "auth"
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
                AppSettings.shared.claudeSettingsLastTab = "auth"
                AppSettings.shared.shouldRevealClaudeAdvancedAuth = true
                self?.setupWizardWindowCoordinator.close()
                self?.showSettingsWindow()
            },
            onOpenOrganizations: { [weak self] in
                AppSettings.shared.settingsLastTab = "claude"
                AppSettings.shared.claudeSettingsLastTab = "organizations"
                self?.setupWizardWindowCoordinator.close()
                self?.showSettingsWindow()
            },
            onUseAutomaticOrganization: { [weak self] in
                guard let self else { return }
                AppSettings.shared.preferredOrganizationID = ""
                Task {
                    await self.apiService.updatePreferredOrganizationID("")
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
            let cookieStorage = HTTPCookieStorage.shared
            cookieStorage.cookies?.forEach { cookieStorage.deleteCookie($0) }
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
}
