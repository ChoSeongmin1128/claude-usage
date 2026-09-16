import Foundation
import CoreGraphics

/// Point-based geometry is shared by all battery variants; AppKit rasterizes it at the display scale.
nonisolated enum BatteryGeometry {
    static let bodyWidth: CGFloat = 25
    static let height: CGFloat = 13
    static let capWidth: CGFloat = 2
    static let capGap: CGFloat = 1
    static let cornerRadius: CGFloat = 3.5
    static let fontSize: CGFloat = 9
    static let contrastStrokeWidth: CGFloat = 0.75
    static let gap: CGFloat = 3
    static let width = bodyWidth + capGap + capWidth

    enum Layout {
        case single, stacked, sideBySide

        var size: CGSize {
            CGSize(width: self == .sideBySide ? width * 2 + gap : width, height: height)
        }

        func body(at index: Int) -> CGRect {
            let bodyHeight = self == .stacked ? (height - gap) / 2 : height
            return CGRect(
                x: self == .sideBySide ? CGFloat(index) * (width + gap) : 0,
                y: self == .stacked ? CGFloat(index) * (bodyHeight + gap) : 0,
                width: bodyWidth, height: bodyHeight
            )
        }
    }
}
