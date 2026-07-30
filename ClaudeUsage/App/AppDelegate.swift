//
//  AppDelegate.swift
//  ClaudeUsage
//
//  AppKit 진입점과 코디네이터/서비스 구성만 담당
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var ownsSingleInstanceLease = false
    var didFinishRuntimeLaunch = false
    var statusItem: NSStatusItem?
    let refreshScheduler = RefreshScheduler()
    let updateCoordinator = AppUpdateCoordinator()
    lazy var apiService = ClaudeAPIService()
    let codexAPIService = CodexAPIService(authManager: CodexAuthManager.shared)
    lazy var antigravityRuntimeTask:
        Task<
            AntigravityProductRuntimeComposition,
            Never
        > = {
            let settingsBootstrap =
                AntigravityApplicationBootstrap
                    .prepareSettings()
            return Task {
                await AntigravityProductRuntimeLoader
                    .makeProduction(
                        settingsBootstrap:
                            settingsBootstrap
                    )
            }
        }()
    let popoverCoordinator = AppPopoverCoordinator()
    let runtimeObservationCoordinator = AppRuntimeObservationCoordinator()
    let settingsWindowCoordinator = SettingsWindowCoordinator()
    let loginWindowCoordinator = LoginWindowCoordinator()
    let setupWizardWindowCoordinator = SetupWizardWindowCoordinator()
    let runtimeState = AppRuntimeStateFacade()

    var statusTimer: Timer?
    var appearanceObservation: NSKeyValueObservation?
    var statusItemPlacementCheckTask: Task<Void, Never>?
    var lastObservedProviderSelectionState: ProviderSelectionState?
    var eventMonitor: Any?
    var globalClickMonitor: Any?
    var isPresentingPopover = false
    var claudeCredentialRefreshTask: Task<Void, Never>?
    var claudeUsageRefreshTask: Task<Void, Never>?
    var claudeCredentialRefreshGeneration = 0
    var claudeCredentialRefreshRequest: ClaudeCredentialRefreshRequest?
    var antigravityRuntimeObservationTask:
        Task<Void, Never>?
    var antigravityRuntimeBootstrapTask:
        Task<Void, Never>?
    var antigravityTerminationTask:
        Task<Void, Never>?
    var antigravityTerminationTimeoutTask:
        Task<Void, Never>?
    var settingsWindowPresentationTask:
        Task<Void, Never>?
    var hasRepliedToTermination = false

    var popover: NSPopover? { popoverCoordinator.popover }
    var popoverViewModel: PopoverViewModel { popoverCoordinator.viewModel }
    lazy var runtimeRefreshHandlers: [PopoverService: (Bool) -> Void] =
        RuntimeRefreshHandlerRegistry.makeHandlers(
            refreshClaude: { [weak self] force in self?.refreshUsage(force: force) },
            refreshCodex: { [weak self] force in self?.refreshCodexUsage(force: force) },
            refreshAntigravity: { [weak self] force in self?.refreshAntigravityUsage(force: force) }
        )
}
