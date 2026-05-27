import Foundation

// MARK: - Context

/// Catalog가 섹션을 만들 때 참조하는 provider-공통 데이터.
/// PopoverViewModel에서 조립해서 넘깁니다.
struct UsageItemContext {
    let density: PopoverDensity
    let settings: AppSettings

    let claudeUsage: ClaudeUsageResponse?
    let claudeOverage: OverageSpendLimitResponse?
    let claudeAccounts: [ClaudeAccount]
    let activeClaudeAccountID: String?

    let codexUsage: CodexUsageResponse?
    let codexError: APIError?

    let antigravityUsage: AntigravityUsageResponse?
}

// MARK: - Catalog protocol

/// Provider별 팝오버 항목 정의.
/// - `providerID`는 `PopoverService.rawValue`와 일치해야 합니다.
/// - `defaultItems`가 "내가 지원하는 항목 ID 전체 + 기본 visibility"를 선언합니다.
/// - `section(for:context:)`가 항목 ID를 화면 섹션으로 변환합니다.
protocol UsageItemCatalog {
    var providerID: String { get }
    var defaultItems: [PopoverItemConfig] { get }
    func displayName(for itemID: String) -> String?
    func section(for itemID: String, context: UsageItemContext) -> PopoverDisplaySection?
    func expandedSections(for itemID: String, context: UsageItemContext) -> [PopoverDisplaySection]
}

extension UsageItemCatalog {
    var supportedIDs: [String] { defaultItems.map(\.id) }

    /// 저장된 항목 배열을 지원 ID 기준으로 정규화합니다.
    /// - 미지원 ID 제거
    /// - 중복 제거
    /// - 누락된 지원 ID는 기본 visibility로 보충
    func normalized(_ items: [PopoverItemConfig]) -> [PopoverItemConfig] {
        let supported = Set(supportedIDs)
        let defaultVisible = Dictionary(uniqueKeysWithValues: defaultItems.map { ($0.id, $0.visible) })

        var seen = Set<String>()
        var result: [PopoverItemConfig] = []
        result.reserveCapacity(defaultItems.count)

        for item in items {
            guard supported.contains(item.id), !seen.contains(item.id) else { continue }
            seen.insert(item.id)
            result.append(item)
        }

        for id in supportedIDs where !seen.contains(id) {
            result.append(PopoverItemConfig(id: id, visible: defaultVisible[id] ?? true))
        }

        return result.isEmpty ? defaultItems : result
    }

    /// Visible 항목만 순서대로 섹션으로 변환.
    func sections(from items: [PopoverItemConfig], context: UsageItemContext) -> [PopoverDisplaySection] {
        items
            .filter(\.visible)
            .flatMap { expandedSections(for: $0.id, context: context) }
    }

    func expandedSections(for itemID: String, context: UsageItemContext) -> [PopoverDisplaySection] {
        if let single = section(for: itemID, context: context) {
            return [single]
        }
        return []
    }
}

// MARK: - Registry

enum UsageItemCatalogRegistry {
    static let all: [any UsageItemCatalog] = [
        ClaudeItemCatalog(),
        CodexItemCatalog(),
        AntigravityItemCatalog(),
    ]

    static func catalog(for service: PopoverService) -> any UsageItemCatalog {
        switch service {
        case .claude: return ClaudeItemCatalog()
        case .codex: return CodexItemCatalog()
        case .antigravity: return AntigravityItemCatalog()
        }
    }

    static func catalog(forProviderID id: String) -> (any UsageItemCatalog)? {
        guard let service = PopoverService(rawValue: id) else { return nil }
        return catalog(for: service)
    }
}

// MARK: - Claude

struct ClaudeItemCatalog: UsageItemCatalog {
    let providerID = PopoverService.claude.rawValue

    let defaultItems: [PopoverItemConfig] = [
        PopoverItemConfig(id: "currentSession", visible: true),
        PopoverItemConfig(id: "weeklyLimit", visible: true),
        PopoverItemConfig(id: "modelUsage", visible: true),
        PopoverItemConfig(id: "overageUsage", visible: true),
    ]

    func displayName(for itemID: String) -> String? {
        switch itemID {
        case "currentSession": return "현재 세션"
        case "weeklyLimit": return "주간 한도"
        case "modelUsage": return "모델별 주간 한도"
        case "overageUsage": return "추가 사용량"
        default: return nil
        }
    }

    func section(for itemID: String, context: UsageItemContext) -> PopoverDisplaySection? {
        switch itemID {
        case "currentSession":
            guard let usage = context.claudeUsage else { return nil }
            return PopoverDisplaySection(
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
                        timeFormatStyle: context.settings.timeFormat
                    )
                )
            )

        case "weeklyLimit":
            guard let sevenDay = context.claudeUsage?.sevenDay else { return nil }
            return PopoverDisplaySection(
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
                        timeFormatStyle: context.settings.timeFormat
                    )
                )
            )

        case "modelUsage":
            // modelUsage는 Sonnet/Opus 각각 섹션 2개를 생성하는 특수 케이스.
            // 여기서는 최상위 섹션만 반환하고, 추가 섹션은 expand로 처리.
            // 현재 구조상 섹션 1개만 반환해야 하므로 Sonnet을 primary로 둡니다.
            return nil // expandedSections(...)에서 처리

        case "overageUsage":
            guard let overage = context.claudeOverage, overage.isEnabled else { return nil }
            return PopoverDisplaySection(
                id: "overageUsage",
                kind: .overage,
                importance: .primary,
                payload: .overage(PopoverOverageSectionData(overage: overage))
            )

        default:
            return nil
        }
    }

    /// 일부 항목은 1:N으로 확장됩니다 (예: modelUsage → Sonnet + Opus 2개).
    /// 기본 `section(for:)`로 처리 불가능한 경우 이 함수가 섹션 배열을 생성합니다.
    func expandedSections(for itemID: String, context: UsageItemContext) -> [PopoverDisplaySection] {
        switch itemID {
        case "modelUsage":
            var out: [PopoverDisplaySection] = []
            if let sonnet = context.claudeUsage?.sevenDaySonnet {
                out.append(PopoverDisplaySection(
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
                            timeFormatStyle: context.settings.timeFormat
                        )
                    )
                ))
            }
            if let opus = context.claudeUsage?.sevenDayOpus {
                out.append(PopoverDisplaySection(
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
                            timeFormatStyle: context.settings.timeFormat
                        )
                    )
                ))
            }
            return out
        default:
            if let single = section(for: itemID, context: context) {
                return [single]
            }
            return []
        }
    }
}

// MARK: - Codex

struct CodexItemCatalog: UsageItemCatalog {
    let providerID = PopoverService.codex.rawValue

    let defaultItems: [PopoverItemConfig] = [
        PopoverItemConfig(id: "codexPrimary", visible: true),
        PopoverItemConfig(id: "codexSecondary", visible: true),
        PopoverItemConfig(id: "codexCredits", visible: true),
    ]

    func displayName(for itemID: String) -> String? {
        switch itemID {
        case "codexPrimary": return "Codex 현재"
        case "codexSecondary": return "Codex 주간"
        case "codexCredits": return "Codex 크레딧"
        default: return nil
        }
    }

    func section(for itemID: String, context: UsageItemContext) -> PopoverDisplaySection? {
        switch itemID {
        case "codexPrimary":
            if let window = context.codexUsage?.rateLimit?.primaryWindow {
                return PopoverDisplaySection(
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
                            timeFormatStyle: context.settings.codexTimeFormat
                        )
                    )
                )
            } else {
                return PopoverDisplaySection(
                    id: "codexPrimary-status",
                    kind: .status,
                    importance: .primary,
                    payload: .status(PopoverStatusSectionData(title: "현재 세션", error: context.codexError))
                )
            }

        case "codexSecondary":
            if let window = context.codexUsage?.rateLimit?.secondaryWindow {
                return PopoverDisplaySection(
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
                            timeFormatStyle: context.settings.codexTimeFormat
                        )
                    )
                )
            } else {
                return PopoverDisplaySection(
                    id: "codexSecondary-status",
                    kind: .status,
                    importance: .primary,
                    payload: .status(PopoverStatusSectionData(title: "주간 한도", error: context.codexError))
                )
            }

        case "codexCredits":
            if let credits = context.codexUsage?.credits {
                return PopoverDisplaySection(
                    id: "codexCredits",
                    kind: .credits,
                    importance: .primary,
                    payload: .credits(PopoverCreditsSectionData(credits: credits))
                )
            } else {
                return PopoverDisplaySection(
                    id: "codexCredits-status",
                    kind: .status,
                    importance: .primary,
                    payload: .status(PopoverStatusSectionData(title: "Codex 크레딧", error: context.codexError))
                )
            }

        default:
            return nil
        }
    }
}

private func windowedAccountSection(
    id: String,
    email: String?,
    plan: String?,
    icon: String
) -> PopoverDisplaySection? {
    guard email != nil || plan != nil else { return nil }
    return PopoverDisplaySection(
        id: id,
        kind: .account,
        importance: .secondary,
        payload: .account(
            PopoverAccountSectionData(
                title: "계정 정보",
                email: email,
                plan: plan,
                systemIcon: icon
            )
        )
    )
}

// MARK: - Antigravity

struct AntigravityItemCatalog: UsageItemCatalog {
    let providerID = PopoverService.antigravity.rawValue
    let defaultItems: [PopoverItemConfig] = [
        PopoverItemConfig(id: "antigravityModels", visible: true),
        PopoverItemConfig(id: "antigravityAccount", visible: false),
    ]

    fileprivate let accountIcon = "person.crop.circle"

    func displayName(for itemID: String) -> String? {
        switch itemID {
        case "antigravityModels":
            return "모델별 quota"
        case "antigravityAccount":
            return "Antigravity 계정 정보"
        default:
            return nil
        }
    }

    func section(for itemID: String, context: UsageItemContext) -> PopoverDisplaySection? {
        let usage = context.antigravityUsage
        switch itemID {
        case "antigravityAccount":
            return windowedAccountSection(
                id: itemID,
                email: usage?.accountEmail,
                plan: usage?.accountPlan,
                icon: accountIcon
            )
        default:
            return nil
        }
    }

    func expandedSections(for itemID: String, context: UsageItemContext) -> [PopoverDisplaySection] {
        switch itemID {
        case "antigravityModels":
            guard let usage = context.antigravityUsage else { return [] }
            return context.settings.visibleAntigravityModelWindows(from: usage.modelWindows).enumerated().map { index, window in
                PopoverDisplaySection(
                    id: "antigravityModel-\(index)",
                    kind: .usage,
                    importance: .primary,
                    payload: .usage(
                        PopoverUsageSectionData(
                            systemIcon: AntigravityUsageMapper.displayIcon(for: window),
                            title: window.label,
                            compactLabel: window.label,
                            percentage: window.usedPercent,
                            resetAt: window.resetAtISO,
                            isWeekly: false,
                            timeFormatStyle: context.settings.timeFormat
                        )
                    )
                )
            }
        default:
            return section(for: itemID, context: context).map { [$0] } ?? []
        }
    }
}
