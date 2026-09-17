import XCTest
@testable import ClaudeUsage

final class UsageLimitCatalogTests: XCTestCase {
    func testClaudeModelIdentitySurvivesLabelsOrderAndResetChanges() throws {
        let first = claude([model("fable-v1", "Fable"), model("other", "Other")])
        let next = claude([model("other", "Renamed"), model("fable-v1", "New name", reset: "2030-01-01T00:00:00Z")])
        XCTAssertEqual(Set(first.map(\.id)), Set(next.map(\.id)))
        XCTAssertEqual(first.count, 3)
        XCTAssertTrue(first.allSatisfy(\.canNotify))
        XCTAssertEqual(first.last?.periodSeconds, 604_800)
    }

    func testLegacyModelFallbackDoesNotDuplicateAnOpaqueNewIdentifier() {
        let usage = ClaudeUsageResponse(
            fiveHour: .init(utilization: 10, resetsAt: nil), sevenDay: nil,
            sevenDaySonnet: .init(utilization: 20, resetsAt: nil),
            scopedLimits: [model("opaque-123", "Sonnet")])
        let limits = UsageLimitCatalog.claude(usage)
        XCTAssertEqual(limits.count, 2)
        XCTAssertEqual(limits[1].scope, "model:opaque-123")
    }

    func testMissingAndConflictingModelIdentitiesCannotNotify() {
        let limits = claude([model(nil, "Fable"), model("same", "First"), model("same", "Second")])
        XCTAssertEqual(limits.count, 3)
        XCTAssertFalse(limits[1].isIdentifiable)
        XCTAssertNotNil(limits[1].usedPercentage)  // Still display readable quota.
        XCTAssertFalse(limits[2].canNotify)
        XCTAssertNil(limits[2].usedPercentage)
        XCTAssertTrue(limits[2].title.contains("충돌"))
    }

    func testRawIDsDoNotCollapseAfterSlugSanitizing() {
        let limits = claude([model("a.b", "Same name"), model("a-b", "Same name")])
        XCTAssertEqual(Set(limits.map(\.id)).count, 3)
        XCTAssertTrue(limits.allSatisfy(\.canNotify))
    }

    func testCodexUsesEveryActualWindowWithoutPlanOrModelWhitelist() throws {
        let usage = try codex(
            """
            {"plan_type":"future-plan", "rate_limit":{"primary_window":{"used_percent":21,"limit_window_seconds":604800}},
             "additional_rate_limits":[{"metered_feature":"new-feature","limit_name":"Future model","rate_limit":{
             "primary_window":{"used_percent":30,"limit_window_seconds":18000},
             "secondary_window":{"used_percent":40,"limit_window_seconds":604800}}}]}
            """)
        let limits = UsageLimitCatalog.codex(usage)
        XCTAssertEqual(limits.map(\.title), ["주간", "Future model · 5시간", "Future model · 주간"])
        XCTAssertEqual(Set(limits.map(\.id)).count, 3)
        XCTAssertEqual(limits.map(\.usedPercentage), [21, 30, 40])
        XCTAssertTrue(limits.allSatisfy(\.canNotify))
    }

    func testCodexPeriodIdentitySurvivesPrimarySecondaryReordering() throws {
        let a = UsageLimitCatalog.codex(
            try codex(
                """
                {"rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":18000},"secondary_window":{"used_percent":50,"limit_window_seconds":604800}}}
                """))
        let b = UsageLimitCatalog.codex(
            try codex(
                """
                {"rate_limit":{"secondary_window":{"used_percent":22,"limit_window_seconds":18000},"primary_window":{"used_percent":55,"limit_window_seconds":604800}}}
                """))
        XCTAssertEqual(Set(a.map(\.id)), Set(b.map(\.id)))
    }

    func testMissingPeriodIsNotGuessedAndMissingFeatureCannotNotify() throws {
        let limits = UsageLimitCatalog.codex(
            try codex(
                """
                {"rate_limit":{"primary_window":{"used_percent":20}},"additional_rate_limits":[{"limit_name":"Display only","rate_limit":{"primary_window":{"used_percent":22,"limit_window_seconds":604800}}}]}
                """))
        XCTAssertNil(limits[0].periodSeconds)
        XCTAssertTrue(limits[0].title.contains("주기 미제공"))
        XCTAssertFalse(limits[1].canNotify)
    }

    func testCreditsAndResetCreditsAreNotNotificationTargets() throws {
        var usage = try codex(
            """
            {"credits":{"has_credits":true,"unlimited":false,"balance":"100"},"additional_rate_limits":[]}
            """)
        usage.resetCredits = .init(credits: [
            .init(id: "credit", status: "available", expiresAtISO: "2099-01-01T00:00:00Z")
        ])
        XCTAssertTrue(UsageLimitCatalog.codex(usage).isEmpty)
    }

    func testInvalidAndDuplicatePeriodsAreNotEligible() throws {
        let limits = UsageLimitCatalog.codex(
            try codex(
                """
                {"rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":604800},"secondary_window":{"used_percent":50,"limit_window_seconds":604800}},"additional_rate_limits":[{"metered_feature":"broken","rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":-1}}}]}
                """))
        XCTAssertEqual(limits.count, 2)
        XCTAssertTrue(limits.allSatisfy { !$0.canNotify })
        let invalid = UsageLimitCatalog.claude(.init(fiveHour: .init(utilization: .nan, resetsAt: nil), sevenDay: nil))
        XCTAssertFalse(invalid[0].canNotify)
    }

    private func claude(_ models: [ClaudeScopedLimit]) -> [UsageLimit] {
        UsageLimitCatalog.claude(
            .init(fiveHour: .init(utilization: 20, resetsAt: nil), sevenDay: nil, scopedLimits: models))
    }
    private func model(_ id: String?, _ name: String, reset: String? = nil) -> ClaudeScopedLimit {
        .init(kind: "weekly_scoped", percent: 30, resetsAt: reset, modelID: id, modelName: name)
    }
    private func codex(_ json: String) throws -> CodexUsageResponse {
        try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
    }
}
