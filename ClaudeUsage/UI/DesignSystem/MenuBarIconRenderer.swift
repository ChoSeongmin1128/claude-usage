import AppKit

@MainActor
enum MenuBarIconRenderer {
    private static var isDarkAppearance: Bool {
        NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func batteryIcon(
        percentage: Double?, color: NSColor, showPercent: Bool = true, design: MenuBarDesign = .modern,
        monochrome: Bool = false
    ) -> NSImage {
        batteryImage(
            values: [(percentage, color)], layout: .single, showPercent: showPercent, design: design,
            monochrome: monochrome)
    }

    static func dualBatteryIcon(
        topPercent: Double?, bottomPercent: Double?, topColor: NSColor, bottomColor: NSColor,
        design: MenuBarDesign = .modern
    )
        -> NSImage
    {
        batteryImage(
            values: [(bottomPercent, bottomColor), (topPercent, topColor)], layout: .stacked, showPercent: false,
            design: design)
    }

    static func sideBySideBatteryIcon(
        leftPercent: Double?, rightPercent: Double?, leftColor: NSColor, rightColor: NSColor, showPercent: Bool = true,
        design: MenuBarDesign = .modern, monochrome: Bool = false, rightMonochrome: Bool? = nil
    ) -> NSImage {
        batteryImage(
            values: [(leftPercent, leftColor), (rightPercent, rightColor)], layout: .sideBySide,
            showPercent: showPercent, design: design, monochrome: monochrome, rightMonochrome: rightMonochrome)
    }

    private static func batteryImage(
        values: [(Double?, NSColor)], layout: BatteryGeometry.Layout, showPercent: Bool, design: MenuBarDesign,
        monochrome: Bool = false, rightMonochrome: Bool? = nil
    )
        -> NSImage
    {
        let isDark = isDarkAppearance
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let colors = values.map { $0.1.usingColorSpace(.sRGB) ?? $0.1 }
        let percentages = values.map { $0.0 }
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let size = layout.size(for: design)
        let image = NSImage(size: size, flipped: false) { _ in
            for index in percentages.indices {
                let body = layout.body(at: index, design: design)
                if design == .classic {
                    drawClassicBattery(
                        body: body, percentage: percentages[index], color: colors[index],
                        showPercent: showPercent, isDark: isDark, small: layout == .stacked)
                } else {
                    drawBattery(
                        body: body, percentage: percentages[index], color: colors[index],
                        showPercent: showPercent, isDark: isDark, highContrast: highContrast,
                        cutoutText: (index == 1 ? (rightMonochrome ?? monochrome) : monochrome) && !highContrast
                            && !reduceTransparency)
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private nonisolated static func drawBattery(
        body: NSRect, percentage: Double?, color: NSColor,
        showPercent: Bool, isDark: Bool, highContrast: Bool, cutoutText: Bool
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
            let font = NSFont.systemFont(ofSize: BatteryGeometry.fontSize, weight: .regular)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground]
            let textSize = (text as NSString).size(withAttributes: attributes)
            var origin = NSPoint(x: body.midX - textSize.width / 2, y: body.midY - textSize.height / 2)
            if let context = NSGraphicsContext.current?.cgContext {
                let devicePoint = context.convertToDeviceSpace(origin)
                origin = context.convertToUserSpace(CGPoint(x: devicePoint.x.rounded(), y: devicePoint.y.rounded()))
            }
            // Draw the glyph exactly once across the whole battery. The fill
            // boundary must never split one character into different colors.
            NSGraphicsContext.saveGraphicsState()
            if cutoutText {
                NSGraphicsContext.current?.cgContext.setBlendMode(.destinationOut)
            }
            (text as NSString).draw(at: origin, withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
        if highContrast {
            foreground.setStroke()
            shape.lineWidth = BatteryGeometry.contrastStrokeWidth
            shape.stroke()
        }
        let cap = NSRect(
            x: body.maxX + BatteryGeometry.capGap, y: body.minY + body.height / 3,
            width: BatteryGeometry.capWidth, height: body.height / 3)
        foreground.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: cap, xRadius: 1, yRadius: 1).fill()
    }

    private nonisolated static func classicShadow(isDark: Bool, radius: CGFloat, opacity: CGFloat) -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = (isDark ? NSColor.black : .white).withAlphaComponent(opacity)
        shadow.shadowOffset = .zero
        shadow.shadowBlurRadius = radius
        return shadow
    }

    private nonisolated static func drawClassicBattery(
        body: CGRect, percentage: Double?, color: NSColor, showPercent: Bool, isDark: Bool, small: Bool
    ) {
        let corner: CGFloat = small ? 2 : 3
        let inset: CGFloat = small ? 1 : 1.5
        let stroke = (isDark ? NSColor.white : .black).withAlphaComponent(isDark ? 0.7 : 0.5)
        let outline = NSBezierPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5), xRadius: corner, yRadius: corner)
        outline.lineWidth = small ? 0.8 : 1
        stroke.setStroke()
        outline.stroke()
        let cap = NSRect(
            x: body.maxX, y: body.minY + body.height * (small ? 0.2 : 0.25),
            width: small ? 2.1 : 3, height: body.height * (small ? 0.6 : 0.5))
        stroke.withAlphaComponent(small ? 0.4 : 0.5).setFill()
        NSBezierPath(roundedRect: cap, xRadius: small ? 1 : 1.5, yRadius: small ? 1 : 1.5).fill()
        let value = percentage.flatMap { $0.isFinite ? min(100, max(0, $0)) : nil }
        let fill = CGRect(
            x: body.minX + inset, y: body.minY + inset,
            width: (body.width - inset * 2) * (value ?? 0) / 100, height: body.height - inset * 2)
        color.setFill()
        NSBezierPath(roundedRect: fill, xRadius: max(corner - inset, 0.5), yRadius: max(corner - inset, 0.5)).fill()
        guard showPercent else { return }
        let text = value.map { String(format: "%.0f", $0) } ?? "—"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold),
            .foregroundColor: isDark ? NSColor.white : .black,
            .shadow: classicShadow(isDark: isDark, radius: 3, opacity: 0.95),
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(
            at: NSPoint(x: body.midX - size.width / 2, y: body.midY - size.height / 2), withAttributes: attrs)
    }

    static func circularRingIcon(percentage: Double?, color: NSColor, design: MenuBarDesign = .modern) -> NSImage {
        ringImage(values: [(percentage, color)], design: design)
    }

    static func concentricRingsIcon(
        outerPercent: Double?, innerPercent: Double?, outerColor: NSColor, innerColor: NSColor,
        design: MenuBarDesign = .modern
    ) -> NSImage {
        ringImage(values: [(outerPercent, outerColor), (innerPercent, innerColor)], design: design)
    }

    private static func ringImage(values: [(Double?, NSColor)], design: MenuBarDesign) -> NSImage {
        let foreground: NSColor = isDarkAppearance ? .white : .black
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let isDark = isDarkAppearance
        let classic = design == .classic
        let concentric = values.count > 1
        let size = classic && concentric ? CGSize(width: 22, height: 22) : RingGeometry.size
        let trackAlpha = classic ? (concentric ? (isDark ? 0.15 : 0.08) : (isDark ? 0.2 : 0.12)) : 0.2
        let track = foreground.withAlphaComponent(contrast ? 0.4 : trackAlpha)
        let colors = values.map { $0.1.usingColorSpace(.sRGB) ?? $0.1 }
        let percentages = values.map { $0.0 }
        let image = NSImage(size: size, flipped: false) { _ in
            NSGraphicsContext.saveGraphicsState()
            if classic { classicShadow(isDark: isDark, radius: 1.5, opacity: 0.8).set() }
            for index in percentages.indices {
                drawRing(
                    percentage: percentages[index], color: colors[index], track: track,
                    radius: classic
                        ? (index == 0 ? (concentric ? 7.75 : 6.75) : 4.5)
                        : (index == 0 ? RingGeometry.outerRadius : RingGeometry.innerRadius),
                    stroke: classic
                        ? (index == 0 ? 2.5 : 2) : (index == 0 ? RingGeometry.outerStroke : RingGeometry.innerStroke),
                    center: NSPoint(x: size.width / 2, y: size.height / 2))
            }
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = false
        return image
    }

    private nonisolated static func drawRing(
        percentage: Double?, color: NSColor, track: NSColor, radius: CGFloat, stroke: CGFloat, center: NSPoint
    ) {
        let background = NSBezierPath()
        background.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        background.lineWidth = stroke
        track.setStroke()
        background.stroke()
        guard let percentage, percentage.isFinite, percentage > 0 else { return }
        let foreground = NSBezierPath()
        foreground.appendArc(
            withCenter: center, radius: radius, startAngle: 90,
            endAngle: 90 - min(100, percentage) * 3.6, clockwise: true)
        foreground.lineWidth = stroke
        foreground.lineCapStyle = .round
        color.setStroke()
        foreground.stroke()
    }
}
