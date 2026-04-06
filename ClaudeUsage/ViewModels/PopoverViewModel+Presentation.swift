import Foundation

extension PopoverViewModel {
    struct LayoutResult {
        let spec: PopoverLayoutSpec
        let sections: [PopoverDisplaySection]
    }

    func layoutWithSections(for service: PopoverService, settings: AppSettings) -> LayoutResult {
        let density: PopoverDensity = settings.isPopoverCompact(for: service.providerKind) ? .compact : .standard
        let phase = contentPhase(for: service, settings: settings)
        let sections = displaySections(for: service, density: density, settings: settings)
        let hasContent = runtimeServiceState(for: service, settings: settings).hasContent
        let rowCount = phase == .content ? max(sections.count, hasContent ? 1 : 0) : 0
        let spec = PopoverLayoutMetrics.layoutSpec(
            density: density,
            phase: phase,
            sections: sections,
            rowCount: rowCount
        )
        return LayoutResult(spec: spec, sections: sections)
    }

    func layoutSpec(for service: PopoverService, settings: AppSettings) -> PopoverLayoutSpec {
        layoutWithSections(for: service, settings: settings).spec
    }

    func contentPhase(for service: PopoverService, settings: AppSettings) -> PopoverContentPhase {
        let runtimeState = runtimeServiceState(for: service, settings: settings)
        if runtimeState.isAuthRequired {
            return .authRequired
        }
        if runtimeState.isLoading && !runtimeState.hasContent {
            return .loading
        }
        if runtimeState.error != nil && !runtimeState.hasContent {
            return .error
        }
        if runtimeState.hasContent {
            return .content
        }
        return .empty
    }

    func displaySections(
        for service: PopoverService,
        density: PopoverDensity,
        settings: AppSettings
    ) -> [PopoverDisplaySection] {
        let sections: [PopoverDisplaySection]
        switch service {
        case .claude:
            sections = claudeDisplaySections(density: density, settings: settings)
        case .codex:
            sections = codexDisplaySections(density: density, settings: settings)
        case .gemini:
            sections = geminiDisplaySections()
        case .antigravity:
            sections = antigravityDisplaySections()
        }

        if density == .compact {
            return sections.filter { $0.importance == .primary }
        }
        return sections
    }

    private func claudeDisplaySections(
        density: PopoverDensity,
        settings: AppSettings
    ) -> [PopoverDisplaySection] {
        let visibleItemIDs = (density == .compact ? settings.effectiveCompactItems : settings.popoverItems)
            .filter(\.visible)
            .map(\.id)
        var sections: [PopoverDisplaySection] = []

        for itemID in visibleItemIDs {
            switch itemID {
            case "currentSession":
                if let usage = claudeUsage {
                    sections.append(
                        PopoverDisplaySection(
                            id: "currentSession",
                            kind: .usage,
                            importance: .primary,
                            payload: .usage(
                                PopoverUsageSectionData(
                                    systemIcon: "gauge.medium",
                                    title: "현재 세션",
                                    compactLabel: "현재",
                                    percentage: usage.fiveHour.utilization,
                                    resetAt: usage.fiveHour.resetsAt,
                                    isWeekly: false,
                                    timeFormatStyle: settings.timeFormat
                                )
                            )
                        )
                    )
                }
            case "weeklyLimit":
                if let sevenDay = claudeUsage?.sevenDay {
                    sections.append(
                        PopoverDisplaySection(
                            id: "weeklyLimit",
                            kind: .usage,
                            importance: .primary,
                            payload: .usage(
                                PopoverUsageSectionData(
                                    systemIcon: "calendar",
                                    title: "주간 한도",
                                    compactLabel: "주간",
                                    percentage: sevenDay.utilization,
                                    resetAt: sevenDay.resetsAt,
                                    isWeekly: true,
                                    timeFormatStyle: settings.timeFormat
                                )
                            )
                        )
                    )
                }
            case "modelUsage":
                if let sonnet = claudeUsage?.sevenDaySonnet {
                    sections.append(
                        PopoverDisplaySection(
                            id: "modelUsage-sonnet",
                            kind: .usage,
                            importance: .primary,
                            payload: .usage(
                                PopoverUsageSectionData(
                                    systemIcon: "bolt.fill",
                                    title: "Sonnet (주간)",
                                    compactLabel: "소넷",
                                    percentage: sonnet.utilization,
                                    resetAt: sonnet.resetsAt,
                                    isWeekly: true,
                                    timeFormatStyle: settings.timeFormat
                                )
                            )
                        )
                    )
                }
                if let opus = claudeUsage?.sevenDayOpus {
                    sections.append(
                        PopoverDisplaySection(
                            id: "modelUsage-opus",
                            kind: .usage,
                            importance: .primary,
                            payload: .usage(
                                PopoverUsageSectionData(
                                    systemIcon: "diamond.fill",
                                    title: "Opus (주간)",
                                    compactLabel: "Opus",
                                    percentage: opus.utilization,
                                    resetAt: opus.resetsAt,
                                    isWeekly: true,
                                    timeFormatStyle: settings.timeFormat
                                )
                            )
                        )
                    )
                }
            case "overageUsage":
                if let overage, overage.isEnabled {
                    sections.append(
                        PopoverDisplaySection(
                            id: "overageUsage",
                            kind: .overage,
                            importance: .primary,
                            payload: .overage(PopoverOverageSectionData(overage: overage))
                        )
                    )
                }
            default:
                break
            }
        }

        return sections
    }

    private func codexDisplaySections(
        density: PopoverDensity,
        settings: AppSettings
    ) -> [PopoverDisplaySection] {
        let visibleItemIDs = (density == .compact ? settings.effectiveCompactCodexItems : settings.codexPopoverItems)
            .filter(\.visible)
            .map(\.id)
        let codexError = snapshot(for: .codex)?.error
        var sections: [PopoverDisplaySection] = []

        for itemID in visibleItemIDs {
            switch itemID {
            case "codexPrimary":
                if let window = codexUsage?.rateLimit?.primaryWindow {
                    sections.append(
                        PopoverDisplaySection(
                            id: "codexPrimary",
                            kind: .usage,
                            importance: .primary,
                            payload: .usage(
                                PopoverUsageSectionData(
                                    systemIcon: "bubble.left.and.bubble.right",
                                    title: "현재 세션",
                                    compactLabel: "현재",
                                    percentage: window.utilization,
                                    resetAt: window.resetAtISO,
                                    isWeekly: false,
                                    timeFormatStyle: settings.codexTimeFormat
                                )
                            )
                        )
                    )
                } else {
                    sections.append(
                        PopoverDisplaySection(
                            id: "codexPrimary-status",
                            kind: .status,
                            importance: .primary,
                            payload: .status(PopoverStatusSectionData(title: "현재 세션", error: codexError))
                        )
                    )
                }
            case "codexSecondary":
                if let window = codexUsage?.rateLimit?.secondaryWindow {
                    sections.append(
                        PopoverDisplaySection(
                            id: "codexSecondary",
                            kind: .usage,
                            importance: .primary,
                            payload: .usage(
                                PopoverUsageSectionData(
                                    systemIcon: "calendar.badge.clock",
                                    title: "주간 한도",
                                    compactLabel: "주간",
                                    percentage: window.utilization,
                                    resetAt: window.resetAtISO,
                                    isWeekly: true,
                                    timeFormatStyle: settings.codexTimeFormat
                                )
                            )
                        )
                    )
                } else {
                    sections.append(
                        PopoverDisplaySection(
                            id: "codexSecondary-status",
                            kind: .status,
                            importance: .primary,
                            payload: .status(PopoverStatusSectionData(title: "주간 한도", error: codexError))
                        )
                    )
                }
            case "codexCredits":
                if let credits = codexUsage?.credits {
                    sections.append(
                        PopoverDisplaySection(
                            id: "codexCredits",
                            kind: .credits,
                            importance: .primary,
                            payload: .credits(PopoverCreditsSectionData(credits: credits))
                        )
                    )
                } else {
                    sections.append(
                        PopoverDisplaySection(
                            id: "codexCredits-status",
                            kind: .status,
                            importance: .primary,
                            payload: .status(PopoverStatusSectionData(title: "Codex 크레딧", error: codexError))
                        )
                    )
                }
            default:
                break
            }
        }

        return sections
    }

    private func geminiDisplaySections() -> [PopoverDisplaySection] {
        var sections: [PopoverDisplaySection] = []

        if let primary = geminiUsage?.primaryWindow {
            sections.append(
                PopoverDisplaySection(
                    id: "gemini-primary",
                    kind: .usage,
                    importance: .primary,
                    payload: .usage(
                        PopoverUsageSectionData(
                            systemIcon: "sparkles",
                            title: primary.label,
                            compactLabel: primary.label,
                            percentage: primary.usedPercent,
                            resetAt: primary.resetAtISO,
                            isWeekly: false,
                            timeFormatStyle: AppSettings.shared.timeFormat
                        )
                    )
                )
            )
        }

        if let secondary = geminiUsage?.secondaryWindow {
            sections.append(
                PopoverDisplaySection(
                    id: "gemini-secondary",
                    kind: .usage,
                    importance: .primary,
                    payload: .usage(
                        PopoverUsageSectionData(
                            systemIcon: "bolt.horizontal.circle",
                            title: secondary.label,
                            compactLabel: secondary.label,
                            percentage: secondary.usedPercent,
                            resetAt: secondary.resetAtISO,
                            isWeekly: true,
                            timeFormatStyle: AppSettings.shared.timeFormat
                        )
                    )
                )
            )
        }

        if let tertiary = geminiUsage?.tertiaryWindow {
            sections.append(
                PopoverDisplaySection(
                    id: "gemini-tertiary",
                    kind: .usage,
                    importance: .primary,
                    payload: .usage(
                        PopoverUsageSectionData(
                            systemIcon: "circle.hexagongrid",
                            title: tertiary.label,
                            compactLabel: tertiary.label,
                            percentage: tertiary.usedPercent,
                            resetAt: tertiary.resetAtISO,
                            isWeekly: true,
                            timeFormatStyle: AppSettings.shared.timeFormat
                        )
                    )
                )
            )
        }

        if let usage = geminiUsage,
           usage.accountEmail != nil || usage.accountPlan != nil {
            sections.append(
                PopoverDisplaySection(
                    id: "gemini-account",
                    kind: .account,
                    importance: .secondary,
                    payload: .account(
                        PopoverAccountSectionData(
                            title: "계정 정보",
                            email: usage.accountEmail,
                            plan: usage.accountPlan,
                            systemIcon: "person.crop.circle"
                        )
                    )
                )
            )
        }

        return sections
    }

    private func antigravityDisplaySections() -> [PopoverDisplaySection] {
        var sections: [PopoverDisplaySection] = []

        if let primary = antigravityUsage?.primaryWindow {
            sections.append(
                PopoverDisplaySection(
                    id: "antigravity-primary",
                    kind: .usage,
                    importance: .primary,
                    payload: .usage(
                        PopoverUsageSectionData(
                            systemIcon: "brain",
                            title: primary.label,
                            compactLabel: primary.label,
                            percentage: primary.usedPercent,
                            resetAt: primary.resetAtISO,
                            isWeekly: false,
                            timeFormatStyle: AppSettings.shared.timeFormat
                        )
                    )
                )
            )
        }

        if let secondary = antigravityUsage?.secondaryWindow {
            sections.append(
                PopoverDisplaySection(
                    id: "antigravity-secondary",
                    kind: .usage,
                    importance: .primary,
                    payload: .usage(
                        PopoverUsageSectionData(
                            systemIcon: "sparkles",
                            title: secondary.label,
                            compactLabel: secondary.label,
                            percentage: secondary.usedPercent,
                            resetAt: secondary.resetAtISO,
                            isWeekly: true,
                            timeFormatStyle: AppSettings.shared.timeFormat
                        )
                    )
                )
            )
        }

        if let tertiary = antigravityUsage?.tertiaryWindow {
            sections.append(
                PopoverDisplaySection(
                    id: "antigravity-tertiary",
                    kind: .usage,
                    importance: .primary,
                    payload: .usage(
                        PopoverUsageSectionData(
                            systemIcon: "bolt.horizontal.circle",
                            title: tertiary.label,
                            compactLabel: tertiary.label,
                            percentage: tertiary.usedPercent,
                            resetAt: tertiary.resetAtISO,
                            isWeekly: true,
                            timeFormatStyle: AppSettings.shared.timeFormat
                        )
                    )
                )
            )
        }

        if let usage = antigravityUsage,
           usage.accountEmail != nil || usage.accountPlan != nil {
            sections.append(
                PopoverDisplaySection(
                    id: "antigravity-account",
                    kind: .account,
                    importance: .secondary,
                    payload: .account(
                        PopoverAccountSectionData(
                            title: "계정 정보",
                            email: usage.accountEmail,
                            plan: usage.accountPlan,
                            systemIcon: "person.crop.circle"
                        )
                    )
                )
            )
        }

        return sections
    }
}
