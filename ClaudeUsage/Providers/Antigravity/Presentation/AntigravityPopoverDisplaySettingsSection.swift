import SwiftUI

struct AntigravityPopoverDisplaySettingsSection: View {
    @ObservedObject var viewModel:
        AntigravitySettingsViewModel
    @State private var selectedMode:
        PopoverDisplayEditorMode = .standard

    var body: some View {
        ProviderDisplayEditorShell(
            title: "팝오버 표시 항목",
            description:
                "Antigravity 팝오버에서 일반/간소화 보기별 한도와 순서를 정합니다.",
            selectedMode: $selectedMode
        ) {
            preview
        } controls: {
            if let display = viewModel.state.display {
                if selectedMode == .compact {
                    compactOrderingPicker(
                        display: display
                    )
                }

                displayItemsList(display: display)
                    .frame(
                        maxWidth: 420,
                        alignment: .leading
                    )

                Text(
                    "눈 아이콘으로 표시 여부를 바꾸고, 항목을 드래그해 순서를 조정합니다. 데이터가 없는 한도도 선택은 유지됩니다."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
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
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(
                    maxWidth: .infinity,
                    alignment: .leading
                )
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
            Text("제약 높은 순")
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
        let model = AntigravityDisplayAdapter
            .editorModel(
                settings: display,
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
                            in: display
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

    private var selectedSurface:
        ProviderDisplaySurface
    {
        selectedMode == .compact
            ? .compact
            : .standard
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
                display.compact.orderingPolicy
            },
            set: { policy in
                save(
                    AntigravityDisplayAdapter
                        .settingOrderingPolicy(
                            policy,
                            surface: .compact,
                            presentation:
                                quotaPresentation,
                            in: display
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
                in: display
            ),
            replacing: display
        )
    }

    private func save(
        _ updated: AntigravityDisplaySettings,
        replacing display:
            AntigravityDisplaySettings
    ) {
        guard updated != display else {
            return
        }
        Task {
            _ = await viewModel.updateDisplay(
                updated,
                replacing: display
            )
        }
    }

    private func unavailableTitle(
        _ state: AntigravityPresentationState
    ) -> String {
        switch state {
        case .refreshing:
            "사용량을 확인하고 있습니다."
        case .setupRequired:
            "Google 계정 또는 로컬 세션을 먼저 연결해 주세요."
        case .accountMismatch:
            "계정이 일치하지 않아 사용량을 표시하지 않았습니다."
        case .limited:
            "현재 연결에서는 수치형 quota를 제공하지 않습니다."
        case .identityOnly:
            "계정은 확인했지만 표시할 quota가 없습니다."
        case .failed:
            "사용량을 불러오지 못했습니다."
        case .disabled:
            "Antigravity가 비활성화되어 있습니다."
        case .ready,
             .partial,
             .stale:
            "표시할 사용량이 없습니다."
        }
    }
}
