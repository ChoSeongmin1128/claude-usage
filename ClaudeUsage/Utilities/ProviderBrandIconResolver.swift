import AppKit
import SwiftUI

enum ProviderBrandIconKind: Sendable {
    case menuBar
    case popover
    case settings
}

enum ProviderBrandIconResolver {
    static func image(
        for provider: AppProviderKind,
        kind: ProviderBrandIconKind
    ) -> NSImage? {
        if let assetName = assetName(for: provider, kind: kind),
           let image = NSImage(named: assetName) {
            image.isTemplate = false
            return image
        }

        if kind == .menuBar {
            switch provider {
            case .claude:
                return MenuBarIconFactory.claudeMenuBarIcon(
                    size: NSSize(width: 18, height: 18),
                    tint: MenuBarIconFactory.claudeBrandIconTintColor()
                )
            case .codex:
                return MenuBarIconFactory.codexMenuBarIcon(size: NSSize(width: 18, height: 18))
            case .gemini:
                return MenuBarIconFactory.geminiMenuBarIcon(size: NSSize(width: 18, height: 18))
            case .antigravity:
                return MenuBarIconFactory.antigravityMenuBarIcon(size: NSSize(width: 18, height: 18))
            }
        }

        if let symbol = provider.fallbackSystemSymbolName,
           let image = NSImage(systemSymbolName: symbol, accessibilityDescription: provider.displayName) {
            return image
        }

        return nil
    }

    static func assetName(for provider: AppProviderKind, kind: ProviderBrandIconKind) -> String? {
        switch kind {
        case .menuBar:
            return provider.menuBarAssetName
        case .popover, .settings:
            return provider.brandAssetName
        }
    }
}

struct ProviderBrandIconView: View {
    let provider: AppProviderKind
    let kind: ProviderBrandIconKind
    let size: CGFloat

    var body: some View {
        Group {
            if let image = ProviderBrandIconResolver.image(for: provider, kind: kind) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: provider.fallbackSystemSymbolName ?? "questionmark.circle")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
    }
}
