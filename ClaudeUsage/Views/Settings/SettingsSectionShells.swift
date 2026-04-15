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
            Label("Claude 개요", systemImage: "brain")
                .font(.headline)

            Text("현재 단계: \(stageText(presentation.progress.stage))")
                .font(.caption)
                .foregroundStyle(.secondary)

            content
        }
    }

    private func stageText(_ stage: SetupCompletionPolicy.WizardStage) -> String {
        switch stage {
        case .credential:
            return "자격 준비"
        case .verification:
            return "연결 검증"
        case .organization:
            return "Organization 확인"
        case .complete:
            return "완료"
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

            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            content
        }
    }
}

struct UpdateDiagnosticsSectionShell<Content: View>: View {
    let updateModeSummary: String
    private let content: Content

    init(
        updateModeSummary: String,
        @ViewBuilder content: () -> Content
    ) {
        self.updateModeSummary = updateModeSummary
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("업데이트", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)

            Text(updateModeSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            content
        }
    }
}
