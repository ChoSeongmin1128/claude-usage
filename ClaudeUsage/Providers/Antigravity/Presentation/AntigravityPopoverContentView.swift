import SwiftUI

struct AntigravityPopoverContentView: View {
    @ObservedObject var viewModel: PopoverViewModel
    let density: PopoverDensity

    var body: some View {
        switch viewModel.antigravityRuntimeSnapshot
            .quotaPresentation
        {
        case .content(let presentation):
            if density == .compact {
                AntigravityCompactQuotaView(
                    presentation: presentation.compact
                )
            } else {
                standardContent(presentation)
            }
        case .unavailable:
            let summary =
                AntigravityPopoverPresentationAdapter
                    .statusSummary(
                        for:
                            viewModel
                                .antigravityRuntimeSnapshot
                    )
            StatusPanelView(
                density: density,
                icon: summary.icon,
                iconColor: color(for: summary.tone),
                showsProgress: summary.showsProgress,
                title: summary.title,
                message: summary.message,
                actionTitle: summary.actionTitle,
                actionStyle:
                    summary.actionIsProminent
                        ? .prominent
                        : .bordered,
                action: action(for: summary.action),
                isActionEnabled: summary.action != .retry || viewModel.canRefresh(service: .antigravity)
            )
        }
    }

    @ViewBuilder
    private func standardContent(
        _ presentation:
            AntigravityQuotaPresentation
    ) -> some View {
        if presentation.groups.isEmpty {
            VStack(alignment: .leading, spacing: AppDesign.Space.control) {
                Text("표시할 한도 없음")
                    .font(AppDesign.Typography.subheadline.weight(.semibold))
            }
            .frame(
                maxWidth: .infinity,
                alignment: .leading
            )
        } else {
            AntigravityQuotaGroupsView(
                groups: presentation.groups
            )
        }
    }

    private func color(
        for tone: ProviderRuntimeSummary.Tone
    ) -> Color {
        switch tone {
        case .secondary:
            .secondary
        case .warning:
            .orange
        case .critical:
            .red
        }
    }

    private func action(
        for action: ProviderRuntimeSummary.Action?
    ) -> (() -> Void)? {
        switch action {
        case .openSettings:
            {
                viewModel.openSettings(
                    for: .antigravity
                )
            }
        case .retry:
            {
                viewModel.refresh(
                    service: .antigravity
                )
            }
        case .startClaudeLogin,
            .openDisplaySettings:
            nil
        case nil:
            nil
        }
    }
}
