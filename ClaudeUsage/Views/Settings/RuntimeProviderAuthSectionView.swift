import AppKit
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
            RuntimeProviderNextStepCard(
                settings: settings,
                provider: provider,
                presentation: presentation
            )
        }
    }
}

private struct SettingsSectionToggleRow: View {
    let title: String
    let isOn: Binding<Bool>

    var body: some View {
        HStack(spacing: AppDesign.Space.content) {
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
        .padding(.vertical, AppDesign.Space.tight)
        .contentShape(Rectangle())
    }
}

private struct RuntimeProviderStageCard: View {
    let presentation: RuntimeProviderAuthPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.label) {
            HStack(spacing: AppDesign.Space.control) {
                RuntimeProviderBadgeView(title: presentation.badgeTitle, tone: presentation.badgeTone)
                Spacer(minLength: 0)
            }

            Text(presentation.summary)
                .font(AppDesign.Typography.subheadline.weight(.semibold))
        }
        .padding(AppDesign.Space.content)
        .appPanelStyle()
    }
}

private struct RuntimeProviderNextStepCard: View {
    @ObservedObject var settings: AppSettings
    let provider: AppProviderKind
    let presentation: RuntimeProviderAuthPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.control) {
            Text(presentation.nextStepTitle)
                .font(AppDesign.Typography.subheadline.weight(.semibold))
            Text(presentation.nextStepDetail)
                .font(AppDesign.Typography.caption)
                .foregroundStyle(.secondary)
            if let action = presentation.availableAction {
                Button(presentation.nextStepTitle) {
                    perform(action)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, AppDesign.Space.compact)
            }
        }
        .padding(AppDesign.Space.content)
        .appPanelStyle()
    }

    private func perform(_ action: RuntimeProviderAuthPresentation.AvailableAction) {
        switch action {
        case .enableService:
            settings.setProviderEnabled(true, for: provider)
        case .openAntigravityApp:
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.antigravity") {
                NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }
}

struct RuntimeProviderBadgeView: View {
    let title: String
    let tone: RuntimeProviderAuthPresentation.BadgeTone

    var body: some View {
        Text(title)
            .font(AppDesign.Typography.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.16))
            .foregroundStyle(color)
            .cornerRadius(AppDesign.Radius.control)
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
