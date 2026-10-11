import AppKit

/// 메뉴바에 보일 상태 문구, 툴팁, 색을 정한다. 무엇을 보일지만 정하고 그리는 일은 `MenuBarStatusComposer`가 한다.
struct MenuBarProviderStatus {
    let text: String
    let color: NSColor
    let tooltip: String
}

enum MenuBarProviderStatusPolicy {
    /// 메뉴바 색상 모드(설정)를 반영한 게이지 색.
    /// HIG 권장인 모노크롬과 현행 임계값 색상 사이에서 사용자가 고른 정책을 적용한다.
    static func gaugeColor(for percentage: Double?, config: ProviderMenuBarDisplayConfig) -> NSColor {
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

    /// 인증 실패는 별도 경고 배지로 처리하므로 여기서는 제외한다.
    /// 경고류는 항상 "⚠ " 접두 + 별도 줄 — tooltip 줄넘김 규칙(1줄 = 수치 요약, 이후 줄 = 경고)의 일부.
    private static func staleNote(error: APIError?, hasAuthError: Bool, isStale: Bool) -> String {
        guard let error, !hasAuthError else { return "" }
        if case .claudeCodeExecutableNotFound = error {
            return "\n\(ClaudeCodeCredentialIssue.executableNotFoundExplanation)\n마지막 성공 데이터 표시 중"
        }
        guard isStale else { return "" }
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

    static func claude(
        config: ProviderMenuBarDisplayConfig,
        projection: MenuBarQuotaProjection,
        usage: ClaudeUsageResponse?,
        error: APIError?,
        hasAuthError: Bool,
        hasCredential: Bool,
        isStale: Bool,
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

        if config.quotaSelection != nil {
            return MenuBarProviderStatus(
                text: projection.percentageText,
                color: gaugeColor(for: projection.primary?.usedPercentage, config: config),
                tooltip: projection.tooltip + staleNote(error: error, hasAuthError: hasAuthError, isStale: isStale))
        }

        let hasPrimary = usage.hasSessionWindow
        let fiveHour = usage.fiveHourPercentage
        let weekly = usage.weeklyPercentage
        let text = MenuBarQuotaProjection.legacyPercentageText(
            session: fiveHour, weekly: weekly, hasSession: hasPrimary,
            display: config.percentageDisplay, basis: config.usageValueBasis)

        return MenuBarProviderStatus(
            text: text,
            color: gaugeColor(for: usage.gaugePercentage, config: config),
            tooltip: (config.gaugeSelection != nil
                ? projection.tooltip
                : MenuBarQuotaProjection.legacyTooltip(
                    session: fiveHour, weekly: weekly, basis: config.usageValueBasis))
                + staleNote(error: error, hasAuthError: hasAuthError, isStale: isStale)
        )
    }

    static func codex(
        config: ProviderMenuBarDisplayConfig,
        projection: MenuBarQuotaProjection,
        usage: CodexUsageResponse?,
        error: APIError?,
        hasAuthError: Bool,
        isAuthenticated: Bool,
        isStale: Bool,
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

        if config.quotaSelection != nil {
            return MenuBarProviderStatus(
                text: projection.percentageText,
                color: gaugeColor(for: projection.primary?.usedPercentage, config: config),
                tooltip: projection.tooltip + (usage.workspaceLimitNotice.map { "\n\($0)" } ?? "")
                    + staleNote(error: error, hasAuthError: hasAuthError, isStale: isStale))
        }

        let hasPrimary = usage.hasSessionWindow
        let primary = usage.sessionPercentage
        let weekly = usage.weeklyWindow?.utilization
        let text = MenuBarQuotaProjection.legacyPercentageText(
            session: primary, weekly: weekly, hasSession: hasPrimary,
            display: config.percentageDisplay, basis: config.usageValueBasis)

        return MenuBarProviderStatus(
            text: text,
            color: gaugeColor(for: usage.gaugePercentage, config: config),
            tooltip: (config.gaugeSelection != nil
                ? projection.tooltip
                : MenuBarQuotaProjection.legacyTooltip(
                    session: hasPrimary ? primary : nil, weekly: weekly, basis: config.usageValueBasis))
                + (usage.workspaceLimitNotice.map { " · \($0)" } ?? "")
                + staleNote(error: error, hasAuthError: hasAuthError, isStale: isStale)
        )
    }
}
