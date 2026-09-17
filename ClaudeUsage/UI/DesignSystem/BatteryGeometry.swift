import Foundation
import CoreGraphics

/// Point-based geometry is shared by all battery variants; AppKit rasterizes it at the display scale.
nonisolated enum BatteryGeometry {
    static let bodyWidth: CGFloat = 23
    static let height: CGFloat = 12
    static let capWidth: CGFloat = 1.5
    static let capGap: CGFloat = 1
    static let cornerRadius: CGFloat = 3.5
    static let fontSize: CGFloat = 10
    static let contrastStrokeWidth: CGFloat = 0.75
    static let gap: CGFloat = 3
    static let width = bodyWidth + capGap + capWidth

    enum Layout {
        case single, stacked, sideBySide

        var size: CGSize { size(for: .modern) }

        func size(for design: MenuBarDesign) -> CGSize {
            let width: CGFloat = design == .classic ? 40 : BatteryGeometry.width
            return CGSize(
                width: self == .sideBySide ? width * 2 + gap : width,
                height: design == .classic ? 14 : height)
        }

        func body(at index: Int, design: MenuBarDesign = .modern) -> CGRect {
            let total = size(for: design)
            let spacing: CGFloat = design == .classic && self == .stacked ? 2 : gap
            let bodyHeight = self == .stacked ? (total.height - spacing) / 2 : total.height
            return CGRect(
                x: self == .sideBySide ? CGFloat(index) * ((total.width - gap) / 2 + gap) : 0,
                y: self == .stacked ? CGFloat(index) * (bodyHeight + spacing) : 0,
                width: design == .classic ? 36 : bodyWidth, height: bodyHeight)
        }
    }
}
