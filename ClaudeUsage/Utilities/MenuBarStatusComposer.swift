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
    let text: String
    let color: NSColor
    let tooltip: String
    let icon: NSImage?
    let styleIcon: NSImage?
    let resetText: String?
    let systemStatus: ProviderSystemStatus?
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
        let fiveHourColor = ColorProvider.nsStatusColor(for: fiveHour)
        let weeklyColor = ColorProvider.nsWeeklyStatusColor(for: weekly)
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
        let tooltip = "현재 세션: \(Int(fiveHour))% / 주간: \(Int(weekly))%\(authWarning)"
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

        let primary = usage.primaryPercentage
        let weekly = usage.secondaryPercentage
        let primaryColor = ColorProvider.nsStatusColor(for: primary)
        let weeklyColor = ColorProvider.nsWeeklyStatusColor(for: weekly)
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
            elements.append(.text(displayText(for: primary, showRemaining: showsRemaining(config: config)), attributes: [.font: font, .foregroundColor: primaryColor], shadow: true))
        case .weekly:
            elements.append(.text(displayText(for: weekly, showRemaining: showsRemaining(config: config)), attributes: [.font: font, .foregroundColor: weeklyColor], shadow: true))
        case .dual:
            elements.append(.image(segmentedPercentageImage(
                first: displayText(for: primary, showRemaining: showsRemaining(config: config)),
                firstColor: primaryColor,
                second: displayText(for: weekly, showRemaining: showsRemaining(config: config)),
                secondColor: weeklyColor,
                font: font,
                separatorColor: secondaryColor
            )))
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
            tooltip: "Codex 현재: \(Int(primary))% / 주간: \(Int(weekly))%"
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

    static func antigravitySnapshot(
        config: ProviderMenuBarDisplayConfig,
        usage: AntigravityUsageResponse?,
        error: APIError?,
        hasAuthError: Bool,
        hasCredential: Bool,
        secondaryColor: NSColor,
        icon: NSImage?,
        systemStatus: ProviderSystemStatus? = nil
    ) -> MenuBarProviderSnapshot {
        let status = antigravityStatus(
            config: config,
            usage: usage,
            error: error,
            hasAuthError: hasAuthError,
            hasCredential: hasCredential,
            secondaryColor: secondaryColor
        )
        let usageWithWindows = usage?.hasUsageWindows == true ? usage : nil
        return MenuBarProviderSnapshot(
            kind: .antigravity,
            text: status.text,
            color: status.color,
            tooltip: status.tooltip,
            icon: config.showIcon ? icon : nil,
            styleIcon: styleIcon(usage: usageWithWindows, config: config),
            resetText: resetText(usage: usageWithWindows, config: config),
            systemStatus: systemStatus
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
            tooltip: "Claude: \(claude.tooltip) / Codex: \(codex.tooltip)"
        )
    }

    static func singleProviderContent(
        snapshot: MenuBarProviderSnapshot,
        secondaryColor: NSColor
    ) -> MenuBarRenderedContent {
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let resetFont = NSFont.systemFont(ofSize: 11)
        var elements = renderElements(
            for: snapshot,
            valueFont: valueFont,
            resetFont: resetFont,
            secondaryColor: secondaryColor
        )
        if elements.isEmpty {
            elements.append(statusDot(color: secondaryColor))
        }
        return MenuBarRenderedContent(
            image: composeElements(elements),
            tooltip: providerTooltip(for: snapshot)
        )
    }

    static func multipleProviderContent(
        snapshots: [MenuBarProviderSnapshot],
        secondaryColor: NSColor
    ) -> MenuBarRenderedContent {
        let separatorFont = NSFont.systemFont(ofSize: 11, weight: .regular)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let resetFont = NSFont.systemFont(ofSize: 10, weight: .regular)
        let resolvedSnapshots = snapshots.filter { $0.kind.isRuntimeProvider }
        let elements = resolvedSnapshots.enumerated().flatMap { index, snapshot -> [MenuBarElement] in
            var rendered = renderElements(
                for: snapshot,
                valueFont: valueFont,
                resetFont: resetFont,
                secondaryColor: secondaryColor
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
            .joined(separator: " / ")
        return MenuBarRenderedContent(
            image: composeElements(elements.isEmpty ? [statusDot(color: secondaryColor)] : elements),
            tooltip: tooltip
        )
    }

    private static func renderElements(
        for snapshot: MenuBarProviderSnapshot,
        valueFont: NSFont,
        resetFont: NSFont,
        secondaryColor: NSColor,
        includeResetText: Bool = true
    ) -> [MenuBarElement] {
        var elements: [MenuBarElement] = []
        if let icon = snapshot.icon {
            let renderedIcon = statusBadgedIcon(icon, for: snapshot)
            elements.append(.image(renderedIcon))
        }
        if !snapshot.text.isEmpty {
            elements.append(.text(snapshot.text, attributes: [.font: valueFont, .foregroundColor: snapshot.color]))
        }
        if let styleIcon = snapshot.styleIcon {
            elements.append(.image(styleIcon))
        }
        if includeResetText, let resetText = snapshot.resetText {
            elements.append(.text(resetText, attributes: [.font: resetFont, .foregroundColor: secondaryColor]))
        }
        if snapshot.icon == nil, let status = snapshot.systemStatus, status.hasIssue {
            elements.append(statusDot(color: statusBadgeColor(for: status.effectiveIndicator)))
        }
        return elements
    }

    nonisolated private static func providerTooltip(for snapshot: MenuBarProviderSnapshot) -> String {
        let base = "\(snapshot.kind.displayName): \(snapshot.tooltip)"
        guard let status = snapshot.systemStatus, status.hasIssue else {
            return base
        }
        return "\(base)\n\(snapshot.kind.displayName) 상태: \(status.menuBarSummary)"
    }

    private static func statusBadgedIcon(_ icon: NSImage, for snapshot: MenuBarProviderSnapshot) -> NSImage {
        guard let status = snapshot.systemStatus, status.hasIssue else {
            return icon
        }
        return MenuBarIconFactory.badgedIcon(icon, indicator: status.effectiveIndicator)
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
            color: ColorProvider.nsStatusColor(for: fiveHour),
            tooltip: "현재 \(Int(fiveHour.rounded()))% / 주간 \(Int(weekly.rounded()))%"
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

        let primary = usage.primaryPercentage
        let weekly = usage.secondaryPercentage
        let displayPrimary = displayValue(for: primary, showRemaining: showsRemaining(config: config))
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
                return String(format: "%.0f%%·%.0f%%", displayPrimary, displayWeekly)
            }
        }()

        return MenuBarProviderStatus(
            text: text,
            color: ColorProvider.nsStatusColor(for: primary),
            tooltip: "현재 \(Int(primary.rounded()))% / 주간 \(Int(weekly.rounded()))%"
        )
    }

    private static func antigravityStatus(
        config: ProviderMenuBarDisplayConfig,
        usage: AntigravityUsageResponse?,
        error: APIError?,
        hasAuthError: Bool,
        hasCredential: Bool,
        secondaryColor: NSColor
    ) -> MenuBarProviderStatus {
        if !hasCredential {
            return MenuBarProviderStatus(text: "연결", color: .systemOrange, tooltip: "Antigravity 연결 필요")
        }
        guard let usage else {
            if let error {
                if error.isTemporaryFailure {
                    return MenuBarProviderStatus(
                        text: "…",
                        color: secondaryColor,
                        tooltip: error.errorDescription ?? "재시도 중"
                    )
                }
                return MenuBarProviderStatus(
                    text: hasAuthError ? "연결" : "오류",
                    color: .systemOrange,
                    tooltip: hasAuthError
                        ? "Antigravity 연결이 만료됐습니다. 앱을 다시 열거나 설정에서 Google 계정을 다시 연결하세요."
                        : (error.errorDescription ?? "조회 오류")
                )
            }
            return MenuBarProviderStatus(text: "…", color: secondaryColor, tooltip: "로딩 중")
        }

        guard usage.hasUsageWindows else {
            let account = usage.accountEmail.map { " · \($0)" } ?? ""
            return MenuBarProviderStatus(
                text: "!",
                color: .systemOrange,
                tooltip: "Antigravity\(account) · 계정 확인됨 · quota 수치 미지원"
            )
        }

        let windows = antigravityMenuBarWindows(usage: usage, config: config)
        let primary = windows.primary?.usedPercent ?? 0
        let secondary = windows.secondary?.usedPercent ?? 0
        let displayPrimary = displayValue(for: primary, showRemaining: showsRemaining(config: config))
        let displaySecondary = displayValue(for: secondary, showRemaining: showsRemaining(config: config))
        let text: String = {
            switch config.percentageDisplay {
            case .none:
                return ""
            case .fiveHour:
                return String(format: "%.0f%%", displayPrimary)
            case .weekly:
                return String(format: "%.0f%%", displaySecondary)
            case .dual:
                return String(format: "%.0f%%·%.0f%%", displayPrimary, displaySecondary)
            }
        }()

        return MenuBarProviderStatus(
            text: text,
            color: ColorProvider.nsStatusColor(for: primary),
            tooltip: antigravityTooltip(usage: usage, windows: windows)
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
            guard let resetAt = usage.rateLimit?.primaryWindow?.resetAtISO else { return nil }
            return TimeFormatter.formatResetTime(from: resetAt, style: config.timeFormat, includeDateIfNotToday: false)
        case .weekly:
            guard let resetAt = usage.rateLimit?.secondaryWindow?.resetAtISO else { return nil }
            return TimeFormatter.formatResetTimeWeekly(from: resetAt, style: config.timeFormat, includeDateIfNotToday: false)
        case .dual:
            let first = usage.rateLimit?.primaryWindow?.resetAtISO.flatMap {
                TimeFormatter.formatResetTime(from: $0, style: config.timeFormat, includeDateIfNotToday: false)
            }
            let second = usage.rateLimit?.secondaryWindow?.resetAtISO.flatMap {
                TimeFormatter.formatResetTimeWeekly(from: $0, style: config.timeFormat, includeDateIfNotToday: false)
            }
            if let first, let second { return "\(first) · \(second)" }
            return first ?? second
        }
    }

    private static func resetText(usage: AntigravityUsageResponse?, config: ProviderMenuBarDisplayConfig) -> String? {
        guard let usage else { return nil }
        let windows = antigravityMenuBarWindows(usage: usage, config: config)
        switch config.resetTimeDisplay {
        case .none:
            return nil
        case .fiveHour:
            guard let resetAt = windows.primary?.resetAtISO else { return nil }
            return TimeFormatter.formatResetTime(from: resetAt, style: config.timeFormat, includeDateIfNotToday: false)
        case .weekly:
            guard let resetAt = windows.secondary?.resetAtISO else { return nil }
            return TimeFormatter.formatResetTimeWeekly(from: resetAt, style: config.timeFormat, includeDateIfNotToday: false)
        case .dual:
            let first = windows.primary?.resetAtISO.flatMap {
                TimeFormatter.formatResetTime(from: $0, style: config.timeFormat, includeDateIfNotToday: false)
            }
            let second = windows.secondary?.resetAtISO.flatMap {
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
        let primary = usage.primaryPercentage
        let secondary = usage.secondaryPercentage
        return styleIcon(
            primary: primary,
            secondary: secondary,
            config: config,
            metric: resolvedMetric(primary: primary, secondary: secondary, config: config)
        )
    }

    private static func styleIcon(usage: AntigravityUsageResponse?, config: ProviderMenuBarDisplayConfig) -> NSImage? {
        guard let usage else { return nil }
        let windows = antigravityMenuBarWindows(usage: usage, config: config)
        let primary = windows.primary?.usedPercent ?? 0
        let secondary = windows.secondary?.usedPercent ?? 0
        return styleIcon(
            primary: primary,
            secondary: secondary,
            config: config,
            metric: resolvedMetric(primary: primary, secondary: secondary, config: config)
        )
    }

    private static func antigravityMenuBarWindows(
        usage: AntigravityUsageResponse,
        config: ProviderMenuBarDisplayConfig
    ) -> (primary: AntigravityUsageWindow?, secondary: AntigravityUsageWindow?) {
        let primary = usage.menuBarPrimaryWindow(preferredModelID: config.primaryModelID)
        let secondary = usage.menuBarSecondaryWindow(
            preferredModelID: config.secondaryModelID,
            primaryModelID: primary?.modelID
        )
        return (primary, secondary)
    }

    private static func antigravityTooltip(
        usage: AntigravityUsageResponse,
        windows: (primary: AntigravityUsageWindow?, secondary: AntigravityUsageWindow?)
    ) -> String {
        let selected = [windows.primary, windows.secondary]
            .compactMap { $0 }
            .reduce(into: [AntigravityUsageWindow]()) { result, window in
                if !result.contains(where: { $0.modelID == window.modelID }) {
                    result.append(window)
                }
            }
            .map { "\($0.label) \(Int($0.usedPercent.rounded()))%" }
            .joined(separator: " / ")
        guard !selected.isEmpty else {
            return "Antigravity · \(usage.modelSummary(separator: " / "))"
        }
        return "Antigravity · \(selected)"
    }

    private static func styleIcon(
        primary: Double,
        secondary: Double,
        config: ProviderMenuBarDisplayConfig,
        metric: (percentage: Double, color: NSColor)
    ) -> NSImage? {
        let primaryColor = ColorProvider.nsStatusColor(for: primary)
        let secondaryColor = ColorProvider.nsWeeklyStatusColor(for: secondary)
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
            return (primary, ColorProvider.nsStatusColor(for: primary))
        case .weekly:
            return (secondary, ColorProvider.nsWeeklyStatusColor(for: secondary))
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
