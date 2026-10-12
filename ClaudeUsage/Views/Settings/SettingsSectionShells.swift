import SwiftUI

struct ClaudeSetupSectionShell<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.content) {
            ProviderSettingsSectionHeader(
                provider: .claude,
                title: "Claude"
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
                    .foregroundStyle(AppDesign.Text.secondary)
            }

            content
        }
    }
}
