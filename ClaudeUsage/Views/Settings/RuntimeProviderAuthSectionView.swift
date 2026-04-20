import SwiftUI

struct RuntimeProviderOverviewSectionView: View {
    @ObservedObject var settings: AppSettings
    let provider: AppProviderKind
    let descriptor: ProviderShellDescriptor
    let presentation: RuntimeProviderAuthPresentation

    var body: some View {
        RuntimeProviderPanelShell(
            descriptor: descriptor,
            title: "\(descriptor.title) 개요",
            summary: "현재 상태와 다음 행동만 먼저 보여줍니다.",
            detail: descriptor.detail
        ) {
            SettingsSectionToggleRow(
                title: "\(descriptor.title) 사용",
                isOn: Binding(
                    get: { settings.isProviderEnabled(provider) },
                    set: { settings.setProviderEnabled($0, for: provider) }
                )
            )

            RuntimeProviderStageCard(presentation: presentation)
            RuntimeProviderActionCard(presentation: presentation)
        }
    }
}

private struct SettingsSectionToggleRow: View {
    let title: String
    let isOn: Binding<Bool>

    var body: some View {
        HStack(spacing: 12) {
            Button {
                isOn.wrappedValue.toggle()
            } label: {
                Text(title)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Toggle("", isOn: isOn)
                .labelsHidden()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

private struct RuntimeProviderStageCard: View {
    let presentation: RuntimeProviderAuthPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                RuntimeProviderBadgeView(title: presentation.badgeTitle, tone: presentation.badgeTone)
                Spacer(minLength: 0)
            }

            Text(presentation.summary)
                .font(.subheadline.weight(.semibold))
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
}

private struct RuntimeProviderActionCard: View {
    let presentation: RuntimeProviderAuthPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("지금 할 일")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(presentation.primaryActionTitle)
                .font(.subheadline.weight(.semibold))
            Text(presentation.primaryActionDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.45))
        .cornerRadius(8)
    }
}

private struct RuntimeProviderBadgeView: View {
    let title: String
    let tone: RuntimeProviderAuthPresentation.BadgeTone

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.16))
            .foregroundStyle(color)
            .cornerRadius(6)
    }

    private var color: Color {
        switch tone {
        case .secondary:
            return .secondary
        case .blue:
            return .blue
        case .orange:
            return .orange
        case .red:
            return .red
        }
    }
}
