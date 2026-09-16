import SwiftUI

/// Compact actions retain their position and a stable target while labels describe the outcome.
struct IconActionButton: View {
    let symbol: String
    let label: String
    var compact = true
    var isActive = false
    var isLoading = false
    var isEnabled = true
    var isExternal = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol)
                        .font(AppDesign.Typography.icon)
                        .overlay(alignment: .topTrailing) {
                            if isExternal {
                                Image(systemName: "arrow.up.right")
                                    .font(AppDesign.Control.externalBadgeFont)
                                    .offset(x: 5, y: -3)
                            }
                        }
                }
            }
            .frame(width: targetSize, height: targetSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
        .disabled(!isEnabled)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(isLoading ? "갱신 중" : isActive ? "선택됨" : "")
    }

    private var targetSize: CGFloat {
        compact ? AppDesign.Control.compactHitSize : AppDesign.Control.regularHitSize
    }
}
