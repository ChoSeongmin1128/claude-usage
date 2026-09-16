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
        VStack(alignment: .leading, spacing: AppDesign.Space.content) {
            ProviderSettingsSectionHeader(
                provider: .claude,
                title: "Claude 사용"
            )

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
        VStack(alignment: .leading, spacing: AppDesign.Space.label) {
            Label(title, systemImage: systemImage)
                .font(AppDesign.Typography.headline)

            if let summary {
                Text(summary)
                    .font(AppDesign.Typography.caption)
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
        VStack(alignment: .leading, spacing: AppDesign.Space.content) {
            ProviderSettingsSectionHeader(
                provider: descriptor.kind,
                title: title
            )

            if let summary {
                Text(summary)
                    .font(AppDesign.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            content
        }
    }
}
