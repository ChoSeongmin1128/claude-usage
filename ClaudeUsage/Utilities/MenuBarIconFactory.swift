import AppKit
import Foundation

enum MenuBarIconFactory {
    private static var didLogMissingClaudeIconAsset = false
    private static var didLogMissingCodexIconAsset = false

    static func secondaryTextColor(highContrast: Bool) -> NSColor {
        highContrast ? NSColor.labelColor : NSColor.secondaryLabelColor.withAlphaComponent(0.95)
    }

    static func menuBarIconTintColor(for button: NSStatusBarButton, highContrast: Bool) -> NSColor {
        if highContrast {
            return NSColor.labelColor
        }
        let match = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        let base: NSColor = (match == .darkAqua) ? .white : .black
        return base.withAlphaComponent(0.92)
    }

    static func claudeBrandIconTintColor() -> NSColor {
        NSColor.systemOrange
    }

    static func codexMenuBarIcon(size: NSSize) -> NSImage? {
        if let base = NSImage(named: "CodexMenuBarIcon") {
            return twoToneIcon(base, size: size)
        }
        if !didLogMissingCodexIconAsset {
            didLogMissingCodexIconAsset = true
            Logger.warning("CodexMenuBarIcon 에셋 로드 실패, SF Symbol 폴백 사용")
        }
        if let fallback = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: "Codex") {
            return twoToneIcon(fallback, size: size)
        }
        Logger.error("Codex 메뉴바 아이콘 생성 실패(에셋/SF Symbol 모두 실패)")
        return nil
    }

    static func claudeMenuBarIcon(size: NSSize, tint: NSColor) -> NSImage? {
        if let base = NSImage(named: "ClaudeMenuBarIcon") {
            let cropped = imageByTrimmingTransparentPadding(base)
            return tintedIcon(cropped, size: size, tint: tint)
        }
        if !didLogMissingClaudeIconAsset {
            didLogMissingClaudeIconAsset = true
            Logger.warning("ClaudeMenuBarIcon 에셋 로드 실패, SF Symbol 폴백 사용")
        }
        if let fallback = NSImage(systemSymbolName: "brain", accessibilityDescription: "Claude") {
            return tintedIcon(fallback, size: size, tint: tint)
        }
        Logger.error("Claude 메뉴바 아이콘 생성 실패(에셋/SF Symbol 모두 실패)")
        return nil
    }

    private static func tintedIcon(_ source: NSImage, size: NSSize, tint: NSColor) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        tint.setFill()
        rect.fill(using: .sourceIn)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private static func twoToneIcon(_ source: NSImage, size: NSSize) -> NSImage {
        let borderWidth: CGFloat = size.width >= 14 ? 0.7 : 0.55
        let glyphSize = NSSize(
            width: max(1, size.width - borderWidth * 2),
            height: max(1, size.height - borderWidth * 2)
        )
        let baseRect = NSRect(
            x: borderWidth,
            y: borderWidth,
            width: glyphSize.width,
            height: glyphSize.height
        )
        let outline = tintedIcon(source, size: glyphSize, tint: NSColor(calibratedWhite: 0.96, alpha: 1.0))
        let fill = tintedIcon(source, size: glyphSize, tint: NSColor(calibratedWhite: 0.06, alpha: 1.0))
        let offsets: [NSPoint] = [
            NSPoint(x: -borderWidth, y: 0),
            NSPoint(x: borderWidth, y: 0),
            NSPoint(x: 0, y: -borderWidth),
            NSPoint(x: 0, y: borderWidth),
            NSPoint(x: -borderWidth, y: -borderWidth),
            NSPoint(x: borderWidth, y: -borderWidth),
            NSPoint(x: -borderWidth, y: borderWidth),
            NSPoint(x: borderWidth, y: borderWidth)
        ]

        let image = NSImage(size: size)
        image.lockFocus()
        for offset in offsets {
            let rect = baseRect.offsetBy(dx: offset.x, dy: offset.y)
            outline.draw(in: rect)
        }
        fill.draw(in: baseRect)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private static func imageByTrimmingTransparentPadding(_ source: NSImage) -> NSImage {
        guard
            let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let alphaBounds = alphaBoundingBox(in: cg)
        else {
            return source
        }

        let fullBounds = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        if alphaBounds.equalTo(fullBounds) {
            return source
        }

        guard let croppedCG = cg.cropping(to: alphaBounds) else { return source }
        let trimmed = NSImage(cgImage: croppedCG, size: NSSize(width: alphaBounds.width, height: alphaBounds.height))
        trimmed.isTemplate = false
        return trimmed
    }

    private static func alphaBoundingBox(in image: CGImage) -> CGRect? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let totalBytes = bytesPerRow * height
        var raw = [UInt8](repeating: 0, count: totalBytes)

        guard let ctx = CGContext(
            data: &raw,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1

        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width {
                let alpha = raw[row + (x * bytesPerPixel) + 3]
                if alpha > 0 {
                    if x < minX { minX = x }
                    if y < minY { minY = y }
                    if x > maxX { maxX = x }
                    if y > maxY { maxY = y }
                }
            }
        }

        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(
            x: minX,
            y: minY,
            width: (maxX - minX + 1),
            height: (maxY - minY + 1)
        )
    }
}
