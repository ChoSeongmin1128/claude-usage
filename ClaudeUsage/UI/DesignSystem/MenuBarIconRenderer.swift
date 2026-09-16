import AppKit

@MainActor
enum MenuBarIconRenderer {
    private static var isDarkAppearance: Bool {
        NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func batteryIcon(percentage: Double?, color: NSColor, showPercent: Bool = true) -> NSImage {
        batteryImage(values: [(percentage, color)], layout: .single, showPercent: showPercent)
    }

    static func dualBatteryIcon(topPercent: Double?, bottomPercent: Double?, topColor: NSColor, bottomColor: NSColor)
        -> NSImage
    {
        batteryImage(
            values: [(bottomPercent, bottomColor), (topPercent, topColor)], layout: .stacked, showPercent: false)
    }

    static func sideBySideBatteryIcon(
        leftPercent: Double?, rightPercent: Double?, leftColor: NSColor, rightColor: NSColor, showPercent: Bool = true
    ) -> NSImage {
        batteryImage(
            values: [(leftPercent, leftColor), (rightPercent, rightColor)], layout: .sideBySide,
            showPercent: showPercent)
    }

    private static func batteryImage(values: [(Double?, NSColor)], layout: BatteryGeometry.Layout, showPercent: Bool)
        -> NSImage
    {
        let isDark = isDarkAppearance
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let colors = values.map { $0.1.usingColorSpace(.sRGB) ?? $0.1 }
        let percentages = values.map { $0.0 }
        let size = layout.size
        let image = NSImage(size: size, flipped: false) { _ in
            for index in percentages.indices {
                drawBattery(
                    body: layout.body(at: index), percentage: percentages[index], color: colors[index],
                    showPercent: showPercent, isDark: isDark, highContrast: highContrast)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private nonisolated static func drawBattery(
        body: NSRect, percentage: Double?, color: NSColor,
        showPercent: Bool, isDark: Bool, highContrast: Bool
    ) {
        let foreground: NSColor = isDark ? .white : .black
        let shape = NSBezierPath(
            roundedRect: body, xRadius: min(BatteryGeometry.cornerRadius, body.height / 2),
            yRadius: min(BatteryGeometry.cornerRadius, body.height / 2))
        let validValue = percentage.flatMap { $0.isFinite ? min(100, max(0, $0)) : nil }
        let fill = NSRect(x: body.minX, y: body.minY, width: body.width * (validValue ?? 0) / 100, height: body.height)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        foreground.withAlphaComponent(highContrast ? 0.3 : 0.2).setFill()
        body.fill()
        color.setFill()
        fill.fill()
        if showPercent {
            let text = validValue.map { String(format: "%.0f", $0) } ?? "—"
            let font = NSFont.monospacedDigitSystemFont(ofSize: BatteryGeometry.fontSize, weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground]
            let textSize = (text as NSString).size(withAttributes: attributes)
            let origin = NSPoint(x: body.midX - textSize.width / 2, y: body.midY - textSize.height / 2)
            (text as NSString).draw(at: origin, withAttributes: attributes)
            // Render glyph portions over the colored fill with their own contrast.
            NSGraphicsContext.saveGraphicsState()
            fill.clip()
            let luminance = color.redComponent * 0.2126 + color.greenComponent * 0.7152 + color.blueComponent * 0.0722
            (text as NSString).draw(
                at: origin,
                withAttributes: [.font: font, .foregroundColor: luminance > 0.55 ? NSColor.black : NSColor.white])
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
        if highContrast {
            foreground.setStroke()
            shape.lineWidth = BatteryGeometry.contrastStrokeWidth
            shape.stroke()
        }
        let cap = NSRect(
            x: body.maxX + BatteryGeometry.capGap, y: body.minY + body.height * 0.3,
            width: BatteryGeometry.capWidth, height: body.height * 0.4)
        foreground.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: cap, xRadius: 1, yRadius: 1).fill()
    }

    static func circularRingIcon(percentage: Double?, color: NSColor) -> NSImage {
        ringImage(values: [(percentage, color)])
    }

    static func concentricRingsIcon(
        outerPercent: Double?, innerPercent: Double?, outerColor: NSColor, innerColor: NSColor
    ) -> NSImage {
        ringImage(values: [(outerPercent, outerColor), (innerPercent, innerColor)])
    }

    private static func ringImage(values: [(Double?, NSColor)]) -> NSImage {
        let foreground: NSColor = isDarkAppearance ? .white : .black
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let track = foreground.withAlphaComponent(contrast ? 0.4 : 0.2)
        let colors = values.map { $0.1.usingColorSpace(.sRGB) ?? $0.1 }
        let percentages = values.map { $0.0 }
        let image = NSImage(size: RingGeometry.size, flipped: false) { _ in
            for index in percentages.indices {
                drawRing(
                    percentage: percentages[index], color: colors[index], track: track,
                    radius: index == 0 ? RingGeometry.outerRadius : RingGeometry.innerRadius,
                    stroke: index == 0 ? RingGeometry.outerStroke : RingGeometry.innerStroke)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private nonisolated static func drawRing(
        percentage: Double?, color: NSColor, track: NSColor, radius: CGFloat, stroke: CGFloat
    ) {
        let background = NSBezierPath()
        background.appendArc(withCenter: RingGeometry.center, radius: radius, startAngle: 0, endAngle: 360)
        background.lineWidth = stroke
        track.setStroke()
        background.stroke()
        guard let percentage, percentage.isFinite, percentage > 0 else { return }
        let foreground = NSBezierPath()
        foreground.appendArc(
            withCenter: RingGeometry.center, radius: radius, startAngle: 90,
            endAngle: 90 - min(100, percentage) * 3.6, clockwise: true)
        foreground.lineWidth = stroke
        foreground.lineCapStyle = .round
        color.setStroke()
        foreground.stroke()
    }
}
