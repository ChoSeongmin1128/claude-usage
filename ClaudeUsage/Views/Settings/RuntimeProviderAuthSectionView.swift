import SwiftUI

struct RuntimeProviderOverviewSectionView: View {
    @ObservedObject var settings: AppSettings
    let provider: AppProviderKind
    let descriptor: ProviderShellDescriptor
    let presentation: RuntimeProviderAuthPresentation
    let hint: String?

    var body: some View {
        RuntimeProviderPanelShell(
            descriptor: descriptor,
            title: "\(descriptor.title) 개요",
            summary: "현재 상태와 다음 행동만 먼저 보여줍니다.",
            detail: descriptor.detail
        ) {
            SettingsSectionToggleRow(
                title: "\(descriptor.title) provider 활성화",
                isOn: Binding(
                    get: { settings.isProviderEnabled(provider) },
                    set: { settings.setProviderEnabled($0, for: provider) }
                )
            )

            RuntimeProviderStageCard(presentation: presentation)
            RuntimeProviderActionCard(presentation: presentation)

            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct RuntimeProviderAdvancedSectionView: View {
    let descriptor: ProviderShellDescriptor
    let presentation: RuntimeProviderAuthPresentation
    let footnote: String
    let onRefreshEnvironment: () -> Void

    var body: some View {
        RuntimeProviderPanelShell(
            descriptor: descriptor,
            title: "\(descriptor.title) 고급",
            summary: "감지 상태와 진단 경로를 확인하는 저빈도 화면입니다.",
            detail: descriptor.detail
        ) {
            RuntimeProviderDetectorCard(summary: presentation.detectorSummary)

            if !presentation.pathHints.isEmpty {
                RuntimeProviderPathHintsCard(pathHints: presentation.pathHints)
            }

            Button("환경 다시 읽기", action: onRefreshEnvironment)
                .buttonStyle(.bordered)
                .controlSize(.small)

            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
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

            if !presentation.steps.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(presentation.steps) { step in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 5))
                                .foregroundStyle(.secondary)
                                .padding(.top, 5)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.title)
                                    .font(.caption.weight(.semibold))
                                Text(step.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
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
            Text("다음 행동")
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

private struct RuntimeProviderDetectorCard: View {
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("감지 상태")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.45))
        .cornerRadius(8)
    }
}

private struct RuntimeProviderPathHintsCard: View {
    let pathHints: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("확인할 경로")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(pathHints, id: \.self) { path in
                Text(path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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
