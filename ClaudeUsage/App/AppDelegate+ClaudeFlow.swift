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
}
