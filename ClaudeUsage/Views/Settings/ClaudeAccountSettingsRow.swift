import SwiftUI

struct ClaudeAccountSettingsRow: View {
    let presentation: ClaudeAccountSettingsPresentation
    let isActive: Bool
    let onAction: (ClaudeAccountSettingsAction) -> Void
    @State private var isExpanded = false

    var body: some View {
        SettingsDisclosureControl(
            isExpanded: $isExpanded,
            accessibilityLabel: [
                presentation.primaryTitle, presentation.sourceLabel, presentation.secondaryLine,
                isActive ? "사용 중" : nil, presentation.statusText, "상세",
            ]
            .compactMap { $0 }.joined(separator: ", ")
        ) {
            HStack(spacing: AppDesign.Space.row) {
                Image(systemName: presentation.systemImage)
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: AppDesign.Space.tight) {
                    Text(presentation.primaryTitle)
                        .font(AppDesign.Typography.subheadline.weight(.semibold))
                        .lineLimit(1).truncationMode(.middle)
                        .help(presentation.primaryTitle)
                    Text(
                        [presentation.sourceLabel, presentation.secondaryLine].compactMap { $0 }.joined(
                            separator: " · ")
                    )
                    .font(AppDesign.Typography.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: AppDesign.Space.row)
                VStack(alignment: .trailing, spacing: AppDesign.Space.tight) {
                    if isActive {
                        Text("사용 중").font(AppDesign.Typography.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    Text(presentation.statusText)
                        .font(AppDesign.Typography.caption)
                        .foregroundStyle(presentation.statusTone.color)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        } actions: {
            if let action = presentation.switchAction {
                Button(action.title) { onAction(action) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .accessibilityLabel("\(presentation.primaryTitle) 사용")
            }
        } content: {
            VStack(alignment: .leading, spacing: AppDesign.Space.control) {
                ForEach(presentation.detailRows, id: \.self) { row in
                    HStack(alignment: .firstTextBaseline, spacing: AppDesign.Space.row) {
                        Text(row.title).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
                        Text(row.value).textSelection(.enabled)
                    }
                    .font(AppDesign.Typography.caption)
                }
                HStack(spacing: AppDesign.Space.row) {
                    ForEach(presentation.managementActions, id: \.self) { action in
                        Button(action.title) { onAction(action) }.controlSize(.small)
                    }
                }
            }
            .padding(.horizontal, AppDesign.Space.control)
            .padding(.bottom, AppDesign.Space.control)
        }
        .padding(AppDesign.Space.compact)
        .background(
            isActive ? Color.accentColor.opacity(0.08) : .clear,
            in: RoundedRectangle(cornerRadius: AppDesign.Radius.group))
    }
}

extension ClaudeAccountStatusTone {
    var color: Color {
        switch self {
        case .neutral: return .secondary
        case .success: return .green
        case .warning: return .orange
        }
    }
}
