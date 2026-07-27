import XCTest
@testable import ClaudeUsage

@MainActor
final class UsageItemCatalogTests: XCTestCase {
    func testClaudeCatalogNormalizedKeepsFirstSupportedEntriesAndAppendsMissingDefaults() {
        let catalog = ClaudeItemCatalog()

        let normalized = catalog.normalized(
            [
                PopoverItemConfig(id: "weeklyLimit", visible: false),
                PopoverItemConfig(id: "unknown", visible: true),
                PopoverItemConfig(id: "weeklyLimit", visible: true),
                PopoverItemConfig(id: "currentSession", visible: true),
            ]
        )

        XCTAssertEqual(
            normalized,
            [
                PopoverItemConfig(id: "weeklyLimit", visible: false),
                PopoverItemConfig(id: "currentSession", visible: true),
                PopoverItemConfig(id: "modelUsage", visible: true),
                PopoverItemConfig(id: "overageUsage", visible: true),
            ]
        )
    }

    func testClaudeCatalogRemovesLegacyActiveAccountPopoverItem() {
        let catalog = ClaudeItemCatalog()

        let normalized = catalog.normalized(
            [
                PopoverItemConfig(id: "activeAccount", visible: true),
                PopoverItemConfig(id: "currentSession", visible: true),
            ]
        )

        XCTAssertFalse(normalized.contains { $0.id == "activeAccount" })
        XCTAssertEqual(
            normalized.map(\.id),
            ["currentSession", "weeklyLimit", "modelUsage", "overageUsage"]
        )
    }

    func testClaudeModelUsageExpansionBuildsSonnetAndOpusSections() {
        let catalog = ClaudeItemCatalog()
        let sections = catalog.expandedSections(
            for: "modelUsage",
            context: makeContext(
                claudeUsage: ClaudeUsageResponse(
                    fiveHour: UsageWindow(utilization: 12, resetsAt: nil),
                    sevenDay: nil,
                    sevenDaySonnet: UsageWindow(utilization: 61, resetsAt: "2026-04-18T12:00:00Z"),
                    sevenDayOpus: UsageWindow(utilization: 33, resetsAt: "2026-04-19T12:00:00Z")
                )
            )
        )

        XCTAssertEqual(sections.map(\.id), ["modelUsage-sonnet", "modelUsage-opus"])
        XCTAssertEqual(sections.map(\.kind), [.usage, .usage])
        XCTAssertEqual(usageTitles(from: sections), ["Sonnet", "Opus"])
    }

    func testClaudeOverageSectionIsShownWhenExtraUsageEnabled() {
        let catalog = ClaudeItemCatalog()
        let section = catalog.section(
            for: "overageUsage",
            context: makeContext(
                claudeOverage: OverageSpendLimitResponse(
                    monthlyCreditLimitCents: 10_000,
                    usedCreditsCents: 2_500,
                    isEnabled: true,
                    outOfCredits: false,
                    currency: "USD"
                )
            )
        )

        XCTAssertEqual(section?.id, "overageUsage")
        XCTAssertEqual(section?.kind, .overage)
    }

    func testClaudeOverageSummaryDoesNotInferBalanceFromMonthlyLimit() {
        let overage = OverageSpendLimitResponse(
            monthlyCreditLimitCents: 10_000,
            usedCreditsCents: 0,
            isEnabled: true,
            outOfCredits: false,
            currency: "USD"
        )

        XCTAssertEqual(overage.formattedUsageLimitSummary, "$0.00 사용 / $100.00 한도")
        XCTAssertFalse(overage.formattedUsageLimitSummary.contains("잔액"))
    }

    func testClaudeOverageSectionIsHiddenWhenExtraUsageDisabled() {
        let catalog = ClaudeItemCatalog()
        let section = catalog.section(
            for: "overageUsage",
            context: makeContext(
                claudeOverage: OverageSpendLimitResponse(
                    monthlyCreditLimitCents: 0,
                    usedCreditsCents: 0,
                    isEnabled: false,
                    outOfCredits: false,
                    currency: "USD"
                )
            )
        )

        XCTAssertNil(section)
    }

    func testClaudeModelUsageExpansionIncludesScopedWeeklyFable() {
        let catalog = ClaudeItemCatalog()
        let sections = catalog.expandedSections(
            for: "modelUsage",
            context: makeContext(
                claudeUsage: ClaudeUsageResponse(
                    fiveHour: UsageWindow(utilization: 12, resetsAt: nil),
                    sevenDay: UsageWindow(utilization: 40, resetsAt: nil),
                    sevenDaySonnet: UsageWindow(utilization: 61, resetsAt: nil),
                    scopedLimits: [
                        ClaudeScopedLimit(kind: "weekly_scoped", percent: 27, modelName: "Fable"),
                        ClaudeScopedLimit(kind: "weekly_scoped", percent: 90, modelID: "all-models", modelName: "All models"),
                    ]
                )
            )
        )

        XCTAssertEqual(sections.map(\.id), ["modelUsage-fable", "modelUsage-sonnet"])
        XCTAssertEqual(usageTitles(from: sections), ["Fable", "Sonnet"])
        XCTAssertEqual(compactLabels(from: sections), ["Fable", "소넷"])
    }

    func testCodexCatalogNormalizedInsertsNewDefaultsAtCatalogPosition() {
        let catalog = CodexItemCatalog()
        // 모델별 한도/초기화 크레딧 항목이 생기기 전의 저장 목록
        let normalized = catalog.normalized([
            PopoverItemConfig(id: "codexPrimary", visible: true),
            PopoverItemConfig(id: "codexSecondary", visible: false),
            PopoverItemConfig(id: "codexCredits", visible: true),
        ])

        // 새 항목은 끝에 몰리지 않고 카탈로그 기본 순서상 위치에 삽입된다
        XCTAssertEqual(
            normalized.map(\.id),
            ["codexPrimary", "codexSecondary", "codexModelLimits", "codexResetCredits", "codexCredits"]
        )
        XCTAssertEqual(normalized.first { $0.id == "codexSecondary" }?.visible, false)
    }

    func testCodexCatalogMarksSessionItemUnavailableForWeeklyOnlyPlan() throws {
        let catalog = CodexItemCatalog()
        let usage = try decodeCodexUsage(
            """
            {
              "plan_type": "pro",
              "rate_limit": {
                "primary_window": { "used_percent": 12, "limit_window_seconds": 604800 },
                "secondary_window": null
              }
            }
            """
        )

        let unavailable = catalog.unavailableItemIDs(context: makeContext(codexUsage: usage))
        XCTAssertTrue(unavailable.contains("codexPrimary"))
        XCTAssertFalse(unavailable.contains("codexSecondary"))

        // 응답 자체가 없으면(로딩/오류) 미제공 판정을 하지 않는다
        XCTAssertTrue(catalog.unavailableItemIDs(context: makeContext()).isEmpty)
    }

    func testCodexCatalogRoutesWeeklyAsPrimaryResponseToWeeklyRow() throws {
        // 2026-07 실제 응답: 주간 창이 primary_window 자리에 오고 secondary 는 null.
        // "Codex 현재" 행은 숨고, 주간 창은 "Codex 주간" 항목으로 표시돼야 한다.
        let catalog = CodexItemCatalog()
        let usage = try decodeCodexUsage(
            """
            {
              "plan_type": "pro",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 12,
                  "limit_window_seconds": 604800,
                  "reset_at": 1785283490
                },
                "secondary_window": null
              }
            }
            """
        )
        let sections = catalog.sections(
            from: catalog.defaultItems,
            context: makeContext(codexUsage: usage)
        )

        XCTAssertFalse(sections.contains { $0.id.hasPrefix("codexPrimary") })
        let weekly = sections.first { $0.id == "codexSecondary" }
        XCTAssertNotNil(weekly)
        XCTAssertEqual(usageTitles(from: sections.filter { $0.id == "codexSecondary" }), ["주간 한도"])
    }

    func testCodexCatalogExpandsAdditionalModelLimits() throws {
        let catalog = CodexItemCatalog()
        let usage = try decodeCodexUsage(
            """
            {
              "rate_limit": {
                "primary_window": { "used_percent": 12, "limit_window_seconds": 604800 },
                "secondary_window": null
              },
              "additional_rate_limits": [
                {
                  "limit_name": "GPT-5.3-Codex-Spark",
                  "rate_limit": {
                    "primary_window": { "used_percent": 7, "limit_window_seconds": 604800 }
                  }
                }
              ]
            }
            """
        )
        let sections = catalog.sections(
            from: catalog.defaultItems,
            context: makeContext(codexUsage: usage)
        )

        XCTAssertTrue(sections.contains { $0.id == "codexModelLimit-GPT-5.3-Codex-Spark" })
        XCTAssertTrue(usageTitles(from: sections).contains("GPT-5.3-Codex-Spark"))
    }

    func testCodexCatalogShowsResetCreditsRowWhenAvailable() throws {
        let catalog = CodexItemCatalog()
        var usage = try decodeCodexUsage(
            """
            {
              "plan_type": "plus",
              "rate_limit": {
                "primary_window": { "used_percent": 4, "limit_window_seconds": 18000 },
                "secondary_window": { "used_percent": 63, "limit_window_seconds": 604800 }
              }
            }
            """
        )
        usage.resetCredits = CodexResetCreditsResponse(
            credits: [
                CodexResetCredit(id: "credit-1", status: "available", expiresAtISO: "2099-01-01T00:00:00Z"),
            ]
        )

        let sections = catalog.sections(
            from: catalog.defaultItems,
            context: makeContext(codexUsage: usage)
        )

        XCTAssertTrue(sections.contains { $0.id == "codexResetCredits" && $0.kind == .resetCredits })
    }

    func testCodexCatalogHidesResetCreditsRowWhenNoneAvailable() throws {
        let catalog = CodexItemCatalog()
        var usage = try decodeCodexUsage(
            """
            {
              "rate_limit": {
                "primary_window": { "used_percent": 4, "limit_window_seconds": 18000 }
              }
            }
            """
        )
        usage.resetCredits = CodexResetCreditsResponse(credits: [])

        let sections = catalog.sections(
            from: catalog.defaultItems,
            context: makeContext(codexUsage: usage)
        )

        XCTAssertFalse(sections.contains { $0.id == "codexResetCredits" })
    }

    func testCodexCatalogFallsBackToStatusSectionsWhenPayloadMissing() {
        let catalog = CodexItemCatalog()
        let sections = catalog.sections(
            from: catalog.defaultItems,
            context: makeContext(codexError: .networkError("offline"))
        )

        XCTAssertEqual(
            sections.map(\.id),
            ["codexPrimary-status", "codexSecondary-status", "codexCredits-status"]
        )
        XCTAssertEqual(sections.map(\.kind), [.status, .status, .status])
        XCTAssertEqual(statusTitles(from: sections), ["현재 세션", "주간 한도", "Codex 크레딧"])
    }

    /// AGY catalog는 팝오버 섹션을 만들지 않는다. 권위 항목 하나만 노출하고
    /// 구 ID는 지원하지 않는다.
    func testAntigravityCatalogExposesOnlyUsageLimitsItemAndBuildsNoSections() {
        let catalog = AntigravityItemCatalog()
        let context = makeContext()

        XCTAssertEqual(catalog.supportedIDs, [AntigravityItemCatalog.usageLimitsItemID])
        XCTAssertEqual(
            catalog.displayName(for: AntigravityItemCatalog.usageLimitsItemID),
            "사용량 한도"
        )
        XCTAssertNil(catalog.displayName(for: "antigravityModels"))
        XCTAssertNil(catalog.displayName(for: "antigravityAccount"))
        XCTAssertTrue(
            catalog.expandedSections(
                for: AntigravityItemCatalog.usageLimitsItemID,
                context: context
            ).isEmpty
        )
        XCTAssertTrue(catalog.unavailableItemIDs(context: context).isEmpty)
    }
}

@MainActor
private func makeContext(
    claudeUsage: ClaudeUsageResponse? = nil,
    claudeOverage: OverageSpendLimitResponse? = nil,
    codexUsage: CodexUsageResponse? = nil,
    codexError: APIError? = nil
) -> UsageItemContext {
    UsageItemContext(
        density: .standard,
        settings: AppSettings.shared,
        claudeUsage: claudeUsage,
        claudeOverage: claudeOverage,
        claudeAccounts: [],
        activeClaudeAccountID: nil,
        codexUsage: codexUsage,
        codexError: codexError
    )
}

private func decodeCodexUsage(_ json: String) throws -> CodexUsageResponse {
    try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
}

private func usageTitles(from sections: [PopoverDisplaySection]) -> [String] {
    sections.compactMap { section in
        guard case let .usage(data) = section.payload else { return nil }
        return data.title
    }
}

private func compactLabels(from sections: [PopoverDisplaySection]) -> [String] {
    sections.compactMap { section in
        guard case let .usage(data) = section.payload else { return nil }
        return data.compactLabel
    }
}

private func statusTitles(from sections: [PopoverDisplaySection]) -> [String] {
    sections.compactMap { section in
        guard case let .status(data) = section.payload else { return nil }
        return data.title
    }
}

private func accountEmails(from sections: [PopoverDisplaySection]) -> [String] {
    sections.compactMap { section in
        guard case let .account(data) = section.payload else { return nil }
        return data.email
    }
}
