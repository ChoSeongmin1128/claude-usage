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
        let rowCount: Int
        if service == .antigravity,
           phase == .content,
           case .content(let presentation) =
                antigravityRuntimeSnapshot.quotaPresentation
        {
            if density == .compact {
                rowCount = 1
            } else {
                rowCount = max(
                    1,
                    presentation.groups.reduce(1) {
                        $0 + 1 + $1.lanes.count
                    }
                )
            }
        } else {
            rowCount = phase == .content
                ? max(sections.count, hasContent ? 1 : 0)
                : 0
        }
        let spec = PopoverLayoutMetrics.layoutSpec(
            density: density,
            phase: phase,
            sections: sections,
            rowCount: rowCount,
            // Claude 미인증은 두 버튼짜리 rich 패널을 쓰므로 본문 뷰포트가 더 필요하다.
            // (PopoverView.providerBodyContent의 분기와 같은 조건이어야 한다.)
            richAuthPanel: phase == .authRequired && service == .claude
        )
        return LayoutResult(spec: spec, sections: sections)
    }

    func layoutSpec(for service: PopoverService, settings: AppSettings) -> PopoverLayoutSpec {
        layoutWithSections(for: service, settings: settings).spec
    }

    func contentPhase(for service: PopoverService, settings: AppSettings) -> PopoverContentPhase {
        let runtimeState = runtimeServiceState(for: service, settings: settings)
        if service == .antigravity {
            guard settings.isProviderEnabled(.antigravity) else {
                return .empty
            }
            switch antigravityRuntimeSnapshot.readiness {
            case .bootstrapping:
                return .loading
            case .blocked:
                return .error
            case .shuttingDown:
                return .empty
            case .idle, .ready:
                break
            }
            if antigravityRuntimeSnapshot.hasQuotaContent {
                return .content
            }
            if runtimeState.isAuthRequired {
                return .authRequired
            }
            switch antigravityRuntimeSnapshot.presentationState {
            case .refreshing:
                return .loading
            case .accountMismatch,
                 .limited,
                 .identityOnly,
                 .failed:
                return .error
            case .disabled, .setupRequired:
                return .empty
            case .ready, .partial, .stale:
                return .empty
            }
        }
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
        // Antigravity v2는 동적 lane과 계정/출처 경계를 보존해야 하므로
        // legacy UsageItemContext/Catalog로 다시 평탄화하지 않는다.
        if service == .antigravity {
            return []
        }

        let catalog = UsageItemCatalogRegistry.catalog(for: service)
        let visibleItems = settings.effectivePopoverItems(for: service, density: density).filter(\.visible)
        let context = makeContext(density: density, settings: settings)

        var sections: [PopoverDisplaySection] = []
        for item in visibleItems {
            sections.append(contentsOf: catalog.expandedSections(for: item.id, context: context))
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
            codexError: snapshot(for: .codex)?.error
        )
    }
}
