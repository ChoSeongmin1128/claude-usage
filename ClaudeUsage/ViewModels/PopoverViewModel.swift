import Foundation
import SwiftUI
import Combine

@MainActor
final class PopoverViewModel: ObservableObject {
    struct ProviderShellCard: Identifiable, Sendable, Equatable {
        let kind: AppProviderKind
        let title: String
        let icon: String
        let summary: String
        let detail: String?
        let badgeTitle: String?
        let isSelectable: Bool

        var id: String { kind.rawValue }
    }

    struct RuntimeServiceState: Sendable {
        let service: PopoverService
        let summary: String
        let meta: String?
        let lastUpdated: Date?
        let isLoading: Bool
        let error: APIError?
        let hasContent: Bool
        let isAuthRequired: Bool
        let shouldShowWarningDot: Bool
    }

    @Published var usage: ClaudeUsageResponse?
    @Published var codexUsage: CodexUsageResponse?
    @Published var error: APIError?
    @Published var codexError: APIError?
    @Published var isClaudeLoading: Bool = false
    @Published var isCodexLoading: Bool = false
    @Published var claudeLastUpdated: Date?
    @Published var codexLastUpdated: Date?
    @Published var selectedService: PopoverService = .claude
    @Published var overage: OverageSpendLimitResponse?
    @Published var systemStatus: ClaudeSystemStatus?
    @Published var usageHealthSnapshot: ClaudeAPIService.UsageHealthSnapshot?
    @Published var nextUsageRetryAt: Date?

    var onRefreshService: ((PopoverService) -> Void)?
    var onOpenSettingsForService: ((PopoverService) -> Void)?
    var onServiceSelected: ((PopoverService) -> Void)?
    var onPinChanged: ((PopoverService, Bool) -> Void)?
    var onLayoutChanged: ((PopoverService) -> Void)?

    func refresh() {
        self.onRefreshService?(self.selectedService)
    }

    func refresh(service: PopoverService) {
        self.onRefreshService?(service)
    }

    func openSettings() {
        self.onOpenSettingsForService?(self.selectedService)
    }

    func openSettings(for service: PopoverService) {
        self.onOpenSettingsForService?(service)
    }

    func selectService(_ service: PopoverService) {
        self.selectedService = service
        self.onServiceSelected?(service)
    }

    func requestLayoutRefresh() {
        self.onLayoutChanged?(self.selectedService)
    }

    func requestLayoutRefresh(for service: PopoverService) {
        self.onLayoutChanged?(service)
    }

    func openUsagePage() {
        guard let url = URL(string: "https://claude.ai/settings/usage") else { return }
        NSWorkspace.shared.open(url)
    }

    func downloadLatestRelease() {
        Task {
            let url = await UpdateService.shared.latestDownloadURL()
            NSWorkspace.shared.open(url)
        }
    }

    func providerShellCards(settings: AppSettings) -> [ProviderShellCard] {
        SettingsProviderRegistry.providerShellDescriptors.map { descriptor in
            ProviderShellCard(
                kind: descriptor.kind,
                title: descriptor.title,
                icon: descriptor.icon,
                summary: shellSummary(for: descriptor.kind, settings: settings, baseSummary: descriptor.summary),
                detail: shellDetail(for: descriptor.kind, settings: settings, baseDetail: descriptor.detail),
                badgeTitle: shellBadgeTitle(for: descriptor.kind, settings: settings, baseBadge: descriptor.role.badgeTitle),
                isSelectable: descriptor.supportsPopoverSelection
            )
        }
    }

    var hasClaudeCredential: Bool {
        usageHealthSnapshot?.runtime.credentialAvailability.hasAnyCredential ?? KeychainManager.shared.hasSessionKey
    }

    func runtimeServiceState(for service: PopoverService, settings: AppSettings) -> RuntimeServiceState {
        switch service {
        case .claude:
            let isEnabled = settings.isProviderEnabled(.claude)
            let isAuthRequired = isEnabled && !hasClaudeCredential
            let summary: String
            if !isEnabled {
                summary = "비활성화됨"
            } else if isAuthRequired {
                summary = "인증 필요"
            } else if isClaudeLoading {
                summary = "조회 중"
            } else if let usage {
                summary = "현재 \(Int(usage.fiveHour.utilization.rounded()))% · 주간 \(Int((usage.sevenDay?.utilization ?? 0).rounded()))%"
            } else if let error {
                summary = error.errorDescription ?? "조회 실패"
            } else {
                summary = "데이터를 아직 불러오지 못했습니다"
            }

            let meta = claudeLastUpdated.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) }
            let hasContent = usage != nil
            return RuntimeServiceState(
                service: .claude,
                summary: summary,
                meta: meta,
                lastUpdated: claudeLastUpdated,
                isLoading: isClaudeLoading,
                error: error,
                hasContent: hasContent,
                isAuthRequired: isAuthRequired,
                shouldShowWarningDot: isAuthRequired || error != nil
            )
        case .codex:
            let isEnabled = settings.isProviderEnabled(.codex)
            let isAuthRequired = isEnabled && !CodexAuthManager.shared.isAuthenticated
            let summary: String
            if !isEnabled {
                summary = "비활성화됨"
            } else if isAuthRequired {
                summary = "인증 필요"
            } else if isCodexLoading {
                summary = "조회 중"
            } else if let codexUsage {
                summary = "현재 \(Int((codexUsage.rateLimit?.primaryWindow?.utilization ?? 0).rounded()))% · 주간 \(Int((codexUsage.rateLimit?.secondaryWindow?.utilization ?? 0).rounded()))%"
            } else if let codexError {
                summary = codexError.errorDescription ?? "조회 실패"
            } else {
                summary = "데이터를 아직 불러오지 못했습니다"
            }

            let meta = codexLastUpdated.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) }
            let hasContent = codexUsage != nil
            return RuntimeServiceState(
                service: .codex,
                summary: summary,
                meta: meta,
                lastUpdated: codexLastUpdated,
                isLoading: isCodexLoading,
                error: codexError,
                hasContent: hasContent,
                isAuthRequired: isAuthRequired,
                shouldShowWarningDot: isAuthRequired || codexError != nil
            )
        }
    }

    func overviewSummary(for kind: AppProviderKind, settings: AppSettings) -> String {
        switch kind {
        case .claude:
            return runtimeServiceState(for: .claude, settings: settings).summary
        case .codex:
            return runtimeServiceState(for: .codex, settings: settings).summary
        case .gemini, .antigravity:
            return settings.isProviderEnabled(kind) ? "런타임 연결 준비 중" : "비활성화됨"
        }
    }

    func overviewMeta(for kind: AppProviderKind) -> String? {
        switch kind {
        case .claude:
            return runtimeServiceState(for: .claude, settings: .shared).meta
        case .codex:
            return runtimeServiceState(for: .codex, settings: .shared).meta
        case .gemini, .antigravity:
            return nil
        }
    }

    func overviewCard(for kind: AppProviderKind, settings: AppSettings) -> ProviderShellCard {
        let descriptor = SettingsProviderRegistry.providerShellDescriptor(for: kind)
        return ProviderShellCard(
            kind: descriptor.kind,
            title: descriptor.title,
            icon: descriptor.icon,
            summary: overviewSummary(for: kind, settings: settings),
            detail: overviewMeta(for: kind),
            badgeTitle: descriptor.role.badgeTitle,
            isSelectable: descriptor.supportsPopoverSelection
        )
    }

    private func shellSummary(for kind: AppProviderKind, settings: AppSettings, baseSummary: String) -> String {
        switch kind {
        case .claude:
            return settings.isProviderEnabled(.claude) ? baseSummary : "비활성화됨"
        case .codex:
            return settings.isProviderEnabled(.codex) ? baseSummary : "비활성화됨"
        case .gemini, .antigravity:
            return settings.isProviderEnabled(kind) ? baseSummary : "비활성화됨"
        }
    }

    private func shellDetail(for kind: AppProviderKind, settings: AppSettings, baseDetail: String?) -> String? {
        switch kind {
        case .claude:
            if settings.isProviderEnabled(.claude) {
                return baseDetail
            }
            return "현재는 설정만 유지하고 있습니다."
        case .codex:
            if settings.isProviderEnabled(.codex) {
                return baseDetail
            }
            return "현재는 설정만 유지하고 있습니다."
        case .gemini, .antigravity:
            if settings.isProviderEnabled(kind) {
                return baseDetail ?? "런타임 연결 전 구조를 정리하고 있습니다."
            }
            return "비활성화된 상태입니다."
        }
    }

    private func shellBadgeTitle(for kind: AppProviderKind, settings: AppSettings, baseBadge: String?) -> String? {
        switch kind {
        case .claude:
            return settings.isProviderEnabled(.claude) ? "활성" : "비활성"
        case .codex:
            return settings.isProviderEnabled(.codex) ? "활성" : "비활성"
        case .gemini, .antigravity:
            return settings.isProviderEnabled(kind) ? (baseBadge ?? "준비 중") : "비활성"
        }
    }

    func update(
        usage: ClaudeUsageResponse?,
        codexUsage: CodexUsageResponse?,
        error: APIError?,
        codexError: APIError?,
        isClaudeLoading: Bool,
        isCodexLoading: Bool,
        claudeLastUpdated: Date? = nil,
        codexLastUpdated: Date? = nil,
        overage: OverageSpendLimitResponse? = nil)
    {
        self.usage = usage
        self.codexUsage = codexUsage
        self.error = error
        self.codexError = codexError
        self.isClaudeLoading = isClaudeLoading
        self.isCodexLoading = isCodexLoading
        if let claudeLastUpdated { self.claudeLastUpdated = claudeLastUpdated }
        if let codexLastUpdated { self.codexLastUpdated = codexLastUpdated }
        if let overage { self.overage = overage }
    }
}
