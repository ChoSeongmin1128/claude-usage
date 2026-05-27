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
        XCTAssertEqual(usageTitles(from: sections), ["Sonnet (주간)", "Opus (주간)"])
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

    func testAntigravityCatalogSkipsAccountInfoByDefault() {
        let catalog = AntigravityItemCatalog()
        let sections = catalog.sections(
            from: catalog.defaultItems,
            context: makeContext(
                antigravityUsage: AntigravityUsageResponse(
                    accountEmail: "user@example.com",
                    accountPlan: "Workspace",
                    primaryWindow: AntigravityUsageWindow(
                        label: "Gemini 3.1 Pro (Low)",
                        modelID: "gemini-3.1-pro-low",
                        usedPercent: 24,
                        resetAtISO: nil
                    ),
                    secondaryWindow: nil,
                    tertiaryWindow: nil
                )
            )
        )

        XCTAssertEqual(sections.map(\.id), ["antigravityModel-0"])
        XCTAssertEqual(sections.map(\.kind), [.usage])
        XCTAssertTrue(accountEmails(from: sections).isEmpty)
    }

    func testAntigravityCatalogUsesExactCLIModelLabels() {
        let catalog = AntigravityItemCatalog()
        let sections = catalog.sections(
            from: catalog.defaultItems,
            context: makeContext(
                antigravityUsage: AntigravityUsageResponse(
                    accountEmail: nil,
                    accountPlan: nil,
                    primaryWindow: AntigravityUsageWindow(
                        label: "Gemini 3.1 Pro (Low)",
                        modelID: "models/gemini-2.5-pro",
                        usedPercent: 24,
                        resetAtISO: nil
                    ),
                    secondaryWindow: AntigravityUsageWindow(
                        label: "Gemini 3.5 Flash (Medium)",
                        modelID: "gemini-2.5-flash",
                        usedPercent: 11,
                        resetAtISO: nil
                    ),
                    tertiaryWindow: AntigravityUsageWindow(
                        label: "Claude Sonnet 4.6 (Thinking)",
                        modelID: "claude-sonnet-4.6-thinking",
                        usedPercent: 7,
                        resetAtISO: nil
                    )
                )
            )
        )

        XCTAssertEqual(
            usageTitles(from: sections),
            ["Gemini 3.1 Pro (Low)", "Gemini 3.5 Flash (Medium)", "Claude Sonnet 4.6 (Thinking)"]
        )
        XCTAssertEqual(compactLabels(from: sections), ["Gemini 3.1 Pro (Low)", "Gemini 3.5 Flash (Medium)", "Claude Sonnet 4.6 (Thinking)"])
    }

    func testAntigravityCatalogExpandsEveryModelQuotaWindow() {
        let catalog = AntigravityItemCatalog()
        let modelWindows = [
            AntigravityUsageWindow(label: "Gemini 3.5 Flash (Medium)", modelID: "gemini-3.5-flash-medium", usedPercent: 20, resetAtISO: nil),
            AntigravityUsageWindow(label: "Gemini 3.5 Flash (High)", modelID: "gemini-3.5-flash-high", usedPercent: 20, resetAtISO: nil),
            AntigravityUsageWindow(label: "Gemini 3.5 Flash (Low)", modelID: "gemini-3.5-flash-low", usedPercent: 20, resetAtISO: nil),
            AntigravityUsageWindow(label: "Claude Sonnet 4.6 (Thinking)", modelID: "claude-sonnet-4.6-thinking", usedPercent: 0, resetAtISO: nil),
            AntigravityUsageWindow(label: "GPT-OSS 120B (Medium)", modelID: "gpt-oss-120b-medium", usedPercent: 0, resetAtISO: nil),
        ]
        let sections = catalog.sections(
            from: catalog.defaultItems,
            context: makeContext(
                antigravityUsage: AntigravityUsageResponse(
                    accountEmail: nil,
                    accountPlan: nil,
                    modelWindows: modelWindows
                )
            )
        )

        XCTAssertEqual(sections.map(\.id), [
            "antigravityModel-0",
            "antigravityModel-1",
            "antigravityModel-2",
            "antigravityModel-3",
            "antigravityModel-4",
        ])
        XCTAssertEqual(usageTitles(from: sections), modelWindows.map(\.label))
    }

    func testAntigravityCatalogFiltersHiddenModelIDs() {
        let settings = AppSettings.shared
        let snapshot = settings.createSnapshot()
        defer { settings.restore(from: snapshot) }

        let catalog = AntigravityItemCatalog()
        let modelWindows = [
            AntigravityUsageWindow(label: "Gemini 3.5 Flash (Medium)", modelID: "gemini-3.5-flash-medium", usedPercent: 20, resetAtISO: nil),
            AntigravityUsageWindow(label: "Gemini 3.1 Pro (Low)", modelID: "gemini-3.1-pro-low", usedPercent: 24, resetAtISO: nil),
            AntigravityUsageWindow(label: "Claude Sonnet 4.6 (Thinking)", modelID: "claude-sonnet-4.6-thinking", usedPercent: 0, resetAtISO: nil),
        ]
        settings.setAntigravityModelVisible(false, modelID: "gemini-3.1-pro-low")

        let sections = catalog.sections(
            from: catalog.defaultItems,
            context: makeContext(
                antigravityUsage: AntigravityUsageResponse(
                    accountEmail: nil,
                    accountPlan: nil,
                    modelWindows: modelWindows
                )
            )
        )

        XCTAssertEqual(
            usageTitles(from: sections),
            ["Gemini 3.5 Flash (Medium)", "Claude Sonnet 4.6 (Thinking)"]
        )
    }

    func testAntigravityCatalogDisplayNamesAreOwnedByProviderPrefix() {
        XCTAssertEqual(PopoverItemConfig(id: "unknownPrimary", visible: true).displayName, "unknownPrimary")
        XCTAssertEqual(PopoverItemConfig(id: "antigravityPrimary", visible: true).displayName, "antigravityPrimary")
        XCTAssertEqual(PopoverItemConfig(id: "antigravityModels", visible: true).displayName, "모델별 quota")
        XCTAssertEqual(PopoverItemConfig(id: "antigravityAccount", visible: true).displayName, "Antigravity 계정 정보")
    }

    func testAntigravityUsageSummaryIsModelBased() {
        let usage = AntigravityUsageResponse(
            accountEmail: nil,
            accountPlan: nil,
            primaryWindow: AntigravityUsageWindow(
                label: "Gemini 3.1 Pro (Low)",
                modelID: "gemini-2.5-pro",
                usedPercent: 24.4,
                resetAtISO: nil
            ),
            secondaryWindow: AntigravityUsageWindow(
                label: "Gemini 3.5 Flash (Medium)",
                modelID: "gemini-2.5-flash",
                usedPercent: 11.6,
                resetAtISO: nil
            ),
            tertiaryWindow: AntigravityUsageWindow(
                label: "Claude Sonnet 4.6 (Thinking)",
                modelID: "claude-sonnet-4.6-thinking",
                usedPercent: 7.1,
                resetAtISO: nil
            )
        )

        XCTAssertEqual(usage.modelSummary(), "Gemini 3.1 Pro (Low) 24% · Gemini 3.5 Flash (Medium) 12% · Claude Sonnet 4.6 (Thinking) 7%")
        XCTAssertEqual(usage.modelSummary(separator: " / "), "Gemini 3.1 Pro (Low) 24% / Gemini 3.5 Flash (Medium) 12% / Claude Sonnet 4.6 (Thinking) 7%")
    }

    func testAntigravityCatalogIncludesAccountInfoWhenUserEnablesItem() {
        let catalog = AntigravityItemCatalog()
        let sections = catalog.sections(
            from: [
                PopoverItemConfig(id: "antigravityModels", visible: true),
                PopoverItemConfig(id: "antigravityAccount", visible: true),
            ],
            context: makeContext(
                antigravityUsage: AntigravityUsageResponse(
                    accountEmail: "user@example.com",
                    accountPlan: "Workspace",
                    primaryWindow: AntigravityUsageWindow(
                        label: "Gemini 3.1 Pro (Low)",
                        modelID: "gemini-3.1-pro-low",
                        usedPercent: 24,
                        resetAtISO: nil
                    ),
                    secondaryWindow: nil,
                    tertiaryWindow: nil
                )
            )
        )

        XCTAssertEqual(sections.map(\.id), ["antigravityModel-0", "antigravityAccount"])
        XCTAssertEqual(sections.map(\.kind), [.usage, .account])
        XCTAssertEqual(accountEmails(from: sections), ["user@example.com"])
    }
}

@MainActor
private func makeContext(
    claudeUsage: ClaudeUsageResponse? = nil,
    claudeOverage: OverageSpendLimitResponse? = nil,
    codexUsage: CodexUsageResponse? = nil,
    codexError: APIError? = nil,
    antigravityUsage: AntigravityUsageResponse? = nil
) -> UsageItemContext {
    UsageItemContext(
        density: .standard,
        settings: AppSettings.shared,
        claudeUsage: claudeUsage,
        claudeOverage: claudeOverage,
        claudeAccounts: [],
        activeClaudeAccountID: nil,
        codexUsage: codexUsage,
        codexError: codexError,
        antigravityUsage: antigravityUsage
    )
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
