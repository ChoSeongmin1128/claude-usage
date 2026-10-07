import XCTest
@testable import ClaudeUsage

final class ResetCreditStateTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "ResetCreditStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private func summary(_ count: Int, ids: [String] = [], complete: Bool = false) -> ResetCreditSummary {
        ResetCreditSummary(
            items: ids.map { .init(id: $0, serverTitle: nil, scope: .all, expiresAt: nil) },
            availableCount: count, atLimit: false, identityDetailsComplete: complete)
    }

    func testCountDecreaseAndLateDetailsAreNotNewButIncreaseIs() throws {
        try withDefaults { defaults in
            let account = "codex/a"
            func observe(_ count: Int, ids: [String] = [], complete: Bool = false) {
                ResetCreditSeenStore.observe(
                    summary: summary(count, ids: ids, complete: complete), count: count,
                    accountKey: account, defaults: defaults)
            }
            observe(2)
            XCTAssertFalse(ResetCreditSeenStore.isNew(accountKey: account, defaults: defaults))
            observe(1)
            XCTAssertFalse(ResetCreditSeenStore.isNew(accountKey: account, defaults: defaults))
            observe(1, ids: ["one"], complete: true)
            XCTAssertFalse(ResetCreditSeenStore.isNew(accountKey: account, defaults: defaults))
            observe(2)
            XCTAssertTrue(ResetCreditSeenStore.isNew(accountKey: account, defaults: defaults))
            observe(1)
            XCTAssertTrue(ResetCreditSeenStore.isNew(accountKey: account, defaults: defaults))
            observe(0)
            XCTAssertFalse(ResetCreditSeenStore.isNew(accountKey: account, defaults: defaults))
            observe(1)
            XCTAssertTrue(ResetCreditSeenStore.isNew(accountKey: account, defaults: defaults))
        }
    }

    func testCappedDetailsDoNotCreateNewCreditsDuringEnrichment() throws {
        try withDefaults { defaults in
            ResetCreditSeenStore.observe(
                summary: summary(3, ids: ["a"], complete: false), count: 3,
                accountKey: "a", defaults: defaults)
            ResetCreditSeenStore.observe(
                summary: summary(3, ids: ["a", "b", "c"], complete: true), count: 3,
                accountKey: "a", defaults: defaults)
            XCTAssertFalse(ResetCreditSeenStore.isNew(accountKey: "a", defaults: defaults))
            ResetCreditSeenStore.observe(
                summary: summary(3, ids: ["a", "b", "d"], complete: true), count: 3,
                accountKey: "a", defaults: defaults)
            XCTAssertTrue(ResetCreditSeenStore.isNew(accountKey: "a", defaults: defaults))
        }
    }

    func testAccountsAndVisibleRevisionAreIndependentAndLegacyKeyIsPreserved() throws {
        try withDefaults { defaults in
            let legacy = AppIdentifiers.defaultsKey("seenResetCredits")
            defaults.set(["codex": ["old"]], forKey: legacy)
            ResetCreditSeenStore.observe(summary: nil, count: 1, accountKey: "a", defaults: defaults)
            ResetCreditSeenStore.observe(summary: nil, count: 2, accountKey: "a", defaults: defaults)
            let first = try XCTUnwrap(
                ResetCreditSeenStore.receipt(service: .codex, accountKey: "a", defaults: defaults))
            ResetCreditSeenStore.observe(summary: nil, count: 3, accountKey: "a", defaults: defaults)
            ResetCreditSeenStore.observe(summary: nil, count: 3, accountKey: "b", defaults: defaults)
            ResetCreditSeenStore.markSeen(first, defaults: defaults)
            XCTAssertTrue(ResetCreditSeenStore.isNew(accountKey: "a", defaults: defaults))
            XCTAssertFalse(ResetCreditSeenStore.isNew(accountKey: "b", defaults: defaults))
            let latest = try XCTUnwrap(
                ResetCreditSeenStore.receipt(service: .codex, accountKey: "a", defaults: defaults))
            ResetCreditSeenStore.markSeen(latest, defaults: defaults)
            XCTAssertFalse(ResetCreditSeenStore.isNew(accountKey: "a", defaults: defaults))
            XCTAssertEqual(defaults.dictionary(forKey: legacy)?["codex"] as? [String], ["old"])
            ResetCreditSeenStore.remove(accountKey: "a", defaults: defaults)
            XCTAssertNil(ResetCreditSeenStore.receipt(service: .codex, accountKey: "a", defaults: defaults))
            XCTAssertNotNil(ResetCreditSeenStore.receipt(service: .codex, accountKey: "b", defaults: defaults))
        }
    }

    func testUnconfirmedAccountAndMissingCountDoNotWriteState() throws {
        try withDefaults { defaults in
            ResetCreditSeenStore.observe(summary: nil, count: 2, accountKey: nil, defaults: defaults)
            ResetCreditSeenStore.observe(summary: nil, count: nil, accountKey: "a", defaults: defaults)
            XCTAssertNil(defaults.object(forKey: ResetCreditSeenStore.key))
        }
    }

    func testOnlyFullyVisibleRowInItsOwnViewportIsAcknowledged() {
        let receipt = ResetCreditSeenReceipt(service: .codex, accountKey: "a", revision: 2)
        let viewport = CGRect(x: 0, y: 10, width: 300, height: 100)
        func visible(_ frame: CGRect, compact: Bool = false) -> Set<ResetCreditSeenReceipt> {
            ResetCreditVisibility.Value(
                viewports: [false: viewport],
                rows: [
                    .init(compact: compact, frame: frame, receipt: receipt)
                ]
            ).visibleReceipts
        }
        XCTAssertEqual(visible(CGRect(x: 0, y: 30, width: 300, height: 40)), [receipt])
        XCTAssertTrue(visible(CGRect(x: 0, y: 90, width: 300, height: 40)).isEmpty)
        XCTAssertTrue(visible(CGRect(x: 0, y: 130, width: 300, height: 40)).isEmpty)
        XCTAssertTrue(visible(CGRect(x: 0, y: 30, width: 0, height: 40)).isEmpty)
        XCTAssertTrue(visible(CGRect(x: 0, y: 30, width: 300, height: 40), compact: true).isEmpty)
        XCTAssertTrue(ResetCreditVisibility.Value().visibleReceipts.isEmpty)
    }

    func testExplicitNullExpiryMeansNoExpirationWhileMissingOrCappedDetailsStayUnknown() throws {
        func decode(_ json: String) throws -> ResetCreditSummary {
            var usage = try JSONDecoder().decode(CodexUsageResponse.self, from: Data("{}".utf8))
            usage.resetCredits = try JSONDecoder().decode(CodexResetCreditsResponse.self, from: Data(json.utf8))
            return try XCTUnwrap(ResetCreditSummary.codex(usage))
        }
        XCTAssertEqual(
            try decode(#"{"available_count":1,"credits":[{"id":"a","status":"available","expires_at":null}]}"#)
                .expirationDescription(), "만료 없음")
        XCTAssertEqual(
            try decode(#"{"available_count":1,"credits":[{"id":"a","status":"available"}]}"#).expirationDescription(),
            "만료 정보 없음")
        XCTAssertEqual(
            try decode(#"{"available_count":2,"credits":[{"id":"a","status":"available","expires_at":null}]}"#)
                .expirationDescription(), "만료 정보 없음")
        let converted = try XCTUnwrap(
            CodexOwnerCLI.resetCredits(from: [
                "availableCount": 1, "credits": [["id": "a", "status": "available", "expiresAt": NSNull()]],
            ]))
        XCTAssertTrue(try XCTUnwrap(converted.credits.first).doesNotExpire)
        let roundTrip = try JSONDecoder().decode(CodexResetCreditsResponse.self, from: JSONEncoder().encode(converted))
        XCTAssertEqual(roundTrip, converted)
        XCTAssertTrue(roundTrip.hasCompleteExpirationDetails)
    }
}
