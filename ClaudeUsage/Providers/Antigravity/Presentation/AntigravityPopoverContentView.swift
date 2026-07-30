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
                action: action(for: summary.action)
            )
        }
    }

    @ViewBuilder
    private func standardContent(
        _ presentation:
            AntigravityQuotaPresentation
    ) -> some View {
        if presentation.groups.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("표시할 사용량 한도 없음")
                    .font(.subheadline.weight(.semibold))
                Text(
                    "현재 응답에는 표시하도록 선택한 수치형 quota가 없습니다."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
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
             .openDisplayEditor:
            nil
        case nil:
            nil
        }
    }
}
