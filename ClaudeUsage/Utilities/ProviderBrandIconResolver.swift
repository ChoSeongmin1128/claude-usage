import AppKit
import SwiftUI

enum ProviderBrandIconKind: Sendable {
    case menuBar
    case popover
    case settings
}

enum ProviderBrandIconResolver {
    private static var cachedImages: [String: NSImage] = [:]

    static func image(
        for provider: AppProviderKind,
        kind: ProviderBrandIconKind,
        appearance: NSAppearance? = nil
    ) -> NSImage? {
        if kind == .menuBar {
            guard let appearance else {
                Logger.error("\(provider.displayName) 메뉴바 아이콘 appearance가 지정되지 않았습니다.")
                return nil
            }
            return MenuBarIconFactory.providerMenuBarIcon(
                for: provider,
                size: NSSize(width: 18, height: 18),
                appearance: appearance
            )
        }

        if let assetName = assetName(for: provider, kind: kind),
           let image = baseImage(named: assetName) {
            image.isTemplate = false
            return image
        }

        if let symbol = provider.fallbackSystemSymbolName,
           let image = NSImage(systemSymbolName: symbol, accessibilityDescription: provider.displayName) {
            return image
        }

        return nil
    }

    static func assetName(for provider: AppProviderKind, kind: ProviderBrandIconKind) -> String? {
        switch kind {
        case .menuBar, .popover, .settings:
            return provider.brandAssetName
        }
    }

    static func baseImage(for provider: AppProviderKind) -> NSImage? {
        guard let assetName = provider.brandAssetName else { return nil }
        return baseImage(named: assetName)
    }

    private static func baseImage(named assetName: String) -> NSImage? {
        if let cached = cachedImages[assetName] {
            return cached.copy() as? NSImage ?? cached
        }
        guard let image = NSImage(named: assetName) else { return nil }
        image.isTemplate = false
        cachedImages[assetName] = image
        return image.copy() as? NSImage ?? image
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

struct ProviderSettingsSectionHeader: View {
    let provider: AppProviderKind
    let title: String

    var body: some View {
        HStack(spacing: 9) {
            ProviderBrandIconView(
                provider: provider,
                kind: .settings,
                size: 18
            )
            .frame(width: 20, height: 20)
            Text(title)
        }
        .font(.headline)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
