import XCTest
@testable import ClaudeUsage

final class ProviderPoliciesTests: XCTestCase {
    func testShouldRefreshOnTabSwitchSkipsFreshSuccessfulContent() {
        let state = RuntimeProviderPresentationState(
            service: .claude,
            lastUpdated: Date(),
            hasContent: true,
            error: nil
        )

        XCTAssertFalse(
            ProviderTransitionPolicy.shouldRefreshOnTabSwitch(
                state: state,
                refreshInterval: 120
            )
        )
    }

    func testShouldRefreshOnTabSwitchRefreshesRecoverableAttemptEvenWhenFresh() {
        let state = RuntimeProviderPresentationState(
            service: .codex,
            lastUpdated: Date(),
            hasContent: true,
            error: .networkError("timeout"),
            lastAttemptState: .temporaryFailure
        )

        XCTAssertTrue(
            ProviderTransitionPolicy.shouldRefreshOnTabSwitch(
                state: state,
                refreshInterval: 120
            )
        )
    }

    func testShouldRefreshOnTabSwitchRefreshesWhenBackoffIsActive() {
        let state = RuntimeProviderPresentationState(
            service: .antigravity,
            lastUpdated: Date(),
            hasContent: true,
            error: nil,
            lastAttemptState: .idle,
            nextRefreshAllowedAt: Date(timeIntervalSinceNow: 30)
        )

        XCTAssertTrue(
            ProviderTransitionPolicy.shouldRefreshOnTabSwitch(
                state: state,
                refreshInterval: 120
            )
        )
    }

    func testEnabledChangeDecisionRequiresCredentialForCodex() {
        let decision = ProviderTransitionPolicy.enabledChangeDecision(
            state: RuntimeProviderActivationState(
                service: .codex,
                enabled: true,
                hasCredential: false
            )
        )

        guard case .clearAndPromptAuth = decision else {
            return XCTFail("Codex는 자격이 없으면 인증 유도 결정이어야 합니다")
        }
    }

    func testEnabledChangeDecisionRefreshesAntigravityImmediatelyWithoutCredential() {
        let decision = ProviderTransitionPolicy.enabledChangeDecision(
            state: RuntimeProviderActivationState(
                service: .antigravity,
                enabled: true,
                hasCredential: false
            )
        )

        guard case .refreshNow = decision else {
            return XCTFail("Antigravity는 활성화 직후 즉시 refresh 결정이어야 합니다")
        }
    }

    func testRemainingBackoffSecondsRoundsUpFutureIntervalAndClearsExpiredDate() {
        let remaining = RefreshExecutionPolicy.remainingBackoffSeconds(
            until: Date().addingTimeInterval(5.1)
        )

        XCTAssertNotNil(remaining)
        XCTAssertGreaterThanOrEqual(remaining ?? 0, 5)
        XCTAssertLessThanOrEqual(remaining ?? 0, 6)
        XCTAssertNil(
            RefreshExecutionPolicy.remainingBackoffSeconds(
                until: Date().addingTimeInterval(-1)
            )
        )
    }

    func testInFlightDecisionRecoversStaleLoadingAndSkipsFreshLoading() {
        let staleDecision = RefreshExecutionPolicy.inFlightDecision(
            isLoading: true,
            startedAt: Date(timeIntervalSinceNow: -95),
            staleAfter: 90
        )
        let freshDecision = RefreshExecutionPolicy.inFlightDecision(
            isLoading: true,
            startedAt: Date(timeIntervalSinceNow: -10),
            staleAfter: 90
        )

        switch staleDecision {
        case .recoverStale(let elapsed):
            XCTAssertGreaterThanOrEqual(elapsed, 90)
        default:
            XCTFail("오래된 in-flight refresh는 recoverStale 이어야 합니다")
        }

        guard case .skip = freshDecision else {
            return XCTFail("신선한 in-flight refresh는 skip 이어야 합니다")
        }
    }

    func testNextBackoffDateUsesRetryAfterWhenItExceedsMinimumInterval() {
        let start = Date()
        let result = RefreshExecutionPolicy.nextBackoffDate(
            for: .rateLimited(retryAfter: 45),
            minimumInterval: 20,
            existingAllowedAt: nil
        )

        XCTAssertEqual(result.seconds, 45)
        guard let interval = result.candidate?.timeIntervalSince(start) else {
            return XCTFail("백오프 candidate가 생성되어야 합니다")
        }
        XCTAssertGreaterThanOrEqual(interval, 44)
        XCTAssertLessThanOrEqual(interval, 46)
    }

    func testNextBackoffDateKeepsLongerExistingBackoff() {
        let existingAllowedAt = Date(timeIntervalSinceNow: 120)
        let result = RefreshExecutionPolicy.nextBackoffDate(
            for: .networkError("offline"),
            minimumInterval: 15,
            existingAllowedAt: existingAllowedAt
        )

        guard let candidate = result.candidate else {
            return XCTFail("기존 backoff 시각을 유지해야 합니다")
        }
        XCTAssertEqual(candidate.timeIntervalSince1970, existingAllowedAt.timeIntervalSince1970, accuracy: 0.1)
        XCTAssertNil(result.seconds)
    }

    func testNextBackoffDateSkipsDefinitiveFailures() {
        let result = RefreshExecutionPolicy.nextBackoffDate(
            for: .invalidSessionKey,
            minimumInterval: 30,
            existingAllowedAt: nil
        )

        XCTAssertNil(result.candidate)
        XCTAssertNil(result.seconds)
    }
}
