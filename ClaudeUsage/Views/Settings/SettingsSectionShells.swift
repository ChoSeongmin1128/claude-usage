import SwiftUI

struct ClaudeSetupSectionShell<Content: View>: View {
    let presentation: ClaudeSetupPresentation
    private let content: Content

    init(
        presentation: ClaudeSetupPresentation,
        @ViewBuilder content: () -> Content
    ) {
        self.presentation = presentation
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Claude 사용", systemImage: "brain")
                .font(.headline)

            Text(shellSummary(for: presentation.progress.stage))
                .font(.caption)
                .foregroundStyle(.secondary)

            content
        }
    }

    private func shellSummary(for stage: SetupCompletionPolicy.WizardStage) -> String {
        switch stage {
        case .credential:
            return "로그인만 마치면 바로 사용할 수 있습니다."
        case .verification:
            return "연결 확인만 끝나면 사용할 수 있습니다."
        case .organization:
            return "필요하면 조직만 고르면 됩니다."
        case .complete:
            return "지금 필요한 상태와 다음 행동만 보여줍니다."
        }
    }
}

struct ClaudeOrganizationStatusSectionShell<Content: View>: View {
    let title: String
    let systemImage: String
    let summary: String
    private let content: Content

    init(
        title: String,
        systemImage: String,
        summary: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.summary = summary
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)

            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)

            content
        }
    }
}

struct RuntimeProviderPanelShell<Content: View>: View {
    let descriptor: ProviderShellDescriptor
    let title: String
    let summary: String
    let detail: String?
    private let content: Content

    init(
        descriptor: ProviderShellDescriptor,
        title: String,
        summary: String,
        detail: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.descriptor = descriptor
        self.title = title
        self.summary = summary
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: descriptor.icon)
                .font(.headline)

            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)

            content
        }
    }
}
