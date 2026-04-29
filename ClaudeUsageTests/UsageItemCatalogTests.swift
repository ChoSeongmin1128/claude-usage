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

    func testGeminiCatalogSkipsMissingWindowsAndIncludesAccountWhenAvailable() {
        let catalog = GeminiItemCatalog()
        let sections = catalog.sections(
            from: catalog.defaultItems,
            context: makeContext(
                geminiUsage: GeminiUsageResponse(
                    accountEmail: "user@example.com",
                    accountPlan: "Gemini Advanced",
                    primaryWindow: GeminiUsageWindow(
                        label: "Pro",
                        modelID: "gemini-pro",
                        usedPercent: 24,
                        resetAtISO: nil
                    ),
                    secondaryWindow: nil,
                    tertiaryWindow: nil
                )
            )
        )

        XCTAssertEqual(sections.map(\.id), ["geminiPrimary", "geminiAccount"])
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
    geminiUsage: GeminiUsageResponse? = nil,
    antigravityUsage: AntigravityUsageResponse? = nil
) -> UsageItemContext {
    UsageItemContext(
        density: .standard,
        settings: AppSettings.shared,
        claudeUsage: claudeUsage,
        claudeOverage: claudeOverage,
        codexUsage: codexUsage,
        codexError: codexError,
        geminiUsage: geminiUsage,
        antigravityUsage: antigravityUsage
    )
}

private func usageTitles(from sections: [PopoverDisplaySection]) -> [String] {
    sections.compactMap { section in
        guard case let .usage(data) = section.payload else { return nil }
        return data.title
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
