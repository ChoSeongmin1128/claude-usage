import AppKit
import Foundation

enum MenuBarIconFactory {
    static func secondaryTextColor(highContrast: Bool) -> NSColor {
        highContrast ? NSColor.labelColor : NSColor.secondaryLabelColor.withAlphaComponent(0.95)
    }

    static func providerMenuBarIcon(for provider: AppProviderKind, size: NSSize) -> NSImage? {
        if let base = ProviderBrandIconResolver.baseImage(for: provider) {
            let cropped = imageByTrimmingTransparentPadding(base)
            return fittedIcon(cropped, size: size)
        }

        if let symbol = provider.fallbackSystemSymbolName,
           let fallback = NSImage(systemSymbolName: symbol, accessibilityDescription: provider.displayName) {
            return fittedIcon(fallback, size: size)
        }

        Logger.error("\(provider.displayName) 메뉴바 아이콘 생성 실패")
        return nil
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
