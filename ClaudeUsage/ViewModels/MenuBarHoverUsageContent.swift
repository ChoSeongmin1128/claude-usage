import Foundation

/// Read-only projection of existing, account-scoped runtime data. No fetch or acknowledgement.
struct MenuBarHoverUsageContent: Equatable {
    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let compactTitle: String
        let value: String
        var detail: String? = nil
        var isUnknown = false
    }

    struct Provider: Identifiable, Equatable {
        let kind: AppProviderKind
        let basis: UsageValueBasis
        let items: [Item]
        var stateText: String? = nil
        var serviceTone: ServiceStatusPanelContent.Tone? = nil
        var id: AppProviderKind { kind }
    }

    let providers: [Provider]

    var catalogProviders: [Provider] { providers.filter { $0.kind != .antigravity } }
    var listProviders: [Provider] { usesCommonColumns ? providers.filter { $0.kind == .antigravity } : providers }

    var usesCommonColumns: Bool {
        guard let first = catalogProviders.first, !catalogProviders.isEmpty, first.items.count == 2,
            [AppProviderKind.claude, .codex].contains(first.kind),
            first.items.map(\.compactTitle) == ["5시간", "주간"]
        else { return false }
        return catalogProviders.allSatisfy {
            $0.items.count == 2 && [.claude, .codex].contains($0.kind)
                && $0.items.map(\.compactTitle) == first.items.map(\.compactTitle)
                && $0.items.allSatisfy { $0.detail == nil }
        }
    }

    var caption: String {
        guard !hasMixedBasis, let basis = providers.first?.basis else { return "사용량" }
        return basis == .remaining ? "남은 사용량" : "사용한 양"
    }

    var hasMixedBasis: Bool { Set(providers.map(\.basis)).count > 1 }

    static func catalogProvider(snapshot: RuntimeProviderSnapshot, settings: AppSettings) -> Provider? {
        guard let catalog = UsageItemCatalogRegistry.catalog(for: snapshot.service) else { return nil }
        let selected = settings.displayItems(for: snapshot.service, surface: .hover).filter(\.visible)
        guard !selected.isEmpty else { return nil }
        let context = UsageItemContext(
            density: .compact, settings: settings,
            claudeUsage: snapshot.claudeUsage, claudeOverage: snapshot.claudeOverage,
            codexUsage: snapshot.codexUsage, codexError: snapshot.error,
            claudeOverageUpdatedAt: snapshot.claudeOverageUpdatedAt,
            claudeOverageIsStale: snapshot.claudeOverageIsStale)
        let items = selected.flatMap { config -> [Item] in
            let sections = catalog.expandedSections(for: config.id, context: context)
            if !sections.isEmpty { return sections.compactMap(item) }
            // A selected field that is not reported stays visible as unknown.
            let title = catalog.displayName(for: config.id) ?? config.displayName
            return [
                Item(
                    id: config.id, title: title,
                    compactTitle: defaultCompactTitle(id: config.id, fallback: title),
                    value: "미확인", isUnknown: true)
            ]
        }
        let state: String?
        if snapshot.hasAuthError || snapshot.error?.isDefinitiveAuthFailure == true || !snapshot.hasCredential {
            state = "로그인 필요"
        } else if snapshot.error != nil {
            state = snapshot.hasContent ? "조회 실패 / 이전 값" : "조회 실패"
        } else if snapshot.isLoading {
            state = snapshot.hasContent ? "갱신 중" : "확인 중"
        } else {
            state = snapshot.hasContent ? nil : "확인 전"
        }
        return Provider(
            kind: snapshot.kind, basis: settings.usageValueBasis(for: snapshot.service),
            items: items, stateText: state)
    }

    static func antigravityProvider(snapshot: AntigravityRuntimeSnapshot, basis: UsageValueBasis?) -> Provider? {
        guard let settings = snapshot.settings else {
            return Provider(kind: .antigravity, basis: basis ?? .used, items: [], stateText: "확인 전")
        }
        let presentation: AntigravityQuotaPresentation?
        if case .content(let value) = snapshot.quotaPresentation { presentation = value } else { presentation = nil }
        let projection = AntigravityDisplayAdapter.hoverEditorSettings(
            settings.display, hover: settings.hover,
            presentation: presentation)
        let intent = projection.compact
        let candidates = AntigravityDisplayAdapter.editorItems(
            settings: projection, presentation: presentation, surface: .hover)
        let lanes = presentation?.allGroups.flatMap(\.lanes) ?? []
        let byID = Dictionary(lanes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let valueBasis = basis ?? UsageValueBasis.antigravity(settings.display.menuBar)
        let items = candidates.filter { !intent.hiddenLaneIDs.contains($0.id) }.map { candidate in
            let lane = byID[candidate.id]
            return Item(
                id: candidate.id.rawValue, title: candidate.title, compactTitle: candidate.title,
                value: lane?.value.usedPercentage.map { valueBasis.text(fromUsed: $0) } ?? "미확인",
                isUnknown: lane?.value.usedPercentage == nil)
        }
        let state: String?
        switch snapshot.presentationState {
        case .ready: state = nil
        case .partial: state = "일부 미확인"
        case .stale: state = "이전 값"
        case .failed: state = "조회 실패"
        case .refreshing: state = "확인 중"
        case .disabled: state = "확인 전"
        }
        if items.isEmpty, !(settings.hover.selection == nil && presentation == nil) { return nil }
        return Provider(kind: .antigravity, basis: valueBasis, items: items, stateText: state)
    }

    private static func item(_ section: PopoverDisplaySection) -> Item? {
        switch section.payload {
        case .usage(let usage):
            return Item(
                id: section.id, title: usage.title, compactTitle: usage.compactLabel,
                value: usage.basis.text(fromUsed: usage.percentage), isUnknown: !usage.percentage.isFinite)
        case .credits(let data):
            return Item(id: section.id, title: "크레딧 잔액", compactTitle: "크레딧 잔액", value: data.credits.formattedBalance)
        case .resetCredits(let data):
            return Item(
                id: section.id, title: "초기화권", compactTitle: "초기화권", value: "\(data.summary.availableCount)개",
                detail: data.summary.expirationDescription())
        case .overage(let data):
            return Item(
                id: section.id, title: "추가 사용량", compactTitle: "추가 사용량",
                value: data.overage.formattedUsageLimitSummary,
                detail: data.isStale ? UsageStatusLabel.previousValue : nil)
        case .status(let data):
            return Item(
                id: section.id, title: data.title, compactTitle: data.title,
                value: data.statusText ?? (data.error?.isDefinitiveAuthFailure == true ? "확인 못 함" : "확인 전"),
                isUnknown: true)
        case .account, .accountPicker, .accountRow, .accountSummary: return nil
        }
    }

    private static func defaultCompactTitle(id: String, fallback: String) -> String {
        switch id {
        case "currentSession", "codexPrimary": "5시간"
        case "weeklyLimit", "codexSecondary": "주간"
        default: fallback
        }
    }
}
