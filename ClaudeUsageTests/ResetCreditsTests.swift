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
        XCTAssertEqual(summary.items.first?.scope, .fiveHourAndWeekly)
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
        XCTAssertNil(MenuBarResetCreditBadge.resolve(summary: usedUp, isNew: true, mode: .always, now: now))
    }

    func testFiveHourOnlyScope() throws {
        let usage = try claudeUsage(
            #"{ "eligible": true, "grants": [{ "id": "g", "resets_left": 2, "clears": ["five_hour"] }] }"#)
        let summary = try XCTUnwrap(ResetCreditSummary.claude(usage.resetGrants, now: now))
        XCTAssertEqual(summary.items.first?.scope.title, "5시간 초기화권")
        XCTAssertEqual(summary.availableCount, 2)
    }

    func testMissingClearsDoesNotClaimFiveHourOnly() throws {
        let usage = try claudeUsage(#"{ "eligible": true, "grants": [{ "id": "g", "resets_left": 1 }] }"#)
        let summary = try XCTUnwrap(ResetCreditSummary.claude(usage.resetGrants, now: now))
        XCTAssertEqual(summary.items.first?.scope, .unknown)
        XCTAssertEqual(ResetCreditRows.make(summary: summary, now: now).first?.title, "범위 확인 안 됨")
    }

    func testMalformedClaudeGrantCountRemainsUnknownAndPreservesBaseUsage() throws {
        for field in [
            "", #", "resets_left": null"#, #", "resets_left": "unknown""#,
            #", "resets_left": -1"#, #", "resets_left": 1.5"#, #", "resets_left": true"#,
        ] {
            let usage = try claudeUsage(
                #"{"eligible":true,"grants":[{"id":"grant-fixture"\#(field)}]}"#)
            let grants = try XCTUnwrap(usage.resetGrants)
            XCTAssertEqual(usage.fiveHour?.utilization, 24)
            XCTAssertEqual(grants.grants.count, 1)
            XCTAssertNil(grants.grants.first?.resetsLeft)
            XCTAssertNil(grants.availableCount(at: now))
            XCTAssertNil(ResetCreditSummary.claude(grants, now: now))
        }
    }

    func testPartialClaudeCountsCannotOverwriteSeenCountOrKnownIDs() throws {
        let suite = "ResetCreditsTests.partial.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = "claude/fixture"
        func summary(_ json: String) throws -> ResetCreditSummary? {
            ResetCreditSummary.claude(try claudeUsage(json).resetGrants, now: now)
        }
        let first = try XCTUnwrap(
            summary(
                #"{"eligible":true,"grants":[{"id":"first","resets_left":1}]}"#))
        let completeJSON =
            #"{"eligible":true,"grants":[{"id":"first","resets_left":1},{"id":"second","resets_left":1}]}"#
        let complete = try XCTUnwrap(summary(completeJSON))
        ResetCreditSeenStore.observe(
            summary: first, count: first.availableCount, accountKey: account, defaults: defaults)
        ResetCreditSeenStore.observe(
            summary: complete, count: complete.availableCount, accountKey: account, defaults: defaults)
        let receipt = try XCTUnwrap(
            ResetCreditSeenStore.receipt(service: .claude, accountKey: account, defaults: defaults))
        let stored = try XCTUnwrap(defaults.data(forKey: ResetCreditSeenStore.key))
        XCTAssertTrue(ResetCreditSeenStore.isNew(accountKey: account, defaults: defaults))

        let partialUsage = try claudeUsage(
            #"{"eligible":true,"exhausted":[{}],"grants":[{"id":"first","resets_left":1},{"id":"second","resets_left":"unknown"}]}"#
        )
        let partialGrants = try XCTUnwrap(partialUsage.resetGrants)
        XCTAssertEqual(partialGrants.grants.map(\.id), ["first", "second"])
        XCTAssertEqual(partialGrants.grants.first?.resetsLeft, 1)
        XCTAssertNil(partialGrants.availableCount(at: now))
        let partial = ResetCreditSummary.claude(partialGrants, now: now)
        XCTAssertNil(partial, "One known grant is not a verified total, even when exhausted grants also exist.")
        XCTAssertNil(MenuBarResetCreditBadge.resolve(summary: partial, isNew: true, mode: .always, now: now))
        // This is the same summary/count projection used by AppDelegate.observeResetCredits.
        ResetCreditSeenStore.observe(
            summary: partial, count: partial?.availableCount, accountKey: account, defaults: defaults)
        XCTAssertEqual(defaults.data(forKey: ResetCreditSeenStore.key), stored)
        XCTAssertEqual(
            ResetCreditSeenStore.receipt(service: .claude, accountKey: account, defaults: defaults), receipt)
        XCTAssertTrue(ResetCreditSeenStore.isNew(accountKey: account, defaults: defaults))

        ResetCreditSeenStore.observe(
            summary: try summary(completeJSON), count: complete.availableCount, accountKey: account, defaults: defaults)
        XCTAssertEqual(
            defaults.data(forKey: ResetCreditSeenStore.key), stored,
            "Completing the same IDs must not create another revision after the unknown response.")
    }

    func testVerifiedClaudeZeroAndExhaustedCountsRemainZero() throws {
        for json in [
            #"{"eligible":true,"grants":[{"id":"zero","resets_left":0}]}"#,
            #"{"eligible":true,"grants":[],"exhausted":[{}]}"#,
        ] {
            let grants = try XCTUnwrap(try claudeUsage(json).resetGrants)
            XCTAssertEqual(grants.availableCount(at: now), 0)
            let summary = try XCTUnwrap(ResetCreditSummary.claude(grants, now: now))
            XCTAssertEqual(summary.availableCount, 0)
            XCTAssertTrue(summary.items.isEmpty)
        }
    }

    func testInactiveUnknownGrantsDoNotHideTheVerifiedActiveCount() {
        let active = ClaudeResetGrants.Grant(
            id: "active", label: nil, resetsLeft: 2,
            startsAt: nil, endsAt: nil, clears: [], paused: false)
        let inactive = [
            ClaudeResetGrants.Grant(
                id: "paused", label: nil, resetsLeft: nil,
                startsAt: nil, endsAt: nil, clears: [], paused: true),
            ClaudeResetGrants.Grant(
                id: "future", label: nil, resetsLeft: nil,
                startsAt: now.addingTimeInterval(1), endsAt: nil, clears: [], paused: false),
            ClaudeResetGrants.Grant(
                id: "expired", label: nil, resetsLeft: nil,
                startsAt: nil, endsAt: now, clears: [], paused: false),
        ]
        for grant in inactive {
            let grants = ClaudeResetGrants(eligible: true, grants: [active, grant])
            XCTAssertEqual(grants.availableCount(at: now), 2)
            XCTAssertEqual(ResetCreditSummary.claude(grants, now: now)?.items.map(\.id), ["active"])
        }
    }

    func testUnrepresentableClaudeTotalRemainsUnknown() throws {
        let usage = try claudeUsage(
            #"{"eligible":true,"grants":[{"id":"maximum","resets_left":\#(Int.max)},{"id":"one","resets_left":1}]}"#)
        let grants = try XCTUnwrap(usage.resetGrants)
        XCTAssertEqual(grants.grants.first?.resetsLeft, Int.max)
        XCTAssertNil(grants.availableCount(at: now))
        XCTAssertNil(ResetCreditSummary.claude(grants, now: now))
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
            id: "g", serverTitle: nil, scope: .fiveHourAndWeekly, expiresAt: now.addingTimeInterval(86_400 * 10))
        let summary = ResetCreditSummary(items: [item], availableCount: 1)
        let expiring = ResetCreditSummary(
            items: [
                .init(id: "g", serverTitle: nil, scope: .fiveHourAndWeekly, expiresAt: now.addingTimeInterval(3600))
            ],
            availableCount: 1)

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

    func testFableAndWeeklyRightsGetDistinctRowsWithPerGrantCounts() throws {
        let usage = try claudeUsage(
            """
            {"eligible":true,"grants":[
              {"id":"fable","label":"New model launch: one Fable reset","gives_back_weekly":true,
                "resets_left":2,"clears":["five_hour","seven_day_overage_included"],"ends_at":"\(iso(3600))"},
              {"id":"weekly","resets_left":1,"clears":["seven_day"],"ends_at":"\(iso(700000))"},
              {"id":"other","resets_left":1,"clears":["seven_day_overage_included"]}
            ]}
            """)
        let summary = try XCTUnwrap(ResetCreditSummary.claude(usage, now: now))
        let availability = QuotaAvailability(
            limits: [
                .init(
                    id: "weekly", provider: .claude, title: "주간", shortTitle: "주간", scope: "seven_day",
                    periodSeconds: UsageWindowLength.weekly, usedPercentage: 100, resetAt: nil,
                    isIdentifiable: true, legacyKey: "weekly", coverage: .shared)
            ], now: now)
        let rows = ResetCreditRows.make(summary: summary, availability: availability, now: now)
        XCTAssertEqual(summary.availableCount, 4)
        XCTAssertEqual(rows.map(\.title), ["주간 초기화권", "Fable 초기화권", "범위 확인 안 됨"])
        XCTAssertEqual(rows.map(\.count), [1, 2, 1])
        XCTAssertEqual(rows.map(\.helpsCurrentLimit), [true, false, false])
        let fable = try XCTUnwrap(summary.items.first)
        XCTAssertEqual(fable.scope.effects, [.returnWeeklyModelUsage("Fable"), .refill(.fiveHour)])
        XCTAssertEqual(fable.count, 2)
    }

    func testFableWithoutSessionAndUnconfirmedWeeklyAdjustment() throws {
        let usage = try claudeUsage(
            """
            {"eligible":true,"grants":[
              {"id":"fable","label":"Fable reset","gives_back_weekly":true,"resets_left":1,
                "clears":["five_hour","seven_day","seven_day_overage_included"]},
              {"id":"unconfirmed","label":"Fable promotion","resets_left":1,
                "clears":["seven_day_overage_included"]}
            ]}
            """)
        let summary = try XCTUnwrap(
            ResetCreditSummary.claude(usage.resetGrants, hasSessionWindow: false, now: now))
        XCTAssertEqual(summary.items.first { $0.id == "fable" }?.scope.effects, [.returnWeeklyModelUsage("Fable")])
        XCTAssertEqual(summary.items.first { $0.id == "unconfirmed" }?.scope, .unknown)
    }

    func testCodexIncompleteDetailsPreserveCountWithoutInferringScope() throws {
        var usage = try JSONDecoder().decode(
            CodexUsageResponse.self,
            from: Data(
                #"{ "rate_limit": { "primary_window": { "used_percent": 10, "limit_window_seconds": 604800 } } }"#.utf8)
        )
        usage.resetCredits = .init(
            credits: [.init(id: "a", resetType: "codexRateLimits", status: "available", doesNotExpire: true)],
            availableCountField: 2)
        let summary = try XCTUnwrap(ResetCreditSummary.codex(usage, now: now))
        let rows = ResetCreditRows.make(summary: summary, now: now)
        XCTAssertEqual(rows.map(\.count), [1, 1])
        XCTAssertEqual(rows.map(\.title), ["주간 초기화권", "초기화권 상세 미확인"])
        XCTAssertEqual(rows.first?.expiryText, "만료 없음")
    }

    func testDuplicateClaudeGrantDoesNotInflateCountsAndConflictingCopiesStayUnknown() throws {
        let copies = try claudeUsage(
            #"{"eligible":true,"grants":[{"id":"same","resets_left":2},{"id":"same","resets_left":2}]}"#)
        let conflicting = try claudeUsage(
            #"{"eligible":true,"grants":[{"id":"same","resets_left":1},{"id":"same","resets_left":2}]}"#)
        let summary = try XCTUnwrap(ResetCreditSummary.claude(copies, now: now))
        XCTAssertEqual(summary.availableCount, 2)
        XCTAssertEqual(summary.items.count, 1)
        XCTAssertNil(ResetCreditSummary.claude(conflicting, now: now))
    }

    func testSeenStoreKeepsCurrentIDsPerService() throws {
        let suite = "ResetCreditsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let summary = ResetCreditSummary(
            items: [.init(id: "g", serverTitle: nil, scope: .fiveHourAndWeekly, expiresAt: nil)], availableCount: 1)

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
