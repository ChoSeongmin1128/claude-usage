import Foundation

extension PopoverViewModel {
    struct LayoutResult {
        let spec: PopoverLayoutSpec
        let sections: [PopoverDisplaySection]
    }

    func layoutWithSections(for service: PopoverService, settings: AppSettings) -> LayoutResult {
        let density: PopoverDensity = settings.popoverCompact ? .compact : .standard
        let phase = contentPhase(for: service, settings: settings)
        let sections = displaySections(for: service, density: density, settings: settings)
        let hasContent = runtimeServiceState(for: service, settings: settings).hasContent
        let rowCount = phase == .content ? max(sections.count, hasContent ? 1 : 0) : 0
        let spec = PopoverLayoutMetrics.layoutSpec(
            density: density,
            phase: phase,
            sections: sections,
            rowCount: rowCount
        )
        return LayoutResult(spec: spec, sections: sections)
    }

    func layoutSpec(for service: PopoverService, settings: AppSettings) -> PopoverLayoutSpec {
        layoutWithSections(for: service, settings: settings).spec
    }

    func contentPhase(for service: PopoverService, settings: AppSettings) -> PopoverContentPhase {
        let runtimeState = runtimeServiceState(for: service, settings: settings)
        if runtimeState.isAuthRequired {
            return .authRequired
        }
        if runtimeState.isLoading && !runtimeState.hasContent {
            return .loading
        }
        if runtimeState.error != nil && !runtimeState.hasContent {
            return .error
        }
        if runtimeState.hasContent {
            return .content
        }
        return .empty
    }

    /// provider 구분 없이 동작하는 통합 섹션 생성기.
    ///
    /// 동작:
    /// 1. 해당 provider의 `UsageItemCatalog`를 찾고
    /// 2. 사용자가 저장한 visible 항목 ID를 순서대로 읽고
    /// 3. Catalog가 각 ID를 섹션으로 변환
    /// 4. Claude의 `modelUsage`처럼 1:N 확장이 필요한 항목은 `expandedSections`로 처리
    /// 5. compact density에서는 `.primary` 섹션만 반환
    func displaySections(
        for service: PopoverService,
        density: PopoverDensity,
        settings: AppSettings
    ) -> [PopoverDisplaySection] {
        let catalog = UsageItemCatalogRegistry.catalog(for: service)
        let visibleItems = settings.effectivePopoverItems(for: service, density: density).filter(\.visible)
        let context = makeContext(density: density, settings: settings)

        var sections: [PopoverDisplaySection] = []
        for item in visibleItems {
            sections.append(contentsOf: catalog.expandedSections(for: item.id, context: context))
        }

        if service == .antigravity,
           let usage = context.antigravityUsage,
           !usage.hasUsageWindows,
           !sections.contains(where: { $0.id == "antigravityQuotaStatus" })
        {
            sections.insert(
                PopoverDisplaySection(
                    id: "antigravityQuotaStatus",
                    kind: .status,
                    importance: .primary,
                    payload: .status(
                        PopoverStatusSectionData(
                            title: "계정 확인됨",
                            error: nil,
                            statusText: "수치 미지원",
                            message: "계정과 플랜은 확인됐지만 Antigravity가 아직 사용량 수치를 제공하지 않았습니다."
                        )
                    )
                ),
                at: 0
            )
        }

        if service == .antigravity,
           let usage = context.antigravityUsage,
           usage.hasUsageWindows,
           context.settings.visibleAntigravityModelWindows(from: usage.modelWindows).isEmpty,
           !sections.contains(where: { $0.kind == .usage }),
           !sections.contains(where: { $0.id == "antigravityHiddenModelsStatus" })
        {
            sections.insert(
                PopoverDisplaySection(
                    id: "antigravityHiddenModelsStatus",
                    kind: .status,
                    importance: .primary,
                    payload: .status(
                        PopoverStatusSectionData(
                            title: "표시할 모델 없음",
                            error: nil,
                            statusText: "숨김",
                            message: "설정에서 팝오버에 표시할 Antigravity 모델을 선택하세요."
                        )
                    )
                ),
                at: 0
            )
        }

        if density == .compact {
            return sections.filter { $0.importance == .primary }
        }
        return sections
    }

    // MARK: - Context 조립

    private func makeContext(density: PopoverDensity, settings: AppSettings) -> UsageItemContext {
        let currentAccountState = ClaudeAccountStore.shared.state()
        let presentedAccountState = ClaudeAccountSnapshotPresentationPolicy.resolve(
            snapshotActiveAccountID: usageHealthSnapshot?.activeAccountID,
            currentState: currentAccountState
        )
        return UsageItemContext(
            density: density,
            settings: settings,
            claudeUsage: claudeUsage,
            claudeOverage: overage,
            claudeAccounts: presentedAccountState?.accounts ?? [],
            activeClaudeAccountID: presentedAccountState?.activeAccountID,
            codexUsage: codexUsage,
            codexError: snapshot(for: .codex)?.error,
            antigravityUsage: antigravityUsage
        )
    }
}
