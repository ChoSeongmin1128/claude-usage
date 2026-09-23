import SwiftUI

/// Only the selected provider owns a surface and outline; brand colors stay unchanged.
struct ProviderSelectorButtonLabel: View {
    @Environment(\.colorSchemeContrast) private var contrast

    let provider: AppProviderKind
    let isSelected: Bool
    let showsWarning: Bool
    let compact: Bool

    var body: some View {
        let buttonSize = PopoverLayoutMetrics.providerSelectorSize(compact: compact)
        let iconSize = PopoverLayoutMetrics.providerIconSize(compact: compact)
        let warningDotSize = PopoverLayoutMetrics.providerWarningDotSize(compact: compact)
        let warningDotInset = PopoverLayoutMetrics.providerWarningDotInset(compact: compact)

        ProviderBrandIconView(provider: provider, kind: .popover, size: iconSize)
            .frame(width: buttonSize, height: buttonSize)
            .background(isSelected ? AppDesign.Surface.selection : .clear, in: shape)
            .overlay {
                if isSelected {
                    shape.strokeBorder(
                        Color.accentColor,
                        lineWidth: contrast == .increased ? 2 : AppDesign.Control.selectionStrokeWidth)
                }
            }
            .overlay(alignment: .topTrailing) {
                if showsWarning {
                    Circle()
                        .fill(Color.orange)
                        .overlay {
                            Circle()
                                .stroke(Color(NSColor.windowBackgroundColor), lineWidth: 1)
                        }
                        .frame(width: warningDotSize, height: warningDotSize)
                        .padding(warningDotInset)
                        .accessibilityHidden(true)
                }
            }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: compact ? AppDesign.Radius.control : AppDesign.Radius.group,
            style: .continuous)
    }

}
