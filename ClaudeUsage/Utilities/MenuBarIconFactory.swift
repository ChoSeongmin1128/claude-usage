import AppKit
import Foundation

enum MenuBarIconFactory {
    private struct ProviderIconCacheKey: Hashable {
        let provider: AppProviderKind
        let width: Int
        let height: Int
        let appearance: MenuBarAppearanceKey
    }

    private static var providerIconCache:
        [ProviderIconCacheKey: NSImage] = [:]

    static func secondaryTextColor(highContrast: Bool) -> NSColor {
        highContrast ? NSColor.labelColor : NSColor.secondaryLabelColor
    }

    static func providerMenuBarIcon(
        for provider: AppProviderKind,
        size: NSSize,
        appearance: NSAppearance
    ) -> NSImage? {
        let cacheKey = ProviderIconCacheKey(
            provider: provider,
            width: Int((size.width * 100).rounded()),
            height: Int((size.height * 100).rounded()),
            appearance: MenuBarAppearanceKey(appearance)
        )
        if let cached = providerIconCache[cacheKey] {
            return cached
        }

        var resolvedImage: NSImage?
        appearance.performAsCurrentDrawingAppearance {
            if let base = ProviderBrandIconResolver.baseImage(for: provider) {
                resolvedImage = rasterizedIcon(base, size: size, appearance: appearance)
                return
            }

            if let symbol = provider.fallbackSystemSymbolName,
               let fallback = NSImage(systemSymbolName: symbol, accessibilityDescription: provider.displayName) {
                resolvedImage = rasterizedIcon(fallback, size: size, appearance: appearance)
                return
            }

            Logger.error("\(provider.displayName) 메뉴바 아이콘 생성 실패")
        }
        if let resolvedImage {
            providerIconCache[cacheKey] = resolvedImage
        }
        return resolvedImage
    }

    static func resetProviderIconCacheForTesting() {
        providerIconCache.removeAll()
    }

    static func badgedIcon(
        _ base: NSImage,
        indicator: StatusIndicator,
        appearance: NSAppearance
    ) -> NSImage {
        guard indicator != .none else { return base }

        var renderedImage = base
        appearance.performAsCurrentDrawingAppearance {
            let size = base.size
            let badgeRect = statusBadgeRect(
                for: size,
                indicator: indicator
            )
            let badgeColor: NSColor = indicator == .minor ? .systemOrange : .systemRed
            let image = NSImage(size: size)
            image.lockFocus()
            defer { image.unlockFocus() }

            let rect = NSRect(origin: .zero, size: size)
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)

            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let outlineColor = (isDark ? NSColor.black : NSColor.white).withAlphaComponent(0.92)
            let outlinePath = NSBezierPath(ovalIn: badgeRect.insetBy(dx: -1, dy: -1))
            outlineColor.setFill()
            outlinePath.fill()

            let badgePath = NSBezierPath(ovalIn: badgeRect)
            badgeColor.setFill()
            badgePath.fill()

            if indicator == .critical {
                let text = "!"
                let font = NSFont.systemFont(ofSize: 6, weight: .bold)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor.white,
                ]
                let textSize = (text as NSString).size(withAttributes: attrs)
                let point = NSPoint(
                    x: badgeRect.midX - textSize.width / 2,
                    y: badgeRect.midY - textSize.height / 2
                )
                (text as NSString).draw(at: point, withAttributes: attrs)
            }

            image.isTemplate = false
            renderedImage = image
        }
        return renderedImage
    }

    static func statusBadgeRect(
        for size: NSSize,
        indicator: StatusIndicator
    ) -> NSRect {
        let badgeDiameter: CGFloat = indicator == .critical ? 8 : 7
        let outlineInset: CGFloat = 1
        return NSRect(
            x: max(outlineInset, size.width - badgeDiameter - outlineInset),
            y: max(outlineInset, size.height - badgeDiameter - outlineInset),
            width: badgeDiameter,
            height: badgeDiameter
        )
    }

    static func rasterizedIcon(
        _ source: NSImage,
        size: NSSize,
        appearance: NSAppearance
    ) -> NSImage {
        var renderedImage = source
        appearance.performAsCurrentDrawingAppearance {
            let cropped = imageByTrimmingTransparentPadding(source)
            renderedImage = fittedIcon(cropped, size: size)
        }
        return renderedImage
    }

    private static func fittedIcon(_ source: NSImage, size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
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
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )
    }
}
