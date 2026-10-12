import SwiftUI

struct AntigravityPopoverDisplaySettingsSection: View {
    @ObservedObject var viewModel:
        AntigravitySettingsViewModel
    @State private var selectedMode:
        PopoverDisplayEditorMode = .standard

    var body: some View {
        ProviderDisplayEditorShell(
            title: "표시 항목",
            selectedMode: $selectedMode
        ) {
            preview
        } controls: {
            if let display = viewModel.state.display {
                if selectedMode != .standard {
                    compactOrderingPicker(
                        display: display
                    )
                }

                if selectedMode == .hover, viewModel.state.hover.selection == nil {
                    Text("간소화 설정을 따름").font(AppDesign.Typography.caption).foregroundStyle(AppDesign.Text.secondary)
                }
                displayItemsList(display: display)
                    .frame(
                        maxWidth: 420,
                        alignment: .leading
                    )

                Text("드래그해 순서를 바꿉니다.")
                .font(AppDesign.Typography.caption)
                    .foregroundStyle(AppDesign.Text.secondary)
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        if selectedMode == .hover, let display = viewModel.state.display {
            let editing = editingDisplay(display)
            let lanes = quotaPresentation?.allGroups.flatMap(\.lanes) ?? []
            let byID = Dictionary(lanes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let basis = AppSettings.shared.usageDisplayMode.basis ?? UsageValueBasis.antigravity(display.menuBar)
            let items = AntigravityDisplayAdapter.editorItems(
                settings: editing, presentation: quotaPresentation, surface: .hover
            )
            .filter(\.isVisible).map { item in
                let value = byID[item.id]?.value.usedPercentage
                return MenuBarHoverUsageContent.Item(
                    id: item.id.rawValue, title: item.title, compactTitle: item.title,
                    value: value.map { basis.text(fromUsed: $0) } ?? "미확인", isUnknown: value == nil)
            }
            MenuBarHoverUsageView(
                content: MenuBarHoverUsageContent(providers: [
                    .init(kind: .antigravity, basis: basis, items: items)
                ])
            ).padding(AppDesign.Hover.inset).frame(width: AppDesign.Hover.width)
        } else {
            switch viewModel.state.quotaPresentation {
        case .content(let presentation):
            if selectedMode == .compact {
                AntigravityCompactQuotaView(
                    presentation: presentation.compact
                )
            } else {
                VStack(
                    alignment: .leading,
                    spacing: 10
                ) {
                    ProviderIdentityRail(
                        projection:
                            presentation.identityRail
                    )
                    Divider()
                    if presentation.groups.isEmpty {
                        Text("표시할 사용량 한도 없음")
                            .font(AppDesign.Typography.caption)
                                .foregroundStyle(AppDesign.Text.secondary)
                    } else {
                        AntigravityQuotaGroupsView(
                            groups:
                                presentation.groups
                        )
                    }
                }
            }
        case .unavailable(let state):
            Text(unavailableTitle(state))
                .font(AppDesign.Typography.caption)
                    .foregroundStyle(AppDesign.Text.secondary)
                .frame(
                    maxWidth: .infinity,
                    alignment: .leading
                )
        }
        }
    }

    private func compactOrderingPicker(
        display: AntigravityDisplaySettings
    ) -> some View {
        Picker(
            "간소화 보기 순서",
            selection: orderingPolicyBinding(
                display: display
            )
        ) {
            Text("많이 쓴 순")
                .tag(
                    AntigravityDisplaySettings
                        .LaneOrderingPolicy
                        .mostConstrainedFirst
                )
            Text("직접 정렬")
                .tag(
                    AntigravityDisplaySettings
                        .LaneOrderingPolicy
                        .manual
                )
        }
        .frame(maxWidth: 420)
    }

    @ViewBuilder
    private func displayItemsList(
        display: AntigravityDisplaySettings
    ) -> some View {
        let surface = selectedSurface
        let editing = editingDisplay(display)
        let model = AntigravityDisplayAdapter
            .editorModel(
                settings: editing,
                presentation: quotaPresentation,
                surface: surface
            )

        DisplayItemList(
            model: model,
            onToggleVisibility: { itemID in
                let laneID =
                    AntigravityQuotaLaneID(
                        rawValue: itemID
                    )
                guard let item = model.items.first(
                    where: { $0.id == itemID }
                ) else {
                    return
                }
                save(
                    AntigravityDisplayAdapter
                        .settingVisibility(
                            !item.isVisible,
                            for: laneID,
                            surface: surface,
                            presentation:
                                quotaPresentation,
                            in: editing
                        ),
                    replacing: display
                )
            },
            onMoveByOffset: { itemID, offset in
                move(
                    AntigravityQuotaLaneID(
                        rawValue: itemID
                    ),
                    offset: offset,
                    display: display
                )
            },
            onMoveToItem: {
                sourceID,
                targetID in
                guard
                    let sourceIndex =
                        model.items.firstIndex(
                            where: {
                                $0.id == sourceID
                            }
                        ),
                    let targetIndex =
                        model.items.firstIndex(
                            where: {
                                $0.id == targetID
                            }
                        )
                else {
                    return
                }
                move(
                    AntigravityQuotaLaneID(
                        rawValue: sourceID
                    ),
                    offset:
                        targetIndex - sourceIndex,
                    display: display
                )
            }
        )
    }

    private func editingDisplay(_ display: AntigravityDisplaySettings) -> AntigravityDisplaySettings {
        guard selectedMode == .hover else { return display }
        return AntigravityDisplayAdapter.hoverEditorSettings(
            display, hover: viewModel.state.hover,
            presentation: quotaPresentation)
    }

    private var selectedSurface:
        ProviderDisplaySurface
    {
        selectedMode
    }

    private var quotaPresentation:
        AntigravityQuotaPresentation?
    {
        guard case .content(let presentation) =
                viewModel.state.quotaPresentation
        else {
            return nil
        }
        return presentation
    }

    private func orderingPolicyBinding(
        display: AntigravityDisplaySettings
    ) -> Binding<
        AntigravityDisplaySettings
            .LaneOrderingPolicy
    > {
        Binding(
            get: {
                editingDisplay(display).compact.orderingPolicy
            },
            set: { policy in
                save(
                    AntigravityDisplayAdapter
                        .settingOrderingPolicy(
                            policy,
                            surface: selectedSurface,
                            presentation:
                                quotaPresentation,
                            in: editingDisplay(display)
                        ),
                    replacing: display
                )
            }
        )
    }

    private func move(
        _ laneID: AntigravityQuotaLaneID,
        offset: Int,
        display: AntigravityDisplaySettings
    ) {
        save(
            AntigravityDisplayAdapter.moving(
                laneID,
                offset: offset,
                surface: selectedSurface,
                presentation: quotaPresentation,
                in: editingDisplay(display)
            ),
            replacing: display
        )
    }

    private func save(
        _ updated: AntigravityDisplaySettings,
        replacing display:
            AntigravityDisplaySettings
    ) {
        guard updated != editingDisplay(display) else {
            return
        }
        let surface = selectedMode
        let expectedHover = viewModel.state.hover
        Task {
            if surface == .hover {
                _ = await viewModel.updateHover(
                    updated.compact, replacing: expectedHover, expectedDisplay: display)
            } else {
                _ = await viewModel.updateDisplay(updated, replacing: display)
            }
        }
    }

    private func unavailableTitle(
        _ state: AntigravityPresentationState
    ) -> String {
        switch state {
        case .refreshing:
            "확인 중"
        case .failed:
            "사용량을 불러오지 못했습니다."
        case .disabled:
            viewModel.state.connection == nil || viewModel.state.isRuntimeLoading
                ? "설정을 불러오는 중" : "Antigravity 사용이 꺼져 있습니다."
        case .ready,
             .partial,
             .stale:
            "표시할 사용량이 없습니다."
        }
    }
}
