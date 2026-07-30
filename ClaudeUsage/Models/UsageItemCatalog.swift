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
    /// 이 provider의 사용량 payload가 context에 실려 있는지 (미로딩/오류 상태 구분용)
    func hasPayload(context: UsageItemContext) -> Bool
}

extension UsageItemCatalog {
    var supportedIDs: [String] { defaultItems.map(\.id) }

    /// 저장된 항목 배열을 지원 ID 기준으로 정규화합니다.
    /// - 미지원 ID 제거
    /// - 중복 제거
    /// - 누락된 지원 ID는 기본 visibility로, 카탈로그 기본 순서상 위치에 삽입
    ///   (끝에 몰아붙이면 새 항목이 생길 때마다 사용자 목록 순서가 어긋난다)
    func normalized(_ items: [PopoverItemConfig]) -> [PopoverItemConfig] {
        let supported = Set(supportedIDs)

        var seen = Set<String>()
        var result: [PopoverItemConfig] = []
        result.reserveCapacity(defaultItems.count)

        for item in items {
            guard supported.contains(item.id), !seen.contains(item.id) else { continue }
            seen.insert(item.id)
            result.append(item)
        }

        for (defaultIndex, config) in defaultItems.enumerated() where !seen.contains(config.id) {
            // 기본 순서상 이 항목보다 앞에 오는 항목들 중, 사용자 목록에 존재하는
            // 마지막 항목 바로 뒤에 삽입한다.
            let precedingIDs = Set(defaultItems[..<defaultIndex].map(\.id))
            let insertIndex = result.lastIndex(where: { precedingIDs.contains($0.id) }).map { $0 + 1 } ?? 0
            result.insert(PopoverItemConfig(id: config.id, visible: config.visible), at: insertIndex)
            seen.insert(config.id)
        }

        return result.isEmpty ? defaultItems : result
    }

    /// 프로바이더 데이터는 정상 수신됐는데 표시할 내용이 없는 항목 ID 목록.
    /// 설정 UI가 "지금 플랜/응답에는 이 항목이 없다"는 안내를 붙이는 데 사용한다.
    func unavailableItemIDs(context: UsageItemContext) -> Set<String> {
        guard hasPayload(context: context) else { return [] }
        return Set(supportedIDs.filter { expandedSections(for: $0, context: context).isEmpty })
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
    ]

    static func catalog(
        for service: PopoverService
    ) -> (any UsageItemCatalog)? {
        switch service {
        case .claude: return ClaudeItemCatalog()
        case .codex: return CodexItemCatalog()
        case .antigravity: return nil
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

    func hasPayload(context: UsageItemContext) -> Bool {
        context.claudeUsage != nil
    }

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

    /// 일부 항목은 1:N으로 확장됩니다 (예: modelUsage → 모델별 주간 한도 N개).
    /// 기본 `section(for:)`로 처리 불가능한 경우 이 함수가 섹션 배열을 생성합니다.
    func expandedSections(for itemID: String, context: UsageItemContext) -> [PopoverDisplaySection] {
        switch itemID {
        case "modelUsage":
            guard let usage = context.claudeUsage else { return [] }
            // limits[] 기반 동적 목록 — Fable 등 새 모델 스코프 한도가 생겨도 코드 수정 없이 표시됩니다.
            // 제목은 모델명만 (긴 이름 잘림 방지 + Codex 모델 행과 동일 규칙).
            return usage.modelWeeklyWindows.map { window in
                PopoverDisplaySection(
                    id: "modelUsage-\(window.slug)",
                    kind: .usage,
                    importance: .primary,
                    payload: .usage(
                        PopoverUsageSectionData(
                            title: window.modelName,
                            compactLabel: Self.modelCompactLabel(for: window),
                            percentage: window.utilization,
                            resetAt: window.resetsAt,
                            isWeekly: true,
                            timeFormatStyle: context.settings.timeFormat
                        )
                    )
                )
            }
        default:
            if let single = section(for: itemID, context: context) {
                return [single]
            }
            return []
        }
    }

    private static func modelCompactLabel(for window: ClaudeModelWeeklyWindow) -> String {
        if window.slug.contains("sonnet") { return "소넷" }
        return window.modelName
    }
}

// MARK: - Codex

struct CodexItemCatalog: UsageItemCatalog {
    let providerID = PopoverService.codex.rawValue

    func hasPayload(context: UsageItemContext) -> Bool {
        context.codexUsage != nil
    }

    let defaultItems: [PopoverItemConfig] = [
        PopoverItemConfig(id: "codexPrimary", visible: true),
        PopoverItemConfig(id: "codexSecondary", visible: true),
        PopoverItemConfig(id: "codexModelLimits", visible: true),
        PopoverItemConfig(id: "codexResetCredits", visible: true),
        PopoverItemConfig(id: "codexCredits", visible: true),
    ]

    func displayName(for itemID: String) -> String? {
        switch itemID {
        case "codexPrimary": return "Codex 현재"
        case "codexSecondary": return "Codex 주간"
        case "codexModelLimits": return "Codex 모델별 한도"
        case "codexResetCredits": return "Codex 한도 초기화 크레딧"
        case "codexCredits": return "Codex 크레딧"
        default: return nil
        }
    }

    /// codexModelLimits 는 additional_rate_limits 항목 수만큼 1:N 확장됩니다.
    func expandedSections(for itemID: String, context: UsageItemContext) -> [PopoverDisplaySection] {
        switch itemID {
        case "codexModelLimits":
            guard let usage = context.codexUsage else { return [] }
            return usage.additionalRateLimits.compactMap { limit in
                guard let window = limit.window,
                      let name = limit.limitName?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty else { return nil }
                // 제목은 모델명만 — 실제 모델명이 길어 접미사를 붙이면 잘린다.
                // 주간 여부는 아래 "갱신 예상" 줄의 주간 포맷이 전달한다.
                return PopoverDisplaySection(
                    id: "codexModelLimit-\(name)",
                    kind: .usage,
                    importance: .primary,
                    payload: .usage(
                        PopoverUsageSectionData(
                            title: name,
                            compactLabel: name,
                            percentage: window.utilization,
                            resetAt: window.resetAtISO,
                            isWeekly: (window.limitWindowSeconds ?? 0) >= 24 * 3600,
                            timeFormatStyle: context.settings.codexTimeFormat
                        )
                    )
                )
            }
        default:
            if let single = section(for: itemID, context: context) {
                return [single]
            }
            return []
        }
    }

    func section(for itemID: String, context: UsageItemContext) -> PopoverDisplaySection? {
        switch itemID {
        case "codexPrimary":
            // 위치(primary/secondary)가 아니라 창 길이로 분류한다 —
            // 2026-07 개편으로 주간 창이 primary 자리에 오기 때문.
            if let window = context.codexUsage?.sessionWindow {
                return PopoverDisplaySection(
                    id: "codexPrimary",
                    kind: .usage,
                    importance: .primary,
                    payload: .usage(
                        PopoverUsageSectionData(
                            title: window.adaptiveTitle(expectedSeconds: 5 * 3600, fallback: "현재 세션"),
                            compactLabel: window.adaptiveCompactLabel(expectedSeconds: 5 * 3600, fallback: "현재"),
                            percentage: window.utilization,
                            resetAt: window.resetAtISO,
                            isWeekly: false,
                            timeFormatStyle: context.settings.codexTimeFormat
                        )
                    )
                )
            } else if context.codexUsage != nil {
                // 사용량 응답은 정상인데 세션 성격 창이 없는 경우(주간 전용 개편) — 행을 숨긴다.
                return nil
            } else {
                return PopoverDisplaySection(
                    id: "codexPrimary-status",
                    kind: .status,
                    importance: .primary,
                    payload: .status(PopoverStatusSectionData(title: "현재 세션", error: context.codexError))
                )
            }

        case "codexSecondary":
            if let window = context.codexUsage?.weeklyWindow {
                return PopoverDisplaySection(
                    id: "codexSecondary",
                    kind: .usage,
                    importance: .primary,
                    payload: .usage(
                        PopoverUsageSectionData(
                            title: window.adaptiveTitle(expectedSeconds: 7 * 24 * 3600, fallback: "주간 한도"),
                            compactLabel: window.adaptiveCompactLabel(expectedSeconds: 7 * 24 * 3600, fallback: "주간"),
                            percentage: window.utilization,
                            resetAt: window.resetAtISO,
                            isWeekly: true,
                            timeFormatStyle: context.settings.codexTimeFormat
                        )
                    )
                )
            } else if context.codexUsage != nil {
                // 주간 성격 창 자체가 없는 응답 — 오류가 아니라 미제공이므로 행을 숨긴다.
                return nil
            } else {
                return PopoverDisplaySection(
                    id: "codexSecondary-status",
                    kind: .status,
                    importance: .primary,
                    payload: .status(PopoverStatusSectionData(title: "주간 한도", error: context.codexError))
                )
            }

        case "codexResetCredits":
            // 보유 크레딧이 있을 때만 표시 — 0개일 때는 노이즈라 숨긴다.
            guard let resetCredits = context.codexUsage?.resetCredits else { return nil }
            let availableCount = resetCredits.availableCount()
            guard availableCount > 0 else { return nil }
            return PopoverDisplaySection(
                id: "codexResetCredits",
                kind: .resetCredits,
                importance: .primary,
                payload: .resetCredits(
                    PopoverResetCreditsSectionData(
                        availableCount: availableCount,
                        nextExpiresAtISO: resetCredits.nextExpiringAvailable()?.expiresAtISO,
                        timeFormatStyle: context.settings.codexTimeFormat
                    )
                )
            )

        case "codexCredits":
            if let credits = context.codexUsage?.credits {
                // 크레딧을 실제로 쓰는 계정에서만 표시 — has_credits=false, 잔액 0 이면
                // "$0.00" 은 정보가 아니라 노이즈다. (실계정 응답 기준)
                let balance = credits.balance ?? 0
                guard credits.unlimited || credits.hasCredits || balance > 0 else { return nil }
                return PopoverDisplaySection(
                    id: "codexCredits",
                    kind: .credits,
                    importance: .primary,
                    payload: .credits(PopoverCreditsSectionData(credits: credits))
                )
            } else if context.codexUsage != nil {
                // 사용량 응답에 크레딧 필드 자체가 없으면 미제공 — 행을 숨긴다.
                return nil
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
