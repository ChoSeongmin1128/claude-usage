import XCTest
@testable import ClaudeUsage

final class ResetCreditsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func iso(_ offset: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(offset))
    }

    private func claudeUsage(_ cedar: String) throws -> ClaudeUsageResponse {
        try JSONDecoder().decode(
            ClaudeUsageResponse.self,
            from: Data(#"{ "five_hour": { "utilization": 24, "resets_at": null }, "cedar_ember": \#(cedar) }"#.utf8))
    }

    func testClaudeGrantsBecomeSummaryWithScopeAndExpiry() throws {
        let usage = try claudeUsage(
            """
            { "eligible": true, "at_limit": false, "exhausted": [],
              "grants": [
                { "id": "launch", "label": "A long promotional sentence", "resets_left": 1, "resets_total": 1,
                  "starts_at": "\(iso(-3600))", "ends_at": "\(iso(30 * 3600))",
                  "clears": ["five_hour", "seven_day", "seven_day_overage_included"], "paused": false },
                { "id": "later", "resets_left": 1, "starts_at": "\(iso(3600))", "ends_at": null, "clears": ["five_hour"] },
                { "id": "paused", "resets_left": 2, "clears": ["five_hour"], "paused": true },
                { "broken": true }
              ] }
            """)
        let summary = try XCTUnwrap(ResetCreditSummary.claude(usage.resetGrants, now: now))

        XCTAssertEqual(summary.availableCount, 1)
        XCTAssertEqual(summary.items.map(\.id), ["launch"])
        XCTAssertEqual(summary.items.first?.scope, .all)
        XCTAssertEqual(summary.items.first?.serverTitle, "A long promotional sentence")
        XCTAssertTrue(summary.isExpiringSoon(now: now))
    }

    func testClaudeIneligibleHidesAndUsedUpShowsZero() throws {
        XCTAssertNil(ResetCreditSummary.claude(try claudeUsage("null").resetGrants, now: now))
        XCTAssertNil(
            ResetCreditSummary.claude(
                try claudeUsage(#"{ "eligible": false, "ineligible_reason": "tier", "grants": [] }"#).resetGrants,
                now: now))
        XCTAssertNil(
            ResetCreditSummary.claude(try claudeUsage(#"{ "eligible": true, "grants": [] }"#).resetGrants, now: now))
        let usedUp = try XCTUnwrap(
            ResetCreditSummary.claude(
                try claudeUsage(#"{ "eligible": true, "at_limit": true, "grants": [], "exhausted": [{}] }"#)
                    .resetGrants,
                now: now))
        XCTAssertEqual(usedUp.availableCount, 0)
        XCTAssertTrue(usedUp.atLimit)
        XCTAssertNil(MenuBarResetCreditBadge.resolve(summary: usedUp, isNew: true, mode: .always, now: now))
    }

    func testFiveHourOnlyScope() throws {
        let usage = try claudeUsage(
            #"{ "eligible": true, "grants": [{ "id": "g", "resets_left": 2, "clears": ["five_hour"] }] }"#)
        let summary = try XCTUnwrap(ResetCreditSummary.claude(usage.resetGrants, now: now))
        XCTAssertEqual(summary.items.first?.scope.title, "5시간 한도만")
        XCTAssertEqual(summary.availableCount, 2)
    }

    func testCodexSummaryUsesCountWhenDetailsAreMissing() throws {
        var usage = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(#"{ "account_id": "a" }"#.utf8))
        usage.resetCredits = CodexResetCreditsResponse(credits: [], availableCountField: 2)
        let summary = try XCTUnwrap(ResetCreditSummary.codex(usage, now: now))
        XCTAssertEqual(summary.availableCount, 2)
        XCTAssertTrue(summary.items.isEmpty)
        XCTAssertEqual(summary.expirationDescription(now: now), "만료 정보 없음")

        usage.resetCredits = CodexResetCreditsResponse(credits: [], availableCountField: 0)
        XCTAssertNil(ResetCreditSummary.codex(usage, now: now))
    }

    func testBadgeTonePrefersExpiryOverNewAndRespectsMode() {
        let item = ResetCreditSummary.Item(
            id: "g", serverTitle: nil, scope: .all, expiresAt: now.addingTimeInterval(86_400 * 10))
        let summary = ResetCreditSummary(items: [item], availableCount: 1, atLimit: false)
        let expiring = ResetCreditSummary(
            items: [.init(id: "g", serverTitle: nil, scope: .all, expiresAt: now.addingTimeInterval(3600))],
            availableCount: 1, atLimit: false)

        XCTAssertEqual(
            MenuBarResetCreditBadge.resolve(summary: summary, isNew: true, mode: .always, now: now)?.tone, .new)
        XCTAssertEqual(
            MenuBarResetCreditBadge.resolve(summary: summary, isNew: false, mode: .always, now: now)?.tone, .normal)
        XCTAssertNil(MenuBarResetCreditBadge.resolve(summary: summary, isNew: false, mode: .newOrExpiring, now: now))
        XCTAssertEqual(
            MenuBarResetCreditBadge.resolve(summary: expiring, isNew: true, mode: .newOrExpiring, now: now)?.tone,
            .expiring)
        XCTAssertNil(MenuBarResetCreditBadge.resolve(summary: expiring, isNew: true, mode: .off, now: now))
        XCTAssertEqual(
            MenuBarResetCreditBadge.resolve(summary: summary, isNew: true, mode: .always, now: now)?.text, "↺1")
    }

    func testSeenStoreKeepsCurrentIDsPerService() throws {
        let suite = "ResetCreditsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let summary = ResetCreditSummary(
            items: [.init(id: "g", serverTitle: nil, scope: .all, expiresAt: nil)], availableCount: 1, atLimit: false)

        ResetCreditSeenStore.observe(summary: summary, count: 1, accountKey: "claude/a", defaults: defaults)
        XCTAssertFalse(ResetCreditSeenStore.isNew(accountKey: "claude/a", defaults: defaults))
        ResetCreditSeenStore.observe(summary: summary, count: 2, accountKey: "claude/a", defaults: defaults)
        XCTAssertTrue(ResetCreditSeenStore.isNew(accountKey: "claude/a", defaults: defaults))
        let receipt = try XCTUnwrap(
            ResetCreditSeenStore.receipt(service: .claude, accountKey: "claude/a", defaults: defaults))
        ResetCreditSeenStore.markSeen(receipt, defaults: defaults)
        XCTAssertFalse(ResetCreditSeenStore.isNew(accountKey: "claude/a", defaults: defaults))
        XCTAssertNil(ResetCreditSeenStore.receipt(service: .codex, accountKey: "codex/a", defaults: defaults))
    }
}
