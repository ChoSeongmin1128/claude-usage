import CoreGraphics

/// Single and concentric gauges share their outer contour and optical center.
nonisolated enum RingGeometry {
    static let canvas: CGFloat = 20
    static let outerRadius: CGFloat = 7
    static let innerRadius: CGFloat = 3.5
    static let outerStroke: CGFloat = 2
    static let innerStroke: CGFloat = 1.5
    static let center = CGPoint(x: canvas / 2, y: canvas / 2)
    static let size = CGSize(width: canvas, height: canvas)
}
