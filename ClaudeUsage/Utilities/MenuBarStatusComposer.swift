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
    let text: NSAttributedString?
    /// 세로 가운데를 맞출 때 기준으로 삼는 글꼴. 숫자 높이(cap height)의 가운데를 메뉴바 가운데에 둔다.
    let alignmentFont: NSFont?

    static func image(_ image: NSImage) -> MenuBarElement {
        MenuBarElement(image: image, text: nil, alignmentFont: nil)
    }

    static func text(_ text: String, attributes: [NSAttributedString.Key: Any]) -> MenuBarElement {
        MenuBarElement(
            image: nil, text: NSAttributedString(string: text, attributes: attributes),
            alignmentFont: attributes[.font] as? NSFont)
    }

    static func text(_ text: NSAttributedString, alignedTo font: NSFont) -> MenuBarElement {
        MenuBarElement(image: nil, text: text, alignmentFont: font)
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
    private(set) var renderKey: MenuBarProviderRenderKey
    private(set) var resetCreditBadge: MenuBarResetCreditBadge?

    func withResetCreditBadge(_ badge: MenuBarResetCreditBadge?) -> Self {
        var copy = self
        copy.resetCreditBadge = badge
        copy.renderKey.resetCreditBadge = badge?.key
        return copy
    }

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
        systemStatus: ProviderSystemStatus?,
        renderKey: MenuBarProviderRenderKey? = nil
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
            isStale: false,
            renderKey: renderKey
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
        isStale: Bool = false,
        renderKey: MenuBarProviderRenderKey? = nil
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
        self.renderKey = renderKey ?? MenuBarProviderRenderKey(
            kind: kind,
            regularText: regularText,
            condensedText: condensedText,
            tooltip: tooltip,
            resetText: resetText,
            showsProviderIcon: icon != nil,
            visualConfiguration: [
                styleIcon == nil ? "style.none" : "style.legacy",
            ],
            visualValues: [],
            statusIndicator:
                systemStatus?.effectiveIndicator,
            systemStatusSummary:
                systemStatus?.hasIssue == true
                ? systemStatus?.menuBarSummary
                : nil,
            accessibilityLabel: accessibilityLabel,
            accessibilityValue: accessibilityValue,
            isStale: isStale
        )
    }
}

enum MenuBarStatusComposer {
    private static func withAppearance(_ appearance: NSAppearance?, render: () -> NSImage?) -> NSImage? {
        var result: NSImage?
        (appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            result = render()
        }
        return result
    }

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
            drawCentered(
                NSAttributedString(string: text, attributes: attributes), alignedTo: attributes[.font] as? NSFont, x: 0)
            return true
        }
        image.isTemplate = false
        return MenuBarRenderedContent(image: image, tooltip: "\(AppDistribution.current.appName) 설정")
    }

    private static func statusDot(color: NSColor) -> MenuBarElement {
        .text("•", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: color,
        ])
    }

    /// 메뉴바 색상 모드(설정)를 반영한 게이지 색.
    /// HIG 권장인 모노크롬과 현행 임계값 색상 사이에서 사용자가 고른 정책을 적용한다.
    private static func gaugeColor(for percentage: Double?, config: ProviderMenuBarDisplayConfig) -> NSColor {
        guard let percentage, percentage.isFinite else { return .secondaryLabelColor }
        switch config.colorMode {
        case .always:
            return ColorProvider.nsStatusColor(for: percentage)
        case .warningOnly:
            return percentage >= MenuBarColorMode.warningThreshold
                ? ColorProvider.nsStatusColor(for: percentage)
                : .labelColor
        case .statusNumber, .monochrome:
            return .labelColor
        }
    }

    static func claudeSnapshot(
        config: ProviderMenuBarDisplayConfig,
        usage: ClaudeUsageResponse?,
        error: APIError?,
        hasAuthError: Bool,
        hasCredential: Bool,
        secondaryColor: NSColor,
        icon: NSImage?,
        systemStatus: ProviderSystemStatus? = nil,
        renderImages: Bool = true,
        appearance: NSAppearance? = nil
    ) -> MenuBarProviderSnapshot {
        let projection = usage.flatMap { usage in
            config.quotaSelection.map {
                MenuBarQuotaProjection(
                    selection: $0, limits: UsageLimitCatalog.claude(usage),
                    basis: config.usageValueBasis, timeFormat: config.timeFormat)
            }
        }
        let status = claudeStatus(
            config: config,
            usage: usage,
            error: error,
            hasAuthError: hasAuthError,
            hasCredential: hasCredential,
            secondaryColor: secondaryColor
        )
        let reset =
            projection?.resetText ?? (config.quotaSelection == nil ? resetText(usage: usage, config: config) : nil)
        let renderKey = providerRenderKey(
            kind: .claude,
            regularText: status.text,
            condensedText: status.text,
            tooltip: status.tooltip,
            resetText: reset,
            showsProviderIcon: config.showIcon,
            visualConfiguration:
                providerVisualConfiguration(config),
            visualValues: (usage.map {
                [
                    $0.gaugePercentage ?? 0,
                    $0.weeklyPercentage ?? 0,
                    $0.hasSessionWindow ? 1 : 0,
                ]
            } ?? []) + (projection?.visualValues ?? []),
            systemStatus: systemStatus,
            accessibilityLabel: nil,
            accessibilityValue: nil,
            isStale: false
        )
        return MenuBarProviderSnapshot(
            kind: .claude,
            text: status.text,
            color: status.color,
            tooltip: status.tooltip,
            icon:
                renderImages && config.showIcon
                ? icon
                : nil,
            styleIcon:
                renderImages
                ? withAppearance(appearance) {
                    if let projection { return styleIcon(projection: projection, config: config) }
                    return styleIcon(usage: usage, config: config)
                }
                : nil,
            resetText: reset,
            systemStatus: systemStatus,
            renderKey: renderKey
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
        systemStatus: ProviderSystemStatus? = nil,
        renderImages: Bool = true,
        appearance: NSAppearance? = nil
    ) -> MenuBarProviderSnapshot {
        let projection = usage.flatMap { usage in
            config.quotaSelection.map {
                MenuBarQuotaProjection(
                    selection: $0, limits: UsageLimitCatalog.codex(usage),
                    basis: config.usageValueBasis, timeFormat: config.timeFormat)
            }
        }
        let status = codexStatus(
            config: config,
            usage: usage,
            error: error,
            hasAuthError: hasAuthError,
            isAuthenticated: isAuthenticated,
            secondaryColor: secondaryColor
        )
        let reset =
            projection?.resetText ?? (config.quotaSelection == nil ? resetText(usage: usage, config: config) : nil)
        let renderKey = providerRenderKey(
            kind: .codex,
            regularText: status.text,
            condensedText: status.text,
            tooltip: status.tooltip,
            resetText: reset,
            showsProviderIcon: config.showIcon,
            visualConfiguration:
                providerVisualConfiguration(config),
            visualValues: (usage.map {
                [
                    $0.gaugePercentage ?? 0,
                    $0.weeklyPercentage,
                    $0.hasSessionWindow ? 1 : 0,
                ]
            } ?? []) + (projection?.visualValues ?? []),
            systemStatus: systemStatus,
            accessibilityLabel: nil,
            accessibilityValue: nil,
            isStale: false
        )
        return MenuBarProviderSnapshot(
            kind: .codex,
            text: status.text,
            color: status.color,
            tooltip: status.tooltip,
            icon:
                renderImages && config.showIcon
                ? icon
                : nil,
            styleIcon:
                renderImages
                ? withAppearance(appearance) {
                    if let projection { return styleIcon(projection: projection, config: config) }
                    return styleIcon(usage: usage, config: config)
                }
                : nil,
            resetText: reset,
            systemStatus: systemStatus,
            renderKey: renderKey
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
        icon: NSImage?,
        renderImages: Bool = true,
        appearance: NSAppearance? = nil, design: MenuBarDesign = .modern, colorMode: MenuBarColorMode = .always
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
        let statusColor = antigravityColor(for: presentation.tone)
        let usesMonochromeGauge =
            colorMode == .monochrome || colorMode == .statusNumber
            || (colorMode == .warningOnly
                && presentation.tone != .warning && presentation.tone != .critical)
        let usesCutoutText =
            colorMode == .monochrome
            || (colorMode == .warningOnly
                && presentation.tone != .warning && presentation.tone != .critical)
        let color: NSColor = usesMonochromeGauge ? .labelColor : statusColor
        let batteryTextColor: NSColor? = colorMode == .statusNumber ? statusColor : nil
        let tooltip = staleAnnotatedTooltip(
            presentation.tooltip,
            isStale: isStale
        )
        let accessibilityValue =
            staleAnnotatedAccessibilityValue(
                presentation.accessibilityValue,
                isStale: isStale
            )
        let renderKey = providerRenderKey(
            kind: .antigravity,
            regularText: presentation.regularText,
            condensedText: presentation.condensedText,
            tooltip: tooltip,
            resetText: nil,
            showsProviderIcon:
                presentation.showsProviderIcon,
            visualConfiguration: [
                presentation.style.rawValue, design.rawValue, colorMode.rawValue,
                presentation.selectedLaneID?.rawValue
                    ?? "lane.none",
                presentation.showsGaugePercentage
                    ? "gauge.percent"
                    : "gauge.no-percent",
                String(describing: presentation.tone),
            ],
            visualValues:
                presentation.gaugePercentage.map { [$0] }
                ?? [],
            systemStatus: nil,
            accessibilityLabel:
                presentation.accessibilityLabel,
            accessibilityValue: accessibilityValue,
            isStale: isStale
        )
        return MenuBarProviderSnapshot(
            kind: .antigravity,
            regularText: presentation.regularText,
            condensedText: presentation.condensedText,
            color: color,
            tooltip: tooltip,
            icon:
                renderImages
                    && presentation.showsProviderIcon
                ? icon
                : nil,
            styleIcon:
                renderImages
                ? withAppearance(appearance) {
                    antigravityStyleIcon(
                        presentation: presentation, color: color, design: design,
                        cutoutText: usesCutoutText, textColor: batteryTextColor)
                }
                : nil,
            resetText: nil,
            systemStatus: nil,
            accessibilityLabel: presentation.accessibilityLabel,
            accessibilityValue: accessibilityValue,
            isStale: isStale,
            renderKey: renderKey
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
        if let badge = snapshot.resetCreditBadge {
            let color: NSColor =
                switch badge.tone {
                case .normal: secondaryColor
                case .new: .systemBlue
                case .expiring: .systemRed
                }
            elements.append(.text(resetCreditBadgeText(badge, font: resetFont, color: color), alignedTo: resetFont))
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
            !tooltip.contains(UsageStatusLabel.previousValue)
        else {
            return tooltip
        }
        return "\(tooltip)\n상태: \(UsageStatusLabel.previousValue)"
    }

    nonisolated private static func staleAnnotatedAccessibilityValue(
        _ value: String,
        isStale: Bool
    ) -> String {
        guard isStale,
            !value.contains(UsageStatusLabel.previousValue)
        else {
            return value
        }
        return value.isEmpty
            ? UsageStatusLabel.previousValue
            : "\(value), \(UsageStatusLabel.previousValue)"
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
        var base = tooltipBlock(name: snapshot.kind.displayName, tooltip: snapshot.tooltip)
        if let badge = snapshot.resetCreditBadge {
            base += "\n초기화권 \(badge.count)개"
        }
        guard let status = snapshot.systemStatus, status.hasIssue else {
            return base
        }
        return "\(base)\n⚠ \(snapshot.kind.displayName) 서비스 상태: \(status.menuBarSummary)"
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
        if case .claudeCodeExecutableNotFound = error {
            return "\n\(ClaudeCodeCredentialIssue.executableNotFoundExplanation)\n마지막 성공 데이터 표시 중"
        }
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

    private static func providerVisualConfiguration(
        _ config: ProviderMenuBarDisplayConfig
    ) -> [String] {
        [
            config.showIcon ? "icon.visible" : "icon.hidden",
            config.style.rawValue,
            config.percentageDisplay.rawValue,
            config.showBatteryPercent
                ? "battery.percent"
                : "battery.no-percent",
            config.resetTimeDisplay.rawValue,
            config.timeFormat.rawValue,
            config.circularDisplayMode.rawValue,
            config.basisOverride?.rawValue ?? "legacy",
            config.iconMetric.rawValue,
            config.colorMode.rawValue, config.design.rawValue,
            config.quotaSelection == nil ? "legacy-quota" : "selected-quota",
            config.quotaSelection?.percentageIDs.joined(separator: ",") ?? "",
            config.quotaSelection?.resetIDs.joined(separator: ",") ?? "",
            config.quotaSelection?.gaugeIDs.joined(separator: ",") ?? "",
        ]
    }

    private static func providerRenderKey(
        kind: AppProviderKind,
        regularText: String?,
        condensedText: String?,
        tooltip: String,
        resetText: String?,
        showsProviderIcon: Bool,
        visualConfiguration: [String],
        visualValues: [Double],
        systemStatus: ProviderSystemStatus?,
        accessibilityLabel: String?,
        accessibilityValue: String?,
        isStale: Bool
    ) -> MenuBarProviderRenderKey {
        MenuBarProviderRenderKey(
            kind: kind,
            regularText: regularText,
            condensedText: condensedText,
            tooltip: tooltip,
            resetText: resetText,
            showsProviderIcon: showsProviderIcon,
            visualConfiguration: visualConfiguration,
            visualValues: visualValues,
            statusIndicator:
                systemStatus?.effectiveIndicator,
            systemStatusSummary:
                systemStatus?.hasIssue == true
                ? systemStatus?.menuBarSummary
                : nil,
            accessibilityLabel: accessibilityLabel,
            accessibilityValue: accessibilityValue,
            isStale: isStale
        )
    }

    private static func claudeStatus(
        config: ProviderMenuBarDisplayConfig,
        usage: ClaudeUsageResponse?,
        error: APIError?,
        hasAuthError: Bool,
        hasCredential: Bool,
        secondaryColor: NSColor
    ) -> MenuBarProviderStatus {
        let executableMissing: Bool
        if case .claudeCodeExecutableNotFound? = error {
            executableMissing = true
        } else {
            executableMissing = false
        }
        if !hasCredential, !executableMissing {
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

        if let selection = config.quotaSelection {
            let projection = MenuBarQuotaProjection(
                selection: selection, limits: UsageLimitCatalog.claude(usage),
                basis: config.usageValueBasis, timeFormat: config.timeFormat)
            return MenuBarProviderStatus(
                text: projection.percentageText,
                color: gaugeColor(for: projection.primary?.usedPercentage, config: config),
                tooltip: projection.tooltip + staleNote(error: error, hasAuthError: hasAuthError))
        }

        let hasPrimary = usage.hasSessionWindow
        let fiveHour = usage.fiveHourPercentage
        let weekly = usage.weeklyPercentage
        let displayPrimary = config.usageValueBasis.text(fromUsed: hasPrimary ? fiveHour : weekly)
        let displayWeekly = config.usageValueBasis.text(fromUsed: weekly)
        let text: String = {
            switch config.percentageDisplay {
            case .none:
                return ""
            case .fiveHour:
                return displayPrimary
            case .weekly:
                return displayWeekly
            case .dual:
                guard hasPrimary, weekly != nil else { return hasPrimary ? displayPrimary : displayWeekly }
                return "\(displayPrimary)·\(displayWeekly)"
            }
        }()

        return MenuBarProviderStatus(
            text: text,
            color: gaugeColor(for: usage.gaugePercentage, config: config),
            tooltip: windowSummaryTooltip(session: fiveHour, weekly: weekly, config: config)
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

        if let selection = config.quotaSelection {
            let projection = MenuBarQuotaProjection(
                selection: selection, limits: UsageLimitCatalog.codex(usage),
                basis: config.usageValueBasis, timeFormat: config.timeFormat)
            return MenuBarProviderStatus(
                text: projection.percentageText,
                color: gaugeColor(for: projection.primary?.usedPercentage, config: config),
                tooltip: projection.tooltip + (usage.workspaceLimitNotice.map { "\n\($0)" } ?? "")
                    + staleNote(error: error, hasAuthError: hasAuthError))
        }

        let hasPrimary = usage.hasSessionWindow
        let primary = usage.sessionPercentage
        let weekly = usage.weeklyWindow?.utilization
        let displayPrimary = config.usageValueBasis.text(fromUsed: hasPrimary ? primary : weekly)
        let displayWeekly = config.usageValueBasis.text(fromUsed: weekly)
        let text: String = {
            switch config.percentageDisplay {
            case .none:
                return ""
            case .fiveHour:
                return displayPrimary
            case .weekly:
                return displayWeekly
            case .dual:
                // 응답에 있는 창만 표시한다(주간 전용이면 주간, 세션 전용이면 세션)
                guard hasPrimary, weekly != nil else { return hasPrimary ? displayPrimary : displayWeekly }
                return "\(displayPrimary)·\(displayWeekly)"
            }
        }()

        return MenuBarProviderStatus(
            text: text,
            color: gaugeColor(for: usage.gaugePercentage, config: config),
            tooltip: windowSummaryTooltip(session: hasPrimary ? primary : nil, weekly: weekly, config: config)
                + (usage.workspaceLimitNotice.map { " · \($0)" } ?? "")
                + staleNote(error: error, hasAuthError: hasAuthError)
        )
    }

    /// 응답에 있는 창만 표시 기준(사용량/남은 양)으로 적는다.
    private static func windowSummaryTooltip(
        session: Double?, weekly: Double?, config: ProviderMenuBarDisplayConfig
    ) -> String {
        let basis = config.usageValueBasis
        let parts = [
            session.map { "5시간 \(basis.text(fromUsed: $0))" },
            weekly.map { "주간 \(basis.text(fromUsed: $0))" },
        ].compactMap { $0 }
        return parts.isEmpty ? "데이터 없음" : parts.joined(separator: " · ") + " \(basis.label)"
    }

    private static func resetText(usage: ClaudeUsageResponse?, config: ProviderMenuBarDisplayConfig) -> String? {
        guard let usage else { return nil }
        switch config.resetTimeDisplay {
        case .none:
            return nil
        case .fiveHour:
            // 숫자/게이지의 주간 대체와 시간 선택은 별개다. 고른 창의 시각이 없으면 시간을 숨긴다.
            guard let resetAt = usage.fiveHour?.resetsAt else { return nil }
            return TimeFormatter.formatResetTime(
                from: resetAt, style: config.timeFormat, includeDateIfNotToday: false)
        case .weekly:
            guard let resetAt = usage.sevenDay?.resetsAt else { return nil }
            return TimeFormatter.formatResetTimeWeekly(
                from: resetAt, style: config.timeFormat, includeDateIfNotToday: false)
        case .dual:
            let first = usage.fiveHour?.resetsAt.flatMap {
                TimeFormatter.formatResetTime(
                    from: $0, style: config.timeFormat, includeDateIfNotToday: false)
            }
            let second = usage.sevenDay?.resetsAt.flatMap {
                TimeFormatter.formatResetTimeWeekly(
                    from: $0, style: config.timeFormat, includeDateIfNotToday: false)
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
                return TimeFormatter.formatResetTime(
                    from: sessionReset, style: config.timeFormat, includeDateIfNotToday: false)
            }
            guard let weeklyReset = usage.weeklyWindow?.resetAtISO else { return nil }
            return TimeFormatter.formatResetTimeWeekly(
                from: weeklyReset, style: config.timeFormat, includeDateIfNotToday: false)
        case .weekly:
            guard let resetAt = usage.weeklyWindow?.resetAtISO else { return nil }
            return TimeFormatter.formatResetTimeWeekly(
                from: resetAt, style: config.timeFormat, includeDateIfNotToday: false)
        case .dual:
            let first = usage.sessionWindow?.resetAtISO.flatMap {
                TimeFormatter.formatResetTime(
                    from: $0, style: config.timeFormat, includeDateIfNotToday: false)
            }
            let second = usage.weeklyWindow?.resetAtISO.flatMap {
                TimeFormatter.formatResetTimeWeekly(
                    from: $0, style: config.timeFormat, includeDateIfNotToday: false)
            }
            if let first, let second { return "\(first) · \(second)" }
            return first ?? second
        }
    }

    private static func styleIcon(projection: MenuBarQuotaProjection, config: ProviderMenuBarDisplayConfig) -> NSImage?
    {
        guard !projection.selection.gaugeIDs.isEmpty else { return nil }
        let primary = projection.primary?.usedPercentage
        if projection.selection.gaugeIDs.count == 1,
            config.style == .dualBattery || config.style == .sideBySideBattery || config.style == .concentricRings
        {
            return weeklyOnlyStyleIcon(weekly: primary, config: config)
        }
        return styleIcon(
            primary: primary, secondary: projection.secondary?.usedPercentage, config: config,
            metric: (primary, gaugeColor(for: primary, config: config)))
    }

    private static func styleIcon(usage: ClaudeUsageResponse?, config: ProviderMenuBarDisplayConfig) -> NSImage? {
        guard let usage else { return nil }
        let primary = usage.gaugePercentage
        let secondary = usage.weeklyPercentage
        if !usage.hasSessionWindow {
            return weeklyOnlyStyleIcon(weekly: secondary, config: config)
        }
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
        let secondary = usage.weeklyWindow?.utilization
        if !usage.hasSessionWindow {
            return weeklyOnlyStyleIcon(weekly: secondary, config: config)
        }
        return styleIcon(
            primary: primary,
            secondary: secondary,
            config: config,
            metric: resolvedMetric(primary: primary, secondary: secondary, config: config)
        )
    }

    // 5시간 창이 없는 응답은 주간 게이지 하나로 그린다(0% 오인 방지).
    private static func weeklyOnlyStyleIcon(weekly: Double?, config: ProviderMenuBarDisplayConfig) -> NSImage? {
        let value = config.usageValueBasis.percentage(fromUsed: weekly)
        let color = gaugeColor(for: weekly, config: config)
        switch config.style {
        case .none:
            return nil
        case .batteryBar, .dualBattery, .sideBySideBattery:
            return MenuBarIconRenderer.batteryIcon(
                percentage: value,
                color: color,
                showPercent: config.showBatteryPercent, design: config.design,
                monochrome: usesCutoutBatteryText(used: weekly, mode: config.colorMode),
                textColor: batteryNumberColor(used: weekly, mode: config.colorMode)
            )
        case .circular, .concentricRings:
            return MenuBarIconRenderer.circularRingIcon(percentage: value, color: color, design: config.design)
        }
    }

    private static func antigravityStyleIcon(
        presentation: AntigravityMenuBarQuotaPresentation,
        color: NSColor, design: MenuBarDesign, cutoutText: Bool, textColor: NSColor?
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
                showPercent: presentation.showsGaugePercentage, design: design,
                monochrome: cutoutText, textColor: textColor
            )
        case .circular:
            return MenuBarIconRenderer.circularRingIcon(
                percentage: percentage,
                color: color, design: design
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

    private static func usesCutoutBatteryText(used: Double?, mode: MenuBarColorMode) -> Bool {
        mode == .monochrome || (mode == .warningOnly && (used ?? 0) < MenuBarColorMode.warningThreshold)
    }

    private static func batteryNumberColor(used: Double?, mode: MenuBarColorMode) -> NSColor? {
        guard mode == .statusNumber, let used, used.isFinite else { return nil }
        return ColorProvider.nsStatusColor(for: used)
    }

    private static func styleIcon(
        primary: Double?,
        secondary: Double?,
        config: ProviderMenuBarDisplayConfig,
        metric: (percentage: Double?, color: NSColor)
    ) -> NSImage? {
        let primaryColor = gaugeColor(for: primary, config: config)
        let secondaryColor = gaugeColor(for: secondary, config: config)
        let circularValue = config.usageValueBasis.percentage(fromUsed: metric.percentage)
        let outer = config.usageValueBasis.percentage(fromUsed: primary)
        let inner = config.usageValueBasis.percentage(fromUsed: secondary)

        switch config.style {
        case .none:
            return nil
        case .batteryBar:
            return MenuBarIconRenderer.batteryIcon(
                percentage: circularValue,
                color: metric.color,
                showPercent: config.showBatteryPercent, design: config.design,
                monochrome: usesCutoutBatteryText(used: metric.percentage, mode: config.colorMode),
                textColor: batteryNumberColor(used: metric.percentage, mode: config.colorMode)
            )
        case .circular:
            return MenuBarIconRenderer.circularRingIcon(
                percentage: circularValue, color: metric.color, design: config.design)
        case .concentricRings:
            return MenuBarIconRenderer.concentricRingsIcon(
                outerPercent: outer,
                innerPercent: inner,
                outerColor: primaryColor,
                innerColor: secondaryColor, design: config.design
            )
        case .dualBattery:
            return MenuBarIconRenderer.dualBatteryIcon(
                topPercent: outer,
                bottomPercent: inner,
                topColor: primaryColor,
                bottomColor: secondaryColor, design: config.design
            )
        case .sideBySideBattery:
            return MenuBarIconRenderer.sideBySideBatteryIcon(
                leftPercent: outer,
                rightPercent: inner,
                leftColor: primaryColor,
                rightColor: secondaryColor,
                showPercent: config.showBatteryPercent, design: config.design,
                monochrome: usesCutoutBatteryText(used: primary, mode: config.colorMode),
                rightMonochrome: usesCutoutBatteryText(used: secondary, mode: config.colorMode),
                leftTextColor: batteryNumberColor(used: primary, mode: config.colorMode),
                rightTextColor: batteryNumberColor(used: secondary, mode: config.colorMode)
            )
        }
    }

    private static func resolvedMetric(
        primary: Double?,
        secondary: Double?,
        config: ProviderMenuBarDisplayConfig
    ) -> (percentage: Double?, color: NSColor) {
        switch config.iconMetric {
        case .fiveHour:
            return (primary, gaugeColor(for: primary, config: config))
        case .weekly:
            return (secondary, gaugeColor(for: secondary, config: config))
        }
    }

    private static func composeElements(_ elements: [MenuBarElement]) -> NSImage {
        var totalWidth: CGFloat = 0
        for (index, element) in elements.enumerated() {
            if index > 0 { totalWidth += elementSpacing }
            if let image = element.image {
                totalWidth += image.size.width
            } else if let text = element.text {
                totalWidth += text.size().width
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
                } else if let text = element.text {
                    x += drawCentered(text, alignedTo: element.alignmentFont, x: x)
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// 숫자 높이(cap height)의 가운데를 메뉴바 가운데에 맞춰 그리고 너비를 돌려준다. 줄 높이로 가운데를 잡으면
    /// 아래쪽 여백(descender) 때문에 글자가 로고보다 0.7pt쯤 내려가고, 글자 크기마다 기준선이 달라진다.
    @discardableResult
    private static func drawCentered(_ text: NSAttributedString, alignedTo font: NSFont?, x: CGFloat) -> CGFloat {
        let font = font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let size = text.size()
        let baseline = (menuBarHeight - font.capHeight) / 2
        // usesLineFragmentOrigin 없이 그리면 사각형의 원점이 기준선이다.
        text.draw(with: NSRect(x: x, y: baseline, width: size.width, height: size.height), options: [])
        return size.width
    }

    private static func resetCreditBadgeText(
        _ badge: MenuBarResetCreditBadge, font: NSFont, color: NSColor
    ) -> NSAttributedString {
        let fit = ResetCreditSymbol.fit(to: font)
        let text = NSMutableAttributedString(
            string: MenuBarResetCreditBadge.symbol,
            attributes: [
                .font: font.withSize(fit.pointSize), .foregroundColor: color, .baselineOffset: fit.baselineOffset,
            ])
        text.append(NSAttributedString(string: "\(badge.count)", attributes: [.font: font, .foregroundColor: color]))
        return text
    }
}
