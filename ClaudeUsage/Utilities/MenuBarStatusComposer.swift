//
//  MenuBarStatusComposer.swift
//  ClaudeUsage
//
//  메뉴바 표시 계산과 합성 렌더링을 AppDelegate 밖으로 분리
//

import AppKit
import Foundation

struct MenuBarRenderedContent {
    let image: NSImage
    let tooltip: String
    let accessibilityLabel: String?
    let accessibilityValue: String?

    init(
        image: NSImage,
        tooltip: String,
        accessibilityLabel: String? = nil,
        accessibilityValue: String? = nil
    ) {
        self.image = image
        self.tooltip = tooltip
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValue = accessibilityValue
    }

    func applyAccessibility(to button: NSStatusBarButton) {
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityValue(accessibilityValue)
    }
}

private struct MenuBarElement {
    let image: NSImage?
    let text: String?
    let attributes: [NSAttributedString.Key: Any]?
    let needsShadow: Bool

    static func image(_ image: NSImage) -> MenuBarElement {
        MenuBarElement(image: image, text: nil, attributes: nil, needsShadow: false)
    }

    static func text(_ text: String, attributes: [NSAttributedString.Key: Any], shadow: Bool = false) -> MenuBarElement {
        MenuBarElement(image: nil, text: text, attributes: attributes, needsShadow: shadow)
    }
}

private struct MenuBarProviderStatus {
    let text: String
    let color: NSColor
    let tooltip: String
}

struct MenuBarProviderSnapshot {
    let kind: AppProviderKind
    let regularText: String?
    let condensedText: String?
    let color: NSColor
    let tooltip: String
    let icon: NSImage?
    let styleIcon: NSImage?
    let resetText: String?
    let systemStatus: ProviderSystemStatus?
    let accessibilityLabel: String?
    let accessibilityValue: String?
    let isStale: Bool

    var text: String {
        regularText ?? ""
    }

    init(
        kind: AppProviderKind,
        text: String,
        color: NSColor,
        tooltip: String,
        icon: NSImage?,
        styleIcon: NSImage?,
        resetText: String?,
        systemStatus: ProviderSystemStatus?
    ) {
        self.init(
            kind: kind,
            regularText: text,
            condensedText: text,
            color: color,
            tooltip: tooltip,
            icon: icon,
            styleIcon: styleIcon,
            resetText: resetText,
            systemStatus: systemStatus,
            accessibilityLabel: nil,
            accessibilityValue: nil,
            isStale: false
        )
    }

    init(
        kind: AppProviderKind,
        regularText: String?,
        condensedText: String?,
        color: NSColor,
        tooltip: String,
        icon: NSImage?,
        styleIcon: NSImage?,
        resetText: String?,
        systemStatus: ProviderSystemStatus?,
        accessibilityLabel: String?,
        accessibilityValue: String?,
        isStale: Bool = false
    ) {
        self.kind = kind
        self.regularText = regularText
        self.condensedText = condensedText
        self.color = color
        self.tooltip = tooltip
        self.icon = icon
        self.styleIcon = styleIcon
        self.resetText = resetText
        self.systemStatus = systemStatus
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValue = accessibilityValue
        self.isStale = isStale
    }
}

enum MenuBarStatusComposer {
    private static let menuBarHeight: CGFloat = 22
    private static let elementSpacing: CGFloat = 4

    static func placeholder(secondaryColor: NSColor) -> MenuBarRenderedContent {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: secondaryColor,
        ]
        let text = "⋯"
        let size = (text as NSString).size(withAttributes: attributes)
        let image = NSImage(size: NSSize(width: max(14, size.width), height: menuBarHeight), flipped: false) { _ in
            (text as NSString).draw(at: NSPoint(x: 0, y: (menuBarHeight - size.height) / 2), withAttributes: attributes)
            return true
        }
        image.isTemplate = false
        return MenuBarRenderedContent(image: image, tooltip: "ClaudeUsage 설정")
    }

    private static func statusDot(color: NSColor) -> MenuBarElement {
        .text("•", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: color,
        ])
    }

    /// 메뉴바 색상 모드(설정)를 반영한 게이지 색.
    /// HIG 권장인 모노크롬과 현행 임계값 색상 사이에서 사용자가 고른 정책을 적용한다.
    private static func gaugeColor(for percentage: Double, config: ProviderMenuBarDisplayConfig) -> NSColor {
        switch config.colorMode {
        case .always:
            return ColorProvider.nsStatusColor(for: percentage)
        case .warningOnly:
            return percentage >= MenuBarColorMode.warningThreshold
                ? ColorProvider.nsStatusColor(for: percentage)
                : .labelColor
        case .monochrome:
            return .labelColor
        }
    }

    static func claudeOnlyContent(
        config: ProviderMenuBarDisplayConfig,
        usage: ClaudeUsageResponse?,
        error: APIError?,
        hasAuthError: Bool,
        hasCredential: Bool,
        secondaryColor: NSColor,
        icon: NSImage?,
        systemStatus: ProviderSystemStatus? = nil
    ) -> MenuBarRenderedContent {
        if !hasCredential {
            return iconWithStatusContent(
                icon: icon,
                label: "로그인 필요",
                labelColor: secondaryColor,
                tooltip: "클릭하여 로그인"
            )
        }

        if let error, usage == nil {
            return iconWithStatusContent(
                icon: icon,
                label: hasAuthError ? "인증 필요" : "⚠",
                labelColor: hasAuthError ? .systemOrange : secondaryColor,
                tooltip: error.errorDescription ?? "알 수 없는 에러"
            )
        }

        guard let usage else {
            let fallbackIcon = icon ?? composeElements(
                [MenuBarElement.text("…", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: secondaryColor])]
            )
            return MenuBarRenderedContent(image: fallbackIcon, tooltip: "데이터 로딩 중")
        }

        let fiveHour = usage.fiveHourPercentage
        let weekly = usage.sevenDay?.utilization ?? 0
        let fiveHourColor = gaugeColor(for: fiveHour, config: config)
        let weeklyColor = gaugeColor(for: weekly, config: config)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let smallFont = NSFont.systemFont(ofSize: 11)
        var elements: [MenuBarElement] = []

        if config.showIcon, let icon {
            elements.append(.image(icon))
        }

        switch config.percentageDisplay {
        case .none:
            break
        case .fiveHour:
            elements.append(.text(displayText(for: fiveHour, showRemaining: showsRemaining(config: config)), attributes: [.font: font, .foregroundColor: fiveHourColor], shadow: true))
        case .weekly:
            elements.append(.text(displayText(for: weekly, showRemaining: showsRemaining(config: config)), attributes: [.font: font, .foregroundColor: weeklyColor], shadow: true))
        case .dual:
            elements.append(.image(segmentedPercentageImage(
                first: displayText(for: fiveHour, showRemaining: showsRemaining(config: config)),
                firstColor: fiveHourColor,
                second: displayText(for: weekly, showRemaining: showsRemaining(config: config)),
                secondColor: weeklyColor,
                font: font,
                separatorColor: secondaryColor
            )))
        }

        if let styleIcon = styleIcon(usage: usage, config: config) {
            elements.append(.image(styleIcon))
        }

        if hasAuthError {
            elements.append(.text("⚠", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.systemOrange]))
        }

        if let resetText = resetText(usage: usage, config: config) {
            elements.append(.text(resetText, attributes: [.font: smallFont, .foregroundColor: secondaryColor]))
        }

        if elements.isEmpty {
            elements.append(statusDot(color: secondaryColor))
        }

        let authWarning = hasAuthError ? "\n⚠️ Claude 인증 상태를 확인해주세요" : ""
        let tooltip = "현재 \(Int(fiveHour))% · 주간 \(Int(weekly))%\(authWarning)"
            + staleNote(error: error, hasAuthError: hasAuthError)
        return MenuBarRenderedContent(image: composeElements(elements), tooltip: tooltip)
    }

    static func claudeSnapshot(
        config: ProviderMenuBarDisplayConfig,
        usage: ClaudeUsageResponse?,
        error: APIError?,
        hasAuthError: Bool,
        hasCredential: Bool,
        secondaryColor: NSColor,
        icon: NSImage?,
        systemStatus: ProviderSystemStatus? = nil
    ) -> MenuBarProviderSnapshot {
        let status = claudeStatus(
            config: config,
            usage: usage,
            error: error,
            hasAuthError: hasAuthError,
            hasCredential: hasCredential,
            secondaryColor: secondaryColor
        )
        return MenuBarProviderSnapshot(
            kind: .claude,
            text: status.text,
            color: status.color,
            tooltip: status.tooltip,
            icon: config.showIcon ? icon : nil,
            styleIcon: styleIcon(usage: usage, config: config),
            resetText: resetText(usage: usage, config: config),
            systemStatus: systemStatus
        )
    }

    static func codexOnlyContent(
        config: ProviderMenuBarDisplayConfig,
        usage: CodexUsageResponse?,
        error: APIError?,
        hasAuthError: Bool,
        isAuthenticated: Bool,
        secondaryColor: NSColor,
        icon: NSImage?
    ) -> MenuBarRenderedContent {
        if !isAuthenticated {
            return iconWithStatusContent(
                icon: icon,
                label: "로그인",
                labelColor: .systemOrange,
                tooltip: "로그인 필요"
            )
        }

        guard let usage else {
            if let error {
                return iconWithStatusContent(
                    icon: icon,
                    label: hasAuthError ? "Codex 인증 필요" : "Codex 오류",
                    labelColor: .systemOrange,
                    tooltip: error.errorDescription ?? "Codex 조회 오류"
                )
            }
            return iconWithStatusContent(
                icon: icon,
                label: "…",
                labelColor: secondaryColor,
                tooltip: "로딩 중"
            )
        }

        let hasPrimary = usage.hasSessionWindow
        let primary = usage.sessionPercentage
        let weekly = usage.weeklyPercentage
        let primaryColor = gaugeColor(for: usage.gaugePercentage, config: config)
        let weeklyColor = gaugeColor(for: weekly, config: config)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let smallFont = NSFont.systemFont(ofSize: 11)
        var elements: [MenuBarElement] = []

        if config.showIcon, let icon {
            elements.append(.image(icon))
        }

        switch config.percentageDisplay {
        case .none:
            break
        case .fiveHour:
            // 세션 창이 없으면 주간 게이지로 대체 표시
            elements.append(.text(displayText(for: usage.gaugePercentage, showRemaining: showsRemaining(config: config)), attributes: [.font: font, .foregroundColor: primaryColor], shadow: true))
        case .weekly:
            elements.append(.text(displayText(for: weekly, showRemaining: showsRemaining(config: config)), attributes: [.font: font, .foregroundColor: weeklyColor], shadow: true))
        case .dual:
            if hasPrimary {
                elements.append(.image(segmentedPercentageImage(
                    first: displayText(for: primary, showRemaining: showsRemaining(config: config)),
                    firstColor: primaryColor,
                    second: displayText(for: weekly, showRemaining: showsRemaining(config: config)),
                    secondColor: weeklyColor,
                    font: font,
                    separatorColor: secondaryColor
                )))
            } else {
                // 주간 전용 응답 — 듀얼 대신 주간 단일 표시
                elements.append(.text(displayText(for: weekly, showRemaining: showsRemaining(config: config)), attributes: [.font: font, .foregroundColor: weeklyColor], shadow: true))
            }
        }

        if let styleIcon = styleIcon(usage: usage, config: config) {
            elements.append(.image(styleIcon))
        }

        if let resetText = resetText(usage: usage, config: config) {
            elements.append(.text(resetText, attributes: [.font: smallFont, .foregroundColor: secondaryColor]))
        }

        if elements.isEmpty {
            elements.append(statusDot(color: secondaryColor))
        }

        return MenuBarRenderedContent(
            image: composeElements(elements),
            tooltip: (hasPrimary
                ? "현재 \(Int(primary))% · 주간 \(Int(weekly))%"
                : "주간 \(Int(weekly))%")
                + staleNote(error: error, hasAuthError: hasAuthError)
        )
    }

    static func codexSnapshot(
        config: ProviderMenuBarDisplayConfig,
        usage: CodexUsageResponse?,
        error: APIError?,
        hasAuthError: Bool,
        isAuthenticated: Bool,
        secondaryColor: NSColor,
        icon: NSImage?,
        systemStatus: ProviderSystemStatus? = nil
    ) -> MenuBarProviderSnapshot {
        let status = codexStatus(
            config: config,
            usage: usage,
            error: error,
            hasAuthError: hasAuthError,
            isAuthenticated: isAuthenticated,
            secondaryColor: secondaryColor
        )
        return MenuBarProviderSnapshot(
            kind: .codex,
            text: status.text,
            color: status.color,
            tooltip: status.tooltip,
            icon: config.showIcon ? icon : nil,
            styleIcon: styleIcon(usage: usage, config: config),
            resetText: resetText(usage: usage, config: config),
            systemStatus: systemStatus
        )
    }

    /// Antigravity v2 메뉴바 경로.
    ///
    /// 선택 lane, 수치, reset 문구, 색상 의미와 접근성 문구는 mapper가 만든
    /// presentation에 이미 확정되어 있다. 이 경로는 legacy usage/config 또는
    /// process environment를 다시 해석하지 않고, 그 값을 AppKit 표현으로만 바꾼다.
    static func antigravitySnapshot(
        presentation: AntigravityMenuBarQuotaPresentation,
        context: AntigravityQuotaPresentationContext = .init(),
        icon: NSImage?
    ) -> MenuBarProviderSnapshot? {
        guard presentation.isVisible else {
            return nil
        }

        let isStale: Bool
        switch context.phase {
        case .stale:
            isStale = true
        case .current, .refreshing:
            isStale = false
        }
        let color = antigravityColor(for: presentation.tone)
        return MenuBarProviderSnapshot(
            kind: .antigravity,
            regularText: presentation.regularText,
            condensedText: presentation.condensedText,
            color: color,
            tooltip: staleAnnotatedTooltip(
                presentation.tooltip,
                isStale: isStale
            ),
            icon: presentation.showsProviderIcon ? icon : nil,
            styleIcon: antigravityStyleIcon(
                presentation: presentation,
                color: color
            ),
            resetText: nil,
            systemStatus: nil,
            accessibilityLabel: presentation.accessibilityLabel,
            accessibilityValue: staleAnnotatedAccessibilityValue(
                presentation.accessibilityValue,
                isStale: isStale
            ),
            isStale: isStale
        )
    }

    static func combinedContent(
        claudeConfig: ProviderMenuBarDisplayConfig,
        claudeUsage: ClaudeUsageResponse?,
        claudeError: APIError?,
        hasClaudeAuthError: Bool,
        hasClaudeCredential: Bool,
        claudeIcon: NSImage?,
        codexConfig: ProviderMenuBarDisplayConfig,
        codexUsage: CodexUsageResponse?,
        codexError: APIError?,
        hasCodexAuthError: Bool,
        isCodexAuthenticated: Bool,
        codexIcon: NSImage?,
        secondaryColor: NSColor
    ) -> MenuBarRenderedContent {
        let separatorFont = NSFont.systemFont(ofSize: 11, weight: .regular)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let resetFont = NSFont.systemFont(ofSize: 10, weight: .regular)
        let claude = claudeStatus(
            config: claudeConfig,
            usage: claudeUsage,
            error: claudeError,
            hasAuthError: hasClaudeAuthError,
            hasCredential: hasClaudeCredential,
            secondaryColor: secondaryColor
        )
        let codex = codexStatus(
            config: codexConfig,
            usage: codexUsage,
            error: codexError,
            hasAuthError: hasCodexAuthError,
            isAuthenticated: isCodexAuthenticated,
            secondaryColor: secondaryColor
        )

        var leftElements: [MenuBarElement] = []
        var rightElements: [MenuBarElement] = []

        if claudeConfig.showIcon, let claudeIcon {
            leftElements.append(.image(claudeIcon))
        }
        if !claude.text.isEmpty {
            leftElements.append(.text(claude.text, attributes: [.font: valueFont, .foregroundColor: claude.color]))
        }
        if let styleIcon = styleIcon(usage: claudeUsage, config: claudeConfig) {
            leftElements.append(.image(styleIcon))
        }
        if let resetText = resetText(usage: claudeUsage, config: claudeConfig) {
            leftElements.append(.text(resetText, attributes: [.font: resetFont, .foregroundColor: secondaryColor]))
        }

        if codexConfig.showIcon, let codexIcon {
            rightElements.append(.image(codexIcon))
        }
        if !codex.text.isEmpty {
            rightElements.append(.text(codex.text, attributes: [.font: valueFont, .foregroundColor: codex.color]))
        }
        if let styleIcon = styleIcon(usage: codexUsage, config: codexConfig) {
            rightElements.append(.image(styleIcon))
        }
        if let resetText = resetText(usage: codexUsage, config: codexConfig) {
            rightElements.append(.text(resetText, attributes: [.font: resetFont, .foregroundColor: secondaryColor]))
        }

        if leftElements.isEmpty {
            leftElements.append(statusDot(color: claude.color))
        }
        if rightElements.isEmpty {
            rightElements.append(statusDot(color: codex.color))
        }

        var elements = leftElements
        if !leftElements.isEmpty && !rightElements.isEmpty {
            elements.append(.text("·", attributes: [.font: separatorFont, .foregroundColor: secondaryColor]))
        }
        elements.append(contentsOf: rightElements)

        return MenuBarRenderedContent(
            image: composeElements(elements),
            tooltip: [
                tooltipBlock(name: "Claude", tooltip: claude.tooltip),
                tooltipBlock(name: "Codex", tooltip: codex.tooltip),
            ].joined(separator: "\n")
        )
    }

    static func singleProviderContent(
        snapshot: MenuBarProviderSnapshot,
        secondaryColor: NSColor,
        appearance: NSAppearance
    ) -> MenuBarRenderedContent {
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let resetFont = NSFont.systemFont(ofSize: 11)
        var elements = renderElements(
            for: snapshot,
            text: snapshot.regularText,
            valueFont: valueFont,
            resetFont: resetFont,
            secondaryColor: secondaryColor,
            appearance: appearance
        )
        if elements.isEmpty {
            elements.append(statusDot(color: secondaryColor))
        }
        return MenuBarRenderedContent(
            image: composeElements(elements),
            tooltip: providerTooltip(for: snapshot),
            accessibilityLabel: snapshot.accessibilityLabel,
            accessibilityValue: snapshot.accessibilityValue
        )
    }

    static func multipleProviderContent(
        snapshots: [MenuBarProviderSnapshot],
        secondaryColor: NSColor,
        appearance: NSAppearance
    ) -> MenuBarRenderedContent {
        let separatorFont = NSFont.systemFont(ofSize: 11, weight: .regular)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let resetFont = NSFont.systemFont(ofSize: 10, weight: .regular)
        let resolvedSnapshots = snapshots.filter { $0.kind.isRuntimeProvider }
        let elements = resolvedSnapshots.enumerated().flatMap { index, snapshot -> [MenuBarElement] in
            var rendered = renderElements(
                for: snapshot,
                text: snapshot.condensedText,
                valueFont: valueFont,
                resetFont: resetFont,
                secondaryColor: secondaryColor,
                appearance: appearance
            )
            if rendered.isEmpty {
                rendered = [statusDot(color: snapshot.color)]
            }
            if index < resolvedSnapshots.count - 1 {
                rendered.append(.text("·", attributes: [.font: separatorFont, .foregroundColor: secondaryColor]))
            }
            return rendered
        }
        let tooltip = resolvedSnapshots
            .map(providerTooltip(for:))
            .joined(separator: "\n")
        let accessibilityLabel = joinedAccessibilityText(
            resolvedSnapshots.compactMap(\.accessibilityLabel)
        )
        let accessibilityValue = joinedAccessibilityText(
            resolvedSnapshots.compactMap(\.accessibilityValue)
        )
        return MenuBarRenderedContent(
            image: composeElements(elements.isEmpty ? [statusDot(color: secondaryColor)] : elements),
            tooltip: tooltip,
            accessibilityLabel: accessibilityLabel,
            accessibilityValue: accessibilityValue
        )
    }

    private static func renderElements(
        for snapshot: MenuBarProviderSnapshot,
        text: String?,
        valueFont: NSFont,
        resetFont: NSFont,
        secondaryColor: NSColor,
        appearance: NSAppearance,
        includeResetText: Bool = true
    ) -> [MenuBarElement] {
        var elements: [MenuBarElement] = []
        if let icon = snapshot.icon {
            let renderedIcon = statusBadgedIcon(icon, for: snapshot, appearance: appearance)
            elements.append(.image(renderedIcon))
        }
        if let text, !text.isEmpty {
            elements.append(.text(text, attributes: [.font: valueFont, .foregroundColor: snapshot.color]))
        }
        if let styleIcon = snapshot.styleIcon {
            elements.append(.image(styleIcon))
        }
        if snapshot.isStale {
            elements.append(staleDataIndicator())
        }
        if includeResetText, let resetText = snapshot.resetText {
            elements.append(.text(resetText, attributes: [.font: resetFont, .foregroundColor: secondaryColor]))
        }
        if snapshot.icon == nil, let status = snapshot.systemStatus, status.hasIssue {
            elements.append(statusDot(color: statusBadgeColor(for: status.effectiveIndicator)))
        }
        return elements
    }

    private static func staleDataIndicator() -> MenuBarElement {
        .text(
            "◷",
            attributes: [
                .font: NSFont.systemFont(
                    ofSize: 10,
                    weight: .semibold
                ),
                .foregroundColor: NSColor.systemOrange,
            ]
        )
    }

    nonisolated private static func staleAnnotatedTooltip(
        _ tooltip: String,
        isStale: Bool
    ) -> String {
        guard isStale,
              !tooltip.contains("이전 데이터")
        else {
            return tooltip
        }
        return "\(tooltip)\n상태: 이전 데이터"
    }

    nonisolated private static func staleAnnotatedAccessibilityValue(
        _ value: String,
        isStale: Bool
    ) -> String {
        guard isStale,
              !value.contains("이전 데이터")
        else {
            return value
        }
        return value.isEmpty
            ? "이전 데이터"
            : "\(value), 이전 데이터"
    }

    nonisolated private static func joinedAccessibilityText(
        _ values: [String]
    ) -> String? {
        guard !values.isEmpty else {
            return nil
        }
        return values.joined(separator: ", ")
    }

    nonisolated private static func providerTooltip(for snapshot: MenuBarProviderSnapshot) -> String {
        let base = tooltipBlock(name: snapshot.kind.displayName, tooltip: snapshot.tooltip)
        guard let status = snapshot.systemStatus, status.hasIssue else {
            return base
        }
        return "\(base)\n   ⚠ \(snapshot.kind.displayName) 상태: \(status.menuBarSummary)"
    }

    private static func statusBadgedIcon(
        _ icon: NSImage,
        for snapshot: MenuBarProviderSnapshot,
        appearance: NSAppearance
    ) -> NSImage {
        guard let status = snapshot.systemStatus, status.hasIssue else {
            return icon
        }
        return MenuBarIconFactory.badgedIcon(
            icon,
            indicator: status.effectiveIndicator,
            appearance: appearance
        )
    }

    private static func statusBadgeColor(for indicator: StatusIndicator) -> NSColor {
        switch indicator {
        case .none:
            return .clear
        case .minor:
            return .systemOrange
        case .major, .critical:
            return .systemRed
        }
    }

    /// 마지막 성공 데이터를 표시 중인데 최근 갱신이 실패한 경우 tooltip에 붙는 안내.
    /// 인증 실패는 별도 경고 배지로 처리하므로 여기서는 제외한다.
    /// 경고류는 항상 "⚠ " 접두 + 별도 줄 — tooltip 줄넘김 규칙(1줄 = 수치 요약, 이후 줄 = 경고)의 일부.
    private static func staleNote(error: APIError?, hasAuthError: Bool) -> String {
        guard let error, !hasAuthError else { return "" }
        let label: String
        if error.isTemporaryFailure {
            label = "일시 오류"
        } else if error.isPermissionDenied {
            label = "권한 없음"
        } else {
            label = "조회 실패"
        }
        return "\n⚠ 갱신 지연(\(label)) — 마지막 성공 데이터 표시 중"
    }

    /// 멀티 프로바이더 tooltip 블록: 첫 줄은 "이름: 수치 요약", 경고 줄들은 들여쓰기로 소속을 표시.
    /// 예)
    ///   Claude: 현재 85% · 주간 52%
    ///      ⚠ 갱신 지연(일시 오류) — 마지막 성공 데이터 표시 중
    ///   Codex: 주간 12%
    nonisolated private static func tooltipBlock(name: String, tooltip: String) -> String {
        let lines = tooltip.components(separatedBy: "\n")
        guard let first = lines.first, !first.isEmpty else { return name }
        var block = "\(name): \(first)"
        for line in lines.dropFirst() where !line.isEmpty {
            block += "\n   \(line)"
        }
        return block
    }

    private static func claudeStatus(
        config: ProviderMenuBarDisplayConfig,
        usage: ClaudeUsageResponse?,
        error: APIError?,
        hasAuthError: Bool,
        hasCredential: Bool,
        secondaryColor: NSColor
    ) -> MenuBarProviderStatus {
        if !hasCredential {
            return MenuBarProviderStatus(text: "로그인", color: .systemOrange, tooltip: "로그인 필요")
        }
        if let error, usage == nil {
            return MenuBarProviderStatus(
                text: hasAuthError ? "인증" : "오류",
                color: .systemOrange,
                tooltip: error.errorDescription ?? "조회 오류"
            )
        }
        guard let usage else {
            return MenuBarProviderStatus(text: "…", color: secondaryColor, tooltip: "로딩 중")
        }

        let fiveHour = usage.fiveHourPercentage
        let weekly = usage.sevenDay?.utilization ?? 0
        let displayFiveHour = displayValue(for: fiveHour, showRemaining: showsRemaining(config: config))
        let displayWeekly = displayValue(for: weekly, showRemaining: showsRemaining(config: config))
        let text: String = {
            switch config.percentageDisplay {
            case .none:
                return ""
            case .fiveHour:
                return String(format: "%.0f%%", displayFiveHour)
            case .weekly:
                return String(format: "%.0f%%", displayWeekly)
            case .dual:
                return String(format: "%.0f%%·%.0f%%", displayFiveHour, displayWeekly)
            }
        }()

        return MenuBarProviderStatus(
            text: text,
            color: gaugeColor(for: fiveHour, config: config),
            tooltip: "현재 \(Int(fiveHour.rounded()))% · 주간 \(Int(weekly.rounded()))%"
                + staleNote(error: error, hasAuthError: hasAuthError)
        )
    }

    private static func codexStatus(
        config: ProviderMenuBarDisplayConfig,
        usage: CodexUsageResponse?,
        error: APIError?,
        hasAuthError: Bool,
        isAuthenticated: Bool,
        secondaryColor: NSColor
    ) -> MenuBarProviderStatus {
        if !isAuthenticated {
            return MenuBarProviderStatus(text: "로그인", color: .systemOrange, tooltip: "로그인 필요")
        }
        guard let usage else {
            if let error {
                return MenuBarProviderStatus(
                    text: hasAuthError ? "인증" : "오류",
                    color: .systemOrange,
                    tooltip: error.errorDescription ?? "조회 오류"
                )
            }
            return MenuBarProviderStatus(text: "…", color: secondaryColor, tooltip: "로딩 중")
        }

        let hasPrimary = usage.hasSessionWindow
        let primary = usage.sessionPercentage
        let weekly = usage.weeklyPercentage
        let displayPrimary = displayValue(for: hasPrimary ? primary : weekly, showRemaining: showsRemaining(config: config))
        let displayWeekly = displayValue(for: weekly, showRemaining: showsRemaining(config: config))
        let text: String = {
            switch config.percentageDisplay {
            case .none:
                return ""
            case .fiveHour:
                return String(format: "%.0f%%", displayPrimary)
            case .weekly:
                return String(format: "%.0f%%", displayWeekly)
            case .dual:
                // 세션 창이 없는 주간 전용 응답이면 주간 하나만 표시
                guard hasPrimary else { return String(format: "%.0f%%", displayWeekly) }
                return String(format: "%.0f%%·%.0f%%", displayPrimary, displayWeekly)
            }
        }()

        return MenuBarProviderStatus(
            text: text,
            color: gaugeColor(for: usage.gaugePercentage, config: config),
            tooltip: (hasPrimary
                ? "현재 \(Int(primary.rounded()))% · 주간 \(Int(weekly.rounded()))%"
                : "주간 \(Int(weekly.rounded()))%")
                + staleNote(error: error, hasAuthError: hasAuthError)
        )
    }

    private static func resetText(usage: ClaudeUsageResponse?, config: ProviderMenuBarDisplayConfig) -> String? {
        guard let usage else { return nil }
        switch config.resetTimeDisplay {
        case .none:
            return nil
        case .fiveHour:
            guard let resetAt = usage.fiveHour.resetsAt else { return nil }
            return TimeFormatter.formatResetTime(from: resetAt, style: config.timeFormat, includeDateIfNotToday: false)
        case .weekly:
            guard let resetAt = usage.sevenDay?.resetsAt else { return nil }
            return TimeFormatter.formatResetTimeWeekly(from: resetAt, style: config.timeFormat, includeDateIfNotToday: false)
        case .dual:
            let first = usage.fiveHour.resetsAt.flatMap {
                TimeFormatter.formatResetTime(from: $0, style: config.timeFormat, includeDateIfNotToday: false)
            }
            let second = usage.sevenDay?.resetsAt.flatMap {
                TimeFormatter.formatResetTimeWeekly(from: $0, style: config.timeFormat, includeDateIfNotToday: false)
            }
            if let first, let second { return "\(first) · \(second)" }
            return first ?? second
        }
    }

    private static func resetText(usage: CodexUsageResponse?, config: ProviderMenuBarDisplayConfig) -> String? {
        guard let usage else { return nil }
        switch config.resetTimeDisplay {
        case .none:
            return nil
        case .fiveHour:
            // 세션 창이 있으면 세션 포맷, 없으면(주간 전용 개편) 주간 창을 주간 포맷으로 대체.
            // 포맷은 표시 슬롯이 아니라 실제 창 성격을 따라간다 — 주간 창에 분 단위까지 붙는 것 방지.
            if let sessionReset = usage.sessionWindow?.resetAtISO {
                return TimeFormatter.formatResetTime(from: sessionReset, style: config.timeFormat, includeDateIfNotToday: false)
            }
            guard let weeklyReset = usage.weeklyWindow?.resetAtISO else { return nil }
            return TimeFormatter.formatResetTimeWeekly(from: weeklyReset, style: config.timeFormat, includeDateIfNotToday: false)
        case .weekly:
            guard let resetAt = usage.weeklyWindow?.resetAtISO else { return nil }
            return TimeFormatter.formatResetTimeWeekly(from: resetAt, style: config.timeFormat, includeDateIfNotToday: false)
        case .dual:
            let first = usage.sessionWindow?.resetAtISO.flatMap {
                TimeFormatter.formatResetTime(from: $0, style: config.timeFormat, includeDateIfNotToday: false)
            }
            let second = usage.weeklyWindow?.resetAtISO.flatMap {
                TimeFormatter.formatResetTimeWeekly(from: $0, style: config.timeFormat, includeDateIfNotToday: false)
            }
            if let first, let second { return "\(first) · \(second)" }
            return first ?? second
        }
    }

    private static func styleIcon(usage: ClaudeUsageResponse?, config: ProviderMenuBarDisplayConfig) -> NSImage? {
        guard let usage else { return nil }
        let primary = usage.fiveHourPercentage
        let secondary = usage.sevenDay?.utilization ?? 0
        return styleIcon(
            primary: primary,
            secondary: secondary,
            config: config,
            metric: resolvedMetric(primary: primary, secondary: secondary, config: config)
        )
    }

    private static func styleIcon(usage: CodexUsageResponse?, config: ProviderMenuBarDisplayConfig) -> NSImage? {
        guard let usage else { return nil }
        // 세션 창이 없으면 주간 게이지를 primary 자리에 사용 (0% 오인 방지)
        let primary = usage.gaugePercentage
        let secondary = usage.weeklyPercentage
        if !usage.hasSessionWindow {
            let isRemainingMode = config.circularDisplayMode == .remaining
            let value = isRemainingMode ? (100.0 - secondary) : secondary
            let color = gaugeColor(for: secondary, config: config)
            switch config.style {
            case .none:
                return nil
            case .batteryBar, .dualBattery, .sideBySideBattery:
                return MenuBarIconRenderer.batteryIcon(
                    percentage: value,
                    color: color,
                    showPercent: config.showBatteryPercent
                )
            case .circular, .concentricRings:
                return MenuBarIconRenderer.circularRingIcon(percentage: value, color: color)
            }
        }
        return styleIcon(
            primary: primary,
            secondary: secondary,
            config: config,
            metric: resolvedMetric(primary: primary, secondary: secondary, config: config)
        )
    }

    private static func antigravityStyleIcon(
        presentation: AntigravityMenuBarQuotaPresentation,
        color: NSColor
    ) -> NSImage? {
        guard let percentage = presentation.gaugePercentage else {
            return nil
        }

        switch presentation.style {
        case .none:
            return nil
        case .batteryBar:
            return MenuBarIconRenderer.batteryIcon(
                percentage: percentage,
                color: color,
                showPercent: presentation.showsGaugePercentage
            )
        case .circular:
            return MenuBarIconRenderer.circularRingIcon(
                percentage: percentage,
                color: color
            )
        }
    }

    private static func antigravityColor(
        for tone: AntigravityQuotaRiskTone
    ) -> NSColor {
        switch tone {
        case .neutral:
            return .secondaryLabelColor
        case .healthy:
            return .systemGreen
        case .attention:
            return .systemYellow
        case .warning:
            return .systemOrange
        case .critical:
            return .systemRed
        }
    }

    private static func styleIcon(
        primary: Double,
        secondary: Double,
        config: ProviderMenuBarDisplayConfig,
        metric: (percentage: Double, color: NSColor)
    ) -> NSImage? {
        let primaryColor = gaugeColor(for: primary, config: config)
        let secondaryColor = gaugeColor(for: secondary, config: config)
        let isRemainingMode = config.circularDisplayMode == .remaining
        let circularValue = isRemainingMode ? (100.0 - metric.percentage) : metric.percentage
        let outer = isRemainingMode ? (100.0 - primary) : primary
        let inner = isRemainingMode ? (100.0 - secondary) : secondary

        switch config.style {
        case .none:
            return nil
        case .batteryBar:
            return MenuBarIconRenderer.batteryIcon(
                percentage: circularValue,
                color: metric.color,
                showPercent: config.showBatteryPercent
            )
        case .circular:
            return MenuBarIconRenderer.circularRingIcon(percentage: circularValue, color: metric.color)
        case .concentricRings:
            return MenuBarIconRenderer.concentricRingsIcon(
                outerPercent: outer,
                innerPercent: inner,
                outerColor: primaryColor,
                innerColor: secondaryColor
            )
        case .dualBattery:
            return MenuBarIconRenderer.dualBatteryIcon(
                topPercent: outer,
                bottomPercent: inner,
                topColor: primaryColor,
                bottomColor: secondaryColor
            )
        case .sideBySideBattery:
            return MenuBarIconRenderer.sideBySideBatteryIcon(
                leftPercent: outer,
                rightPercent: inner,
                leftColor: primaryColor,
                rightColor: secondaryColor,
                showPercent: config.showBatteryPercent
            )
        }
    }

    private static func resolvedMetric(
        primary: Double,
        secondary: Double,
        config: ProviderMenuBarDisplayConfig
    ) -> (percentage: Double, color: NSColor) {
        switch config.iconMetric {
        case .fiveHour:
            return (primary, gaugeColor(for: primary, config: config))
        case .weekly:
            return (secondary, gaugeColor(for: secondary, config: config))
        }
    }

    private static func showsRemaining(config: ProviderMenuBarDisplayConfig) -> Bool {
        switch config.style {
        case .none:
            return false
        default:
            return config.circularDisplayMode == .remaining
        }
    }

    private static func displayValue(for percentage: Double, showRemaining: Bool) -> Double {
        max(0, min(100, showRemaining ? (100.0 - percentage) : percentage))
    }

    private static func displayText(for percentage: Double, showRemaining: Bool) -> String {
        String(format: "%.0f%%", displayValue(for: percentage, showRemaining: showRemaining))
    }

    private static func iconWithStatusContent(
        icon: NSImage?,
        label: String,
        labelColor: NSColor,
        tooltip: String
    ) -> MenuBarRenderedContent {
        let font = NSFont.systemFont(ofSize: 12)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: labelColor]
        var elements: [MenuBarElement] = []
        if let icon {
            elements.append(.image(icon))
        }
        elements.append(.text(label, attributes: attributes))
        return MenuBarRenderedContent(image: composeElements(elements), tooltip: tooltip)
    }

    private static func segmentedPercentageImage(
        first: String,
        firstColor: NSColor,
        second: String,
        secondColor: NSColor,
        font: NSFont,
        separatorColor: NSColor
    ) -> NSImage {
        let separator = " · "
        let firstAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: firstColor]
        let separatorAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: separatorColor]
        let secondAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: secondColor]
        let firstWidth = (first as NSString).size(withAttributes: firstAttributes).width
        let separatorWidth = (separator as NSString).size(withAttributes: separatorAttributes).width
        let secondWidth = (second as NSString).size(withAttributes: secondAttributes).width
        let textHeight = (first as NSString).size(withAttributes: firstAttributes).height
        let image = NSImage(size: NSSize(width: firstWidth + separatorWidth + secondWidth, height: textHeight), flipped: false) { _ in
            var x: CGFloat = 0
            (first as NSString).draw(at: NSPoint(x: x, y: 0), withAttributes: firstAttributes)
            x += firstWidth
            (separator as NSString).draw(at: NSPoint(x: x, y: 0), withAttributes: separatorAttributes)
            x += separatorWidth
            (second as NSString).draw(at: NSPoint(x: x, y: 0), withAttributes: secondAttributes)
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func menuBarTextShadow() -> NSShadow {
        let isDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let shadow = NSShadow()
        shadow.shadowColor = (isDark ? NSColor.black : NSColor.white).withAlphaComponent(0.9)
        shadow.shadowOffset = NSSize(width: 0, height: 0)
        shadow.shadowBlurRadius = 2.0
        return shadow
    }

    private static func composeElements(_ elements: [MenuBarElement]) -> NSImage {
        let shadow = menuBarTextShadow()

        var totalWidth: CGFloat = 0
        for (index, element) in elements.enumerated() {
            if index > 0 { totalWidth += elementSpacing }
            if let image = element.image {
                totalWidth += image.size.width
            } else if let text = element.text, let attributes = element.attributes {
                totalWidth += (text as NSString).size(withAttributes: attributes).width
            }
        }

        let image = NSImage(size: NSSize(width: totalWidth, height: menuBarHeight), flipped: false) { _ in
            var x: CGFloat = 0
            for (index, element) in elements.enumerated() {
                if index > 0 { x += elementSpacing }
                if let elementImage = element.image {
                    let y = (menuBarHeight - elementImage.size.height) / 2
                    elementImage.draw(in: NSRect(x: x, y: y, width: elementImage.size.width, height: elementImage.size.height))
                    x += elementImage.size.width
                } else if let text = element.text, var attributes = element.attributes {
                    if element.needsShadow && attributes[.shadow] == nil {
                        attributes[.shadow] = shadow
                    }
                    let size = (text as NSString).size(withAttributes: attributes)
                    let y = (menuBarHeight - size.height) / 2
                    (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
                    x += size.width
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
