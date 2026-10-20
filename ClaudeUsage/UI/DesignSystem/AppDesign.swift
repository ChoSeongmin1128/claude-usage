import AppKit
import SwiftUI

/// Shared visual vocabulary. Provider facts, preferences and commands stay outside this module.
enum AppDesign {
    enum Space {
        static let tight: CGFloat = 2
        static let micro: CGFloat = 3
        static let heading: CGFloat = 5
        static let compact: CGFloat = 4
        static let control: CGFloat = 6
        static let row: CGFloat = 8
        static let label: CGFloat = 10
        static let card: CGFloat = 12
        static let content: CGFloat = 12
        static let section: CGFloat = 16
        static let window: CGFloat = 20
        static let page: CGFloat = 20
    }

    enum Hover {
        static let width: CGFloat = 296
        static let inset: CGFloat = 8
        static let rowGap: CGFloat = 2
        static let incidentGap: CGFloat = 6
        static let statusDot: CGFloat = 6
        static let columnWidth: CGFloat = 64
        static let border: CGFloat = 0.5
        static let scrollerInset: CGFloat = 12
    }

    enum Window {
        static let login = CGSize(width: 720, height: 600)
        static let settingsMinimum = CGSize(width: 800, height: 560)
        static let settingsIdeal = CGSize(width: 880, height: 660)
        static let setupWidth: CGFloat = 460
        static let presetNameWidth: CGFloat = 340
        static let presetQuotaWidth: CGFloat = 400
        static let whatsNew = CGSize(width: 400, height: 490)
        static let releaseNotes = CGSize(width: 720, height: 540)
    }

    enum Radius {
        static let control: CGFloat = 6
        static let group: CGFloat = 8
        static let card: CGFloat = 8
        static let panel: CGFloat = 12
    }

    enum FontSize {
        static let page: CGFloat = 22
        static let section: CGFloat = 15
        static let body: CGFloat = 13
        static let detail: CGFloat = 12
        static let metadata: CGFloat = 11
        static let number: CGFloat = 16
        static let compactNumber: CGFloat = 13
        static let usageNumber: CGFloat = 18
    }

    enum Typography {
        static let title = Font.system(size: FontSize.page, weight: .semibold)
        static let title2 = title
        static let title3 = Font.system(size: FontSize.section, weight: .semibold)
        static let headline = title3
        static let subheadline = Font.system(size: FontSize.body)
        static let callout = subheadline
        static let body = subheadline
        static let caption = Font.system(size: FontSize.detail)
        static let caption2 = Font.system(size: FontSize.metadata)
        static let metadata = caption2
        static let compactIdentity = caption2
        static let number = Font.system(size: FontSize.number, weight: .semibold)
        static let usageValue = Font.system(size: FontSize.usageNumber, weight: .bold)
        static let compactValue = Font.system(size: FontSize.compactNumber, weight: .semibold)
        static let compactMetricValue = Font.system(size: FontSize.compactNumber, weight: .bold)
        static let icon = Font.system(size: FontSize.detail)
        static let smallIcon = Font.system(size: FontSize.metadata, weight: .semibold)
        static let noticeIcon = Font.system(size: 16, weight: .semibold)
        static let badge = Font.system(size: FontSize.metadata, weight: .semibold)
        static let setupIcon = Font.system(size: 36)
        static let failureIcon = Font.system(size: 44)
        static let successIcon = Font.system(size: 56)

        static func metricFont(compact: Bool) -> NSFont {
            compact
                ? NSFont.systemFont(ofSize: FontSize.compactNumber, weight: .bold)
                : NSFont.systemFont(ofSize: FontSize.number, weight: .semibold)
        }
    }

    enum Surface {
        static let selection = Color.accentColor.opacity(0.18)
        static let group = Color(nsColor: .quaternaryLabelColor)
        static let subtleGroup = Color(nsColor: .controlBackgroundColor).opacity(0.35)
        static let strongGroup = Color(nsColor: .controlBackgroundColor).opacity(0.55)
        static let disabledGroup = Color(nsColor: .controlBackgroundColor).opacity(0.3)
        static let editable = Color(nsColor: .controlColor)
        static let boundary = Color.primary.opacity(0.6)
        static let separator = Color(nsColor: .separatorColor)
        static let track = Color.primary.opacity(0.12)
    }

    enum Text {
        // Keep small secondary text readable on both native content and editable surfaces.
        static let secondary = Color.primary.opacity(0.85)
        static let label = tier(light: 0.68, dark: 0.60)
        static let faint = tier(light: 0.56, dark: 0.48)

        private static func tier(light: CGFloat, dark: CGFloat) -> Color {
            Color(
                nsColor: NSColor(name: nil) { appearance in
                    let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    var resolved = NSColor.labelColor
                    appearance.performAsCurrentDrawingAppearance {
                        resolved = NSColor.labelColor.usingColorSpace(.deviceRGB) ?? .labelColor
                    }
                    return resolved.withAlphaComponent(isDark ? dark : light)
                })
        }

        static func status(_ color: Color, scheme: ColorScheme) -> Color {
            guard scheme == .light else { return color }
            let native = NSColor(color)
            return Color(nsColor: native.blended(withFraction: 0.5, of: .black) ?? native)
        }
    }

    enum MenuBar {
        static let singleProviderIconSize = NSSize(width: 18, height: 18)
        static let multipleProviderIconSize = NSSize(width: 14, height: 14)
        static func valueFont(compact: Bool) -> NSFont {
            NSFont.monospacedDigitSystemFont(ofSize: compact ? 12 : 13, weight: .medium)
        }
        static func resetFont(compact: Bool) -> NSFont {
            NSFont.systemFont(ofSize: compact ? 10 : 11, weight: .regular)
        }
    }

    enum Motion {
        static let popoverResizeDuration: TimeInterval = 0.25
        static let control = Animation.easeInOut(duration: 0.15)
        static let value = Animation.easeInOut(duration: 0.3)
    }

    enum Control {
        static let disclosureRowHeight: CGFloat = 32
        static let settingsRowHeight: CGFloat = 32
        static let updateActionWidth: CGFloat = 112
        static let settingsDetailRowHeight: CGFloat = 44
        static let presetTileMinimumWidth: CGFloat = 160
        static let menuBarPreviewHeight: CGFloat = 22
        static let menuBarArrangementPreviewHeight: CGFloat = 30
        static let presetTileHeight: CGFloat = 80
        static let presetSelectionStroke: CGFloat = 2
        static let selectionStrokeWidth: CGFloat = 1.5
        static let compactHitSize: CGFloat = 22
        static let regularHitSize: CGFloat = 28
        static let externalBadgeFont = Font.system(size: 6, weight: .bold)
    }
}
