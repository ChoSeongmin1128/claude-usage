import XCTest
@testable import ClaudeUsage

@MainActor
final class ReviewStorageAndSelectionTests: XCTestCase {
    func testDeletingLastManagedWebLoginRemovesOnlyItsResetCreditRecord() throws {
        let suite = "ReviewStorageAndSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = UsageAccountsController(providers: [], defaults: defaults, isServiceEnabled: { _ in true })
        let identity = UsageAccountIdentity(accountID: "a", organizationID: "org-a")
        controller.bindRuntimeAccount(
            .init(source: .init(role: .web, reference: "web-a"), identity: identity), for: .claude)
        let account = try XCTUnwrap(controller.accounts[.claude]?.first)
        for key in [account.id, "unrelated"] {
            ResetCreditSeenStore.observe(summary: nil, count: 1, accountKey: key, defaults: defaults)
        }
        controller.removeResetCreditStateForDeletedWebLogin("web-a")
        XCTAssertNil(ResetCreditSeenStore.receipt(service: .claude, accountKey: account.id, defaults: defaults))
        XCTAssertNotNil(ResetCreditSeenStore.receipt(service: .claude, accountKey: "unrelated", defaults: defaults))
    }

    func testDeletingOneLoginPreservesHistoryOfSameAccountStillOwnedByAnotherSource() throws {
        for remainingSource in [
            UsageAccountSource(role: .defaultLogin, reference: "fake-cli"),
            .init(role: .web, reference: "web-b"),
        ] {
            let suite = "ReviewStorageAndSelectionTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let controller = UsageAccountsController(providers: [], defaults: defaults, isServiceEnabled: { _ in true })
            let identity = UsageAccountIdentity(accountID: "a", organizationID: "org-a")
            controller.bindRuntimeAccount(
                .init(source: .init(role: .web, reference: "web-a"), identity: identity), for: .claude)
            controller.bindRuntimeAccount(.init(source: remainingSource, identity: identity), for: .claude)
            let account = try XCTUnwrap(controller.accounts[.claude]?.first)
            XCTAssertEqual(account.sources.count, 2)
            ResetCreditSeenStore.observe(summary: nil, count: 1, accountKey: account.id, defaults: defaults)
            let before = ResetCreditSeenStore.receipt(service: .claude, accountKey: account.id, defaults: defaults)
            controller.removeResetCreditStateForDeletedWebLogin("web-a")
            XCTAssertEqual(
                ResetCreditSeenStore.receipt(service: .claude, accountKey: account.id, defaults: defaults), before)
        }
    }

    func testSingleWebSessionWithoutCloudUUIDHasScopedNewCreditHistory() throws {
        let suite = "ReviewStorageAndSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func key(_ org: String) throws -> String {
            try XCTUnwrap(
                RuntimeProviderFetchMetadata(
                    account: .init(
                        source: .init(role: .web, reference: "web-a"), identity: .init(organizationID: org))
                )
                .resetCreditAccountKey(for: .claude))
        }
        let a = try key("org-a"), b = try key("org-b")
        XCTAssertNotEqual(a, b)
        ResetCreditSeenStore.observe(summary: nil, count: 1, accountKey: a, defaults: defaults)
        XCTAssertFalse(ResetCreditSeenStore.isNew(accountKey: a, defaults: defaults))
        ResetCreditSeenStore.observe(summary: nil, count: 2, accountKey: a, defaults: defaults)
        XCTAssertTrue(ResetCreditSeenStore.isNew(accountKey: a, defaults: defaults))
        ResetCreditSeenStore.observe(summary: nil, count: 2, accountKey: b, defaults: defaults)
        XCTAssertFalse(ResetCreditSeenStore.isNew(accountKey: b, defaults: defaults))
        let receipt = try XCTUnwrap(ResetCreditSeenStore.receipt(service: .claude, accountKey: a, defaults: defaults))
        ResetCreditSeenStore.markSeen(receipt, defaults: defaults)
        XCTAssertFalse(ResetCreditSeenStore.isNew(accountKey: a, defaults: defaults))
    }

    func testDeletingWebLoginRemovesItsAllOrganizationScopesAndKeepsSharedCanonicalHistory() throws {
        let suite = "ReviewStorageAndSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = UsageAccountsController(providers: [], defaults: defaults, isServiceEnabled: { _ in true })
        let identity = UsageAccountIdentity(accountID: "a", organizationID: "org-a")
        controller.bindRuntimeAccount(
            .init(source: .init(role: .web, reference: "web-a"), identity: identity), for: .claude)
        controller.bindRuntimeAccount(
            .init(source: .init(role: .defaultLogin, reference: "fixture"), identity: identity), for: .claude)
        let canonical = try XCTUnwrap(controller.accounts[.claude]?.first?.id)
        let prefix = RuntimeProviderFetchMetadata.webSessionOwnerPrefix(reference: "web-a")
        let removed = [prefix + "org-a", prefix + "org-b"]
        let kept = [canonical, RuntimeProviderFetchMetadata.webSessionOwnerPrefix(reference: "web-ab") + "org-a"]
        for key in removed + kept {
            ResetCreditSeenStore.observe(summary: nil, count: 1, accountKey: key, defaults: defaults)
        }
        controller.removeResetCreditStateForDeletedWebLogin("web-a")
        for key in removed {
            XCTAssertNil(ResetCreditSeenStore.receipt(service: .claude, accountKey: key, defaults: defaults))
        }
        for key in kept {
            XCTAssertNotNil(ResetCreditSeenStore.receipt(service: .claude, accountKey: key, defaults: defaults))
        }
    }

    func testMissingSelectedAntigravityLaneHasEditableMatchingPlaceholder() throws {
        let known = AntigravityQuotaLaneID.geminiWeekly
        let missing = AntigravityQuotaLaneID(rawValue: "unknown.scope.window")
        var intent = AntigravityDisplaySettings.default.menuBar
        intent.percentageLaneIDs = [known, missing]
        intent.resetLaneIDs = [missing]
        let selected = intent.textLaneIDs(fallback: [])
        let rows = LimitSettingsTable.antigravityRows(
            lanes: [(known.rawValue, "Gemini 주간")], limits: [], selectedIDs: selected)
        XCTAssertEqual(rows.count, 2)
        let row = try XCTUnwrap(rows.first { $0.laneID == missing.rawValue })
        XCTAssertEqual(row.title, "선택한 한도 2 (데이터 없음)")
        intent.percentageLaneIDs?.removeAll { $0 == missing }
        intent.resetLaneIDs?.removeAll { $0 == missing }
        let after = LimitSettingsTable.antigravityRows(
            lanes: [(known.rawValue, "Gemini 주간")], limits: [], selectedIDs: intent.textLaneIDs(fallback: []))
        XCTAssertEqual(after.map(\.laneID), [known.rawValue])
    }
}
