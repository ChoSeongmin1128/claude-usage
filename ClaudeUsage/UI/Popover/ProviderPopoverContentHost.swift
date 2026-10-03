import SwiftUI

struct ProviderPopoverContentHost: View {
    @ObservedObject var viewModel: PopoverViewModel
    @ObservedObject var settings: AppSettings
    let service: PopoverService
    let layoutSpec: PopoverLayoutSpec
    let sections: [PopoverDisplaySection]
    let onOpenDisplayEditor: () -> Void

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
            PopoverCatalogSectionList(sections: sections, density: layoutSpec.density)
        }
    }

    @ViewBuilder
    private var claudeUnauthenticatedPanel: some View {
        if layoutSpec.density == .compact {
            statusPanel(
                CatalogPopoverPresentationAdapter
                    .statusSummary(
                        phase: .authRequired,
                        error: nil,
                        service: .claude,
                        claudeCodeCredentialIssue:
                            viewModel.claudeCodeCredentialIssue
                    )!
            )
        } else {
            VStack(spacing: AppDesign.Space.content) {
                Image(
                    systemName: "person.badge.key"
                )
                .font(AppDesign.Typography.setupIcon)
                .foregroundStyle(.orange)
                Text(unauthenticatedCopy.title)
                    .font(AppDesign.Typography.headline)
                Text(unauthenticatedCopy.message)
                .font(AppDesign.Typography.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppDesign.Space.section)
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
                HStack(spacing: AppDesign.Space.row) {
                    Button(unauthenticatedCopy.action) {
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

    private var unauthenticatedCopy: (title: String, message: String, action: String) {
        switch viewModel.claudeCodeCredentialIssue {
        case .reconnectRequired:
            return (
                "Claude Code 다시 연결이 필요합니다",
                "Claude Code 로그인은 그대로입니다. 다시 연결하면 최신 로그인을 가져오며, macOS가 Keychain 사용을 물을 수 있습니다.",
                "다시 연결"
            )
        case .reauthenticationRequired:
            return (
                "Claude Code 다시 로그인이 필요합니다",
                "Claude Code의 인증 갱신이 거부됐습니다. 터미널에서 `claude auth login`을 실행한 뒤 다시 연결해 주세요.",
                "다시 연결"
            )
        case nil:
            return (
                "Claude 로그인이 필요합니다",
                "브라우저나 Claude 앱에 저장된 로그인, Claude Code 인증을 그대로 사용할 수 있습니다.",
                "Claude 로그인 시작"
            )
        }
    }

    private var runtimeState: PopoverViewModel.RuntimeServiceState {
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
            onOpenDisplayEditor
        case nil:
            nil
        }
    }
}
