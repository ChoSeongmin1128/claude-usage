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
        static let card: CGFloat = 14
        static let content: CGFloat = 12
        static let section: CGFloat = 16
        static let window: CGFloat = 20
        static let page: CGFloat = 24
    }

    enum Window {
        static let login = CGSize(width: 720, height: 600)
        static let settingsMinimum = CGSize(width: 800, height: 560)
        static let settingsIdeal = CGSize(width: 880, height: 660)
        static let setupWidth: CGFloat = 460
    }

    enum Radius {
        static let control: CGFloat = 6
        static let group: CGFloat = 8
        static let card: CGFloat = 10
        static let panel: CGFloat = 12
    }

    enum Typography {
        static let title = Font.title
        static let title2 = Font.title2
        static let title3 = Font.title3
        static let headline = Font.headline
        static let subheadline = Font.subheadline
        static let callout = Font.callout
        static let caption2 = Font.caption2
        static let body = Font.body
        static let caption = Font.caption
        static let metadata = Font.system(size: 10, weight: .medium)
        static let compactIdentity = Font.system(size: 9, weight: .medium)
        static let icon = Font.system(size: 12)
        static let smallIcon = Font.system(size: 11, weight: .semibold)
        static let noticeIcon = Font.system(size: 16, weight: .semibold)
        static let badge = Font.system(size: 10, weight: .semibold)
        static let setupIcon = Font.system(size: 36)
        static let failureIcon = Font.system(size: 44)
        static let successIcon = Font.system(size: 56)
        static let compactValue = Font.system(.caption, design: .monospaced).weight(.medium)
    }

    enum Surface {
        static let selection = Color.accentColor.opacity(0.18)
        static let group = Color(nsColor: .controlBackgroundColor).opacity(0.45)
        static let subtleGroup = Color(nsColor: .controlBackgroundColor).opacity(0.35)
        static let strongGroup = Color(nsColor: .controlBackgroundColor).opacity(0.55)
        static let disabledGroup = Color(nsColor: .controlBackgroundColor).opacity(0.3)
        static let track = Color.primary.opacity(0.12)
    }

    enum Motion {
        static let control = Animation.easeInOut(duration: 0.15)
        static let value = Animation.easeInOut(duration: 0.3)
    }

    enum Control {
        static let selectionStrokeWidth: CGFloat = 1.5
        static let compactHitSize: CGFloat = 22
        static let regularHitSize: CGFloat = 26
        static let externalBadgeFont = Font.system(size: 6, weight: .bold)
    }
}
