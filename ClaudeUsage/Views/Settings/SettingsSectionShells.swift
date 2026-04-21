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

            content
        }
    }
}

struct ClaudeOrganizationStatusSectionShell<Content: View>: View {
    let title: String
    let systemImage: String
    let summary: String?
    private let content: Content

    init(
        title: String,
        systemImage: String,
        summary: String? = nil,
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

            if let summary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            content
        }
    }
}

struct RuntimeProviderPanelShell<Content: View>: View {
    let descriptor: ProviderShellDescriptor
    let title: String
    let summary: String?
    let detail: String?
    private let content: Content

    init(
        descriptor: ProviderShellDescriptor,
        title: String,
        summary: String? = nil,
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

            if let summary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            content
        }
    }
}
