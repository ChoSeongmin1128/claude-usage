import SwiftUI

struct MenuBarPresetTile<Preview: View, Editing: View>: View {
    let title: String
    let isBuiltin: Bool
    let isSelected: Bool
    let apply: () -> Void
    @ViewBuilder let preview: () -> Preview
    @ViewBuilder let editing: () -> Editing
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: apply) {
            VStack(alignment: .leading, spacing: AppDesign.Space.tight) {
                HStack {
                    if isBuiltin { Image(systemName: "lock.fill").accessibilityHidden(true) }
                    Text(isBuiltin ? "기본 제공" : "내 프리셋")
                }.font(AppDesign.Typography.metadata).foregroundStyle(AppDesign.Text.secondary)
                Text(title).font(AppDesign.Typography.body.weight(.medium)).lineLimit(1)
                    .padding(.trailing, AppDesign.Control.regularHitSize)
                preview().frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(AppDesign.Space.row)
            .frame(
                maxWidth: .infinity, minHeight: AppDesign.Control.presetTileHeight,
                maxHeight: AppDesign.Control.presetTileHeight, alignment: .leading
            )
            .appPanelStyle(role: isBuiltin ? .low : .editable, radius: AppDesign.Radius.card)
            .contentShape(RoundedRectangle(cornerRadius: AppDesign.Radius.card))
        }
        .buttonStyle(.plain).focused($focused)
        .accessibilityLabel(title)
        .accessibilityValue("\(isBuiltin ? "기본 제공" : "사용자 프리셋"), \(isSelected ? "선택됨" : "선택 안 됨")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .overlay(alignment: .topTrailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                    .font(AppDesign.Typography.noticeIcon).padding(AppDesign.Space.row).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .trailing) {
            editing().padding(.trailing, AppDesign.Space.row)
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppDesign.Radius.card + 2)
                .stroke(isSelected ? Color.accentColor : .clear, lineWidth: AppDesign.Control.presetSelectionStroke)
                .padding(-2).allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppDesign.Radius.card + AppDesign.Space.compact)
                .stroke(focused ? Color.primary : .clear, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                .padding(-AppDesign.Space.compact).allowsHitTesting(false)
        }
    }
}
