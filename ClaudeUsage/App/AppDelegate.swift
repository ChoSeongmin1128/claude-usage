//
//  AppDelegate.swift
//  ClaudeUsage
//
//  AppKit 진입점과 코디네이터/서비스 구성만 담당
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let initialRuntimeProviderDetectionKey = "initialRuntimeProviderDetectionCompleted"

    var statusItem: NSStatusItem?
    let refreshScheduler = RefreshScheduler()
    let updateCoordinator = AppUpdateCoordinator()
    let apiService = ClaudeAPIService()
    let codexAPIService = CodexAPIService()
    let geminiAPIService = GeminiAPIService()
    let antigravityAPIService = AntigravityAPIService()
    let popoverCoordinator = AppPopoverCoordinator()
    let runtimeObservationCoordinator = AppRuntimeObservationCoordinator()
    let settingsWindowCoordinator = SettingsWindowCoordinator()
    let loginWindowCoordinator = LoginWindowCoordinator()
    let setupWizardWindowCoordinator = SetupWizardWindowCoordinator()
    let runtimeState = AppRuntimeStateFacade()

    var statusTimer: Timer?
    var appearanceObservation: NSKeyValueObservation?
    var lastObservedProviderStates = AppSettings.shared.providerStates
    var eventMonitor: Any?
    var globalClickMonitor: Any?

    var popover: NSPopover? { popoverCoordinator.popover }
    var popoverViewModel: PopoverViewModel { popoverCoordinator.viewModel }
    lazy var runtimeRefreshHandlers: [PopoverService: (Bool) -> Void] =
        RuntimeRefreshHandlerRegistry.makeHandlers(
            refreshClaude: { [weak self] force in self?.refreshUsage(force: force) },
            refreshCodex: { [weak self] force in self?.refreshCodexUsage(force: force) },
            refreshGemini: { [weak self] force in self?.refreshGeminiUsage(force: force) },
            refreshAntigravity: { [weak self] force in self?.refreshAntigravityUsage(force: force) }
        )
}
