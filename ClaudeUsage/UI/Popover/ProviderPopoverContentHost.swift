import SwiftUI

struct ProviderPopoverContentHost: View {
    @ObservedObject var viewModel: PopoverViewModel
    @ObservedObject var settings: AppSettings
    let service: PopoverService
    let layoutSpec: PopoverLayoutSpec
    let sections: [PopoverDisplaySection]
    @Binding var isDisplayEditorPresented: Bool

    var body: some View {
        if service == .antigravity {
            AntigravityPopoverContentView(
                viewModel: viewModel,
                density: layoutSpec.density
            )
        } else if layoutSpec.phase
            == .content
        {
            catalogContent
        } else if service == .claude,
                  layoutSpec.phase
                    == .authRequired
        {
            claudeUnauthenticatedPanel
        } else if let summary =
            CatalogPopoverPresentationAdapter
                .statusSummary(
                    phase: layoutSpec.phase,
                    error: runtimeState.error,
                    service: service,
                    claudeUsesCodeCredentials:
                        claudeUsesCodeCredentials
                )
        {
            statusPanel(summary)
        }
    }

    @ViewBuilder
    private var catalogContent: some View {
        if sections.isEmpty {
            statusPanel(
                CatalogPopoverPresentationAdapter
                    .emptySelectionSummary()
            )
        } else {
            VStack(spacing: 0) {
                ForEach(
                    Array(sections.enumerated()),
                    id: \.element.id
                ) { index, section in
                    if index > 0,
                       !layoutSpec.isCompact
                    {
                        Divider()
                            .padding(.vertical, 8)
                    }
                    PopoverDisplaySectionView(
                        section: section,
                        density: layoutSpec.density
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var claudeUnauthenticatedPanel:
        some View
    {
        if layoutSpec.density == .compact {
            statusPanel(
                CatalogPopoverPresentationAdapter
                    .statusSummary(
                        phase: .authRequired,
                        error: nil,
                        service: .claude
                    )!
            )
        } else {
            VStack(spacing: 12) {
                Image(
                    systemName: "person.badge.key"
                )
                .font(.system(size: 36))
                .foregroundStyle(.orange)
                Text("Claude 로그인이 필요합니다")
                    .font(.headline)
                Text(
                    "Chrome 프로필에 저장된 로그인이나 Claude Code 인증을 그대로 사용할 수 있습니다."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
                HStack(spacing: 8) {
                    Button("Claude 로그인 시작") {
                        viewModel
                            .startClaudeLogin()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    Button("설정 열기") {
                        viewModel.openSettings(
                            for: .claude
                        )
                    }
                    .controlSize(.regular)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        }
    }

    private var runtimeState:
        PopoverViewModel.RuntimeServiceState
    {
        viewModel.runtimeServiceState(
            for: service,
            settings: settings
        )
    }

    private var claudeUsesCodeCredentials: Bool {
        guard service == .claude else {
            return false
        }
        let activeAccount =
            viewModel.usageHealthSnapshot?
                .activeAccount
        return activeAccount?.kind
            == .claudeCodeExternal
            || runtimeState.sourceLabel?
                .hasPrefix("Claude Code")
                == true
    }

    private func statusPanel(
        _ summary: ProviderRuntimeSummary
    ) -> some View {
        StatusPanelView(
            density: layoutSpec.density,
            icon: summary.icon,
            iconColor: color(
                for: summary.tone
            ),
            showsProgress:
                summary.showsProgress,
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
                viewModel.openSettings(for: service)
            }
        case .retry:
            {
                viewModel.refresh(service: service)
            }
        case .startClaudeLogin:
            {
                viewModel.startClaudeLogin()
            }
        case .openDisplayEditor:
            {
                isDisplayEditorPresented = true
            }
        case nil:
            nil
        }
    }
}
