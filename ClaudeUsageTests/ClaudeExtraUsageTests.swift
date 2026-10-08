import XCTest
@testable import ClaudeUsage

@MainActor
final class ClaudeExtraUsageTests: XCTestCase {

    func testIncompleteEnabledExtraUsageFallsBackInsteadOfInventingMoney() async throws {
        let bodies = [
            #"{}"#,
            #"{"is_enabled":true,"monthly_limit":1000}"#,
            #"{"is_enabled":true,"used_credits":1007}"#,
            #"{"is_enabled":true,"monthly_limit":"bad","used_credits":1007}"#,
            #"{"is_enabled":true,"monthly_limit":1000,"used_credits":"NaN"}"#,
        ]
        for body in bodies {
            let usage = try decode("{\"extra_usage\":" + body + "}")
            XCTAssertNil(usage.extraUsage, body)
            let fallback = ExtraUsageFallbackStub(.value(separateUsage))
            let result = try await ClaudeSupplementalRefreshResult.refresh(
                embeddedUsage: usage.extraUsage, source: .webSession
            ) { try await fallback.fetch() }
            XCTAssertEqual(try successValue(result), separateUsage)
            let calls = await fallback.calls
            XCTAssertEqual(calls, 1, body)
        }
    }

    func testExplicitDisabledExtraUsageRemainsAuthoritativeWithoutMoneyFields() async throws {
        let usage = try decode(#"{"extra_usage":{"is_enabled":false}}"#)
        XCTAssertEqual(usage.extraUsage, .notEnabled)
        let fallback = ExtraUsageFallbackStub(.value(separateUsage))
        let result = try await ClaudeSupplementalRefreshResult.refresh(
            embeddedUsage: usage.extraUsage, source: .webSession
        ) { try await fallback.fetch() }
        XCTAssertEqual(try successValue(result), .notEnabled)
        let calls = await fallback.calls
        XCTAssertEqual(calls, 0)
    }

    func testExtraUsageUsesMinorUnitsAndSpendLimitFlag() throws {
        let usage = try decode(
            """
            {
              "five_hour": { "utilization": 10, "resets_at": null },
              "extra_usage": {
                "is_enabled": true, "monthly_limit": "5000", "used_credits": 5000,
                "currency": "USD", "decimal_places": 2, "spend_limit_reached": true
              }
            }
            """)
        let extra = try XCTUnwrap(usage.extraUsage)

        XCTAssertTrue(extra.isEnabled)
        XCTAssertEqual(extra.monthlyCreditLimit, 50)
        XCTAssertEqual(extra.formattedUsageLimitSummary, "$50.00 사용 / $50.00 한도 · 크레딧 소진")
    }

    func testMissingOrMalformedExtraUsageDoesNotBreakUsage() throws {
        XCTAssertNil(
            try decode(#"{ "five_hour": { "utilization": 1, "resets_at": null }, "extra_usage": null }"#).extraUsage)
        let malformed = try decode(#"{ "five_hour": { "utilization": 1, "resets_at": null }, "extra_usage": 3 }"#)
        XCTAssertNil(malformed.extraUsage)
        XCTAssertEqual(malformed.fiveHour?.utilization, 1)
    }

    func testBrowserUsesUsageBodyInsteadOfConflictingSeparateAmount() async throws {
        let usage = try decode(memberUsageJSON)
        let fallback = ExtraUsageFallbackStub(.value(separateUsage))

        let result = try await ClaudeSupplementalRefreshResult.refresh(
            embeddedUsage: usage.extraUsage, source: .webSession
        ) { try await fallback.fetch() }

        let value = try successValue(result)
        XCTAssertEqual(value.formattedUsageLimitSummary, "$10.07 사용 / $10.00 한도 · 크레딧 소진")
        XCTAssertEqual(try XCTUnwrap(value.usagePercentage), 100.7, accuracy: 0.001)
        let calls = await fallback.calls
        XCTAssertEqual(calls, 0)
    }

    func testUsageBodyReplacesCachedAmountDuringSeparateFetchCooldown() async throws {
        let now = Date()
        let facade = AppRuntimeStateFacade()
        facade.activeClaudeAccountID = "account"
        facade[.claude].lastSuccessfulMetadata = fixtureClaudeMetadata(accountID: "account")
        facade.applyClaudeSupplementalUsage(
            .success(separateUsage, fetchedAt: now), accountID: "account",
            ownerKey: fixtureClaudeMetadata(accountID: "account").supplementalAccountKey)
        let fallback = ExtraUsageFallbackStub(.value(separateUsage))

        let result = try await ClaudeSupplementalRefreshResult.refresh(
            embeddedUsage: try decode(memberUsageJSON).extraUsage,
            source: .webSession, lastAttemptAt: now, now: now
        ) { try await fallback.fetch() }
        facade.applyClaudeSupplementalUsage(
            result, accountID: "account", ownerKey: fixtureClaudeMetadata(accountID: "account").supplementalAccountKey)

        XCTAssertEqual(facade.currentOverage?.formattedUsedCredits, "$10.07")
        XCTAssertEqual(facade.currentOverage?.formattedCreditLimit, "$10.00")
        let calls = await fallback.calls
        XCTAssertEqual(calls, 0)
    }

    func testDisabledUsageBodyDoesNotEnableSeparateUsage() async throws {
        let usage = try decode(#"{"extra_usage":{"is_enabled":false,"monthly_limit":0,"used_credits":0}}"#)
        for source in [ClaudeUsageSource.webSession, .oauth] {
            let fallback = ExtraUsageFallbackStub(.value(separateUsage))
            let result = try await ClaudeSupplementalRefreshResult.refresh(
                embeddedUsage: usage.extraUsage, source: source
            ) { try await fallback.fetch() }

            let value = try successValue(result)
            XCTAssertFalse(value.isEnabled)
            XCTAssertEqual(value.usedCredits, 0)
            let calls = await fallback.calls
            XCTAssertEqual(calls, 0)
        }
    }

    func testUnlimitedUsageBodyDoesNotAdoptSeparateLimit() async throws {
        let usage = try decode(
            #"{"extra_usage":{"is_enabled":true,"monthly_limit":null,"used_credits":1250}}"#)
        let fallback = ExtraUsageFallbackStub(.value(separateUsage))
        let result = try await ClaudeSupplementalRefreshResult.refresh(
            embeddedUsage: usage.extraUsage, source: .webSession
        ) { try await fallback.fetch() }

        let value = try successValue(result)
        XCTAssertNil(value.monthlyCreditLimit)
        XCTAssertNil(value.usagePercentage)
        XCTAssertEqual(value.formattedUsageLimitSummary, "$12.50 사용 / 한도 없음")
        let calls = await fallback.calls
        XCTAssertEqual(calls, 0)
    }

    func testZeroUsageBodyDoesNotAdoptSeparateSpend() async throws {
        let usage = try decode(
            #"{"extra_usage":{"is_enabled":true,"monthly_limit":1000,"used_credits":0,"currency":"EUR"}}"#)
        let fallback = ExtraUsageFallbackStub(.value(separateUsage))
        let result = try await ClaudeSupplementalRefreshResult.refresh(
            embeddedUsage: usage.extraUsage, source: .webSession
        ) { try await fallback.fetch() }

        let value = try successValue(result)
        XCTAssertEqual(value.usedCredits, 0)
        XCTAssertEqual(value.monthlyCreditLimit, 10)
        XCTAssertEqual(value.currency, "EUR")
        let calls = await fallback.calls
        XCTAssertEqual(calls, 0)
    }

    func testOAuthPathTreatsAbsentExtraUsageAsNotEnabled() async throws {
        let now = Date()
        let usage = try decode(#"{ "five_hour": { "utilization": 1, "resets_at": null } }"#)
        let fallback = ExtraUsageFallbackStub(.value(separateUsage))
        let result = try await ClaudeSupplementalRefreshResult.refresh(
            embeddedUsage: usage.extraUsage, source: .oauth, now: now
        ) { try await fallback.fetch() }

        guard case .success(let value, let fetchedAt) = result else { return XCTFail("expected success") }
        XCTAssertFalse(value.isEnabled)
        XCTAssertEqual(fetchedAt, now)
        let calls = await fallback.calls
        XCTAssertEqual(calls, 0)
    }

    func testBrowserWithoutUsageBodyFetchesSeparateUsage() async throws {
        let fallback = ExtraUsageFallbackStub(.value(separateUsage))
        let result = try await ClaudeSupplementalRefreshResult.refresh(
            embeddedUsage: nil, source: .webSession
        ) { try await fallback.fetch() }

        XCTAssertEqual(try successValue(result), separateUsage)
        let calls = await fallback.calls
        XCTAssertEqual(calls, 1)
    }

    func testBrowserWithoutUsageBodyKeepsSeparateFetchCooldown() async throws {
        let now = Date()
        let fallback = ExtraUsageFallbackStub(.value(separateUsage))
        let result = try await ClaudeSupplementalRefreshResult.refresh(
            embeddedUsage: nil, source: .webSession,
            lastAttemptAt: now.addingTimeInterval(-299), now: now
        ) { try await fallback.fetch() }

        guard case .unchanged = result else { return XCTFail("expected unchanged") }
        let calls = await fallback.calls
        XCTAssertEqual(calls, 0)
    }

    func testSeparateFetchFailureKeepsCachedAmountAndMarksItStale() async throws {
        let previousFetch = Date().addingTimeInterval(-301)
        let facade = AppRuntimeStateFacade()
        facade.activeClaudeAccountID = "account"
        facade[.claude].lastSuccessfulMetadata = fixtureClaudeMetadata(accountID: "account")
        facade.applyClaudeSupplementalUsage(
            .success(separateUsage, fetchedAt: previousFetch), accountID: "account",
            ownerKey: fixtureClaudeMetadata(accountID: "account").supplementalAccountKey)
        let fallback = ExtraUsageFallbackStub(.failure)
        let result = try await ClaudeSupplementalRefreshResult.refresh(
            embeddedUsage: nil, source: .webSession, lastAttemptAt: previousFetch
        ) { try await fallback.fetch() }
        facade.applyClaudeSupplementalUsage(
            result, accountID: "account", ownerKey: fixtureClaudeMetadata(accountID: "account").supplementalAccountKey)

        guard case .failed = result else { return XCTFail("expected failed") }
        XCTAssertEqual(facade.currentOverage, separateUsage)
        XCTAssertEqual(facade.lastOverageFetchAt, previousFetch)
        XCTAssertTrue(facade.snapshot(for: .claude, codexAuthenticated: false).claudeOverageIsStale)
        let calls = await fallback.calls
        XCTAssertEqual(calls, 1)
    }

    func testSeparateFetchCancellationRemainsCancellation() async throws {
        let fallback = ExtraUsageFallbackStub(.cancellation)
        do {
            _ = try await ClaudeSupplementalRefreshResult.refresh(
                embeddedUsage: nil, source: .webSession
            ) { try await fallback.fetch() }
            XCTFail("expected cancellation")
        } catch is CancellationError {
            let calls = await fallback.calls
            XCTAssertEqual(calls, 1)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private var memberUsageJSON: String {
        #"{"five_hour":{"utilization":8},"extra_usage":{"is_enabled":true,"monthly_limit":1000,"used_credits":1007,"currency":"USD","decimal_places":2,"spend_limit_reached":true}}"#
    }

    private var separateUsage: OverageSpendLimitResponse {
        OverageSpendLimitResponse(
            monthlyCreditLimitCents: 2000, usedCreditsCents: 1115,
            isEnabled: true, outOfCredits: false, currency: "USD")
    }

    private func successValue(_ result: ClaudeSupplementalRefreshResult) throws -> OverageSpendLimitResponse {
        guard case .success(let value, _) = result else {
            XCTFail("expected success")
            throw ExtraUsageTestError.expectedSuccess
        }
        return value
    }

    private func decode(_ json: String) throws -> ClaudeUsageResponse {
        try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(json.utf8))
    }
}

private enum ExtraUsageTestError: Error {
    case expectedSuccess
}

private actor ExtraUsageFallbackStub {
    enum Outcome: Sendable {
        case value(OverageSpendLimitResponse)
        case failure
        case cancellation
    }

    let outcome: Outcome
    private(set) var calls = 0

    init(_ outcome: Outcome) { self.outcome = outcome }

    func fetch() throws -> OverageSpendLimitResponse {
        calls += 1
        switch outcome {
        case .value(let value): return value
        case .failure: throw URLError(.notConnectedToInternet)
        case .cancellation: throw CancellationError()
        }
    }
}
