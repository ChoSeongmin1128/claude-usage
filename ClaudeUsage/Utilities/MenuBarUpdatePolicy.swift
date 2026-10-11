import AppKit

enum MenuBarAppearanceKey:
    String,
    Hashable,
    Sendable
{
    case light
    case dark
    case highContrastLight
    case highContrastDark

    init(
        _ appearance: NSAppearance,
        highContrast: Bool = NSWorkspace.shared
            .accessibilityDisplayShouldIncreaseContrast
    ) {
        let match = appearance.bestMatch(
            from: [
                .darkAqua,
                .vibrantDark,
                .aqua,
                .vibrantLight,
            ]
        )
        let isDark =
            match == .darkAqua
            || match == .vibrantDark
        if highContrast {
            self = isDark
                ? .highContrastDark
                : .highContrastLight
            return
        }
        switch match {
        case .darkAqua, .vibrantDark:
            self = .dark
        default:
            self = .light
        }
    }
}

struct MenuBarAppearanceChangeState: Equatable {
    private(set) var lastKey: MenuBarAppearanceKey?

    init(initialKey: MenuBarAppearanceKey? = nil) {
        lastKey = initialKey
    }

    mutating func shouldRequestUpdate(
        for key: MenuBarAppearanceKey
    ) -> Bool {
        guard key != lastKey else {
            return false
        }
        lastKey = key
        return true
    }
}

struct MenuBarUpdateRequestState: Equatable {
    private(set) var isScheduled = false
    private(set) var hasForcedRequest = false

    mutating func request(force: Bool) -> Bool {
        hasForcedRequest = hasForcedRequest || force
        guard !isScheduled else {
            return false
        }
        isScheduled = true
        return true
    }

    mutating func consume() -> Bool? {
        guard isScheduled else {
            return nil
        }
        let force = hasForcedRequest
        isScheduled = false
        hasForcedRequest = false
        return force
    }

    mutating func reset() {
        isScheduled = false
        hasForcedRequest = false
    }
}

struct MenuBarProviderRenderKey: Equatable, Sendable {
    /// 문구 밖에서 그림을 바꾸는 입력. 표시 설정과 presentation을 통째로 담아 입력이 늘어도 비교에서 빠지지 않게 한다.
    enum Visual: Equatable, Sendable {
        case plain(hasStyleIcon: Bool)
        /// Claude/Codex: 표시 설정 전체와 그 설정이 그리는 사용량 값
        case usage(ProviderMenuBarDisplayConfig, values: [Double])
        /// AGY: mapper가 확정한 표시 값 전체
        case antigravity(
            AntigravityMenuBarQuotaPresentation, design: MenuBarDesign, colorMode: MenuBarColorMode,
            arrangement: MenuBarQuotaArrangement?)
    }

    let kind: AppProviderKind
    let regularText: String?
    let condensedText: String?
    let tooltip: String
    let resetText: String?
    let showsProviderIcon: Bool
    let visual: Visual
    let statusIndicator: StatusIndicator?
    let systemStatusSummary: String?
    let accessibilityLabel: String?
    let accessibilityValue: String?
    let isStale: Bool
    var resetCreditBadge: String? = nil
}

struct MenuBarRenderKey: Equatable, Sendable {
    enum Layout: Equatable, Sendable {
        case placeholder
        case single(MenuBarProviderRenderKey)
        case multiple([MenuBarProviderRenderKey])
    }

    let appearance: MenuBarAppearanceKey
    let usesHighContrastText: Bool
    let layout: Layout
}

struct MenuBarContentApplicationState: Equatable {
    private(set) var lastKey: MenuBarRenderKey?

    mutating func shouldApply(
        _ key: MenuBarRenderKey,
        force: Bool
    ) -> Bool {
        guard force || key != lastKey else {
            return false
        }
        lastKey = key
        return true
    }

    mutating func reset() {
        lastKey = nil
    }
}
