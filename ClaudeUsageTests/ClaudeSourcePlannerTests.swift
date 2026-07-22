import XCTest
@testable import ClaudeUsage

final class ClaudeSourcePlannerTests: XCTestCase {
    func testRecentSuccessPreferenceKeepsRecentOAuthFirst() {
        let planner = ClaudeSourcePlanner()
        let context = ClaudeFetchContext(
            sourcePreference: .recentSuccess,
            webSessionAvailable: true,
            oauthAvailable: true,
            recentSuccessfulSource: .oauth,
            currentUsagePercent: 72,
            fallbackPolicy: .init(isEnabled: true, allowAutomaticFallback: true, minimumUsagePercent: 50)
        )

        let plan = planner.makePlan(from: context)

        XCTAssertEqual(plan.primaryCandidates.map(\.source), [.oauth, .webSession])
        XCTAssertEqual(plan.preferredPrimarySource, .oauth)
        XCTAssertEqual(plan.fallbackSource, .messagesHeaderFallback)
        XCTAssertTrue(plan.shouldAttemptAutomaticFallback)
    }

    func testAutoPreferenceIgnoresMessagesFallbackAsRecentSuccess() {
        let planner = ClaudeSourcePlanner()
        let context = ClaudeFetchContext(
            sourcePreference: .auto,
            webSessionAvailable: true,
            oauthAvailable: true,
            recentSuccessfulSource: .messagesHeaderFallback
        )

        let plan = planner.makePlan(from: context)

        XCTAssertEqual(plan.primaryCandidates.map(\.source), [.webSession, .oauth])
        XCTAssertEqual(plan.primaryCandidates.map(\.reason), ["default-web-session-first", "default-oauth-fallback"])
        XCTAssertEqual(plan.preferredPrimarySource, .webSession)
    }

    func testAutomaticFallbackStaysDisabledBelowThreshold() {
        let planner = ClaudeSourcePlanner()
        let context = ClaudeFetchContext(
            sourcePreference: .auto,
            webSessionAvailable: false,
            oauthAvailable: true,
            recentSuccessfulSource: .oauth,
            currentUsagePercent: 19,
            fallbackPolicy: .init(isEnabled: true, allowAutomaticFallback: true, minimumUsagePercent: 20)
        )

        let plan = planner.makePlan(from: context)

        XCTAssertEqual(plan.preferredPrimarySource, .oauth)
        XCTAssertFalse(plan.shouldAttemptAutomaticFallback)
    }

    func testFailedWebSessionPrioritizesDetectedOAuth() {
        let planner = ClaudeSourcePlanner()
        let context = ClaudeFetchContext(
            sourcePreference: .auto,
            webSessionAvailable: true,
            oauthAvailable: true,
            webSessionValidationState: .failed,
            oauthValidationState: .detected,
            recentSuccessfulSource: .webSession
        )

        let plan = planner.makePlan(from: context)

        XCTAssertEqual(plan.primaryCandidates.map(\.source), [.oauth, .webSession])
        XCTAssertEqual(plan.preferredPrimarySource, .oauth)
    }

    func testRecentSuccessSourceIsNotPreferredWhenCredentialUnavailable() {
        let planner = ClaudeSourcePlanner()
        let context = ClaudeFetchContext(
            sourcePreference: .recentSuccess,
            webSessionAvailable: false,
            oauthAvailable: true,
            recentSuccessfulSource: .webSession
        )

        let plan = planner.makePlan(from: context)

        XCTAssertEqual(plan.primaryCandidates.map(\.source), [.webSession, .oauth])
        XCTAssertEqual(plan.preferredPrimarySource, .oauth)
    }

    func testMessagesFallbackIsNeverPrimaryCandidate() {
        let planner = ClaudeSourcePlanner()
        let context = ClaudeFetchContext(
            sourcePreference: .auto,
            webSessionAvailable: false,
            oauthAvailable: true,
            recentSuccessfulSource: .messagesHeaderFallback,
            currentUsagePercent: 90,
            fallbackPolicy: .init(isEnabled: true, allowAutomaticFallback: true, minimumUsagePercent: 20)
        )

        let plan = planner.makePlan(from: context)

        XCTAssertFalse(plan.primaryCandidates.map(\.source).contains(.messagesHeaderFallback))
        XCTAssertEqual(plan.fallbackSource, .messagesHeaderFallback)
        XCTAssertTrue(plan.shouldAttemptAutomaticFallback)
    }

    func testExplicitWebAccountDoesNotFallbackToOAuthWhenWebSessionFails() {
        // 사용자가 명시적으로 선택/추가한 web 계정(Chrome 프로파일, 직접 입력 등)은
        // OAuth 토큰이 있어도 자동으로 다른 계정 자격으로 폴백하지 않는다.
        // "내가 회사 계정으로 보겠다" 는 의지가 다른 OAuth 사용자 사용량으로 잠식되지 않게 한다.
        let planner = ClaudeSourcePlanner()
        let context = ClaudeFetchContext(
            accountKind: .webSession,
            sourcePreference: .auto,
            webSessionAvailable: false,
            oauthAvailable: true,
            webSessionValidationState: .failed,
            oauthValidationState: .detected
        )

        let plan = planner.makePlan(from: context)

        XCTAssertEqual(plan.primaryCandidates.map(\.source), [.webSession])
        XCTAssertNil(plan.preferredPrimarySource)
    }

    func testMigratedWebAccountStillDoesNotCrossAccountBoundary() {
        // 마이그레이션 유래 여부는 인증 경계를 바꾸지 않는다. 웹 세션이 만료되어도
        // 다른 사용자일 수 있는 시스템 Claude Code 자격으로 자동 전환하지 않는다.
        let planner = ClaudeSourcePlanner()
        let context = ClaudeFetchContext(
            accountKind: .webSession,
            sourcePreference: .auto,
            webSessionAvailable: false,
            oauthAvailable: true,
            webSessionValidationState: .failed,
            oauthValidationState: .detected
        )

        let plan = planner.makePlan(from: context)

        XCTAssertEqual(plan.primaryCandidates.map(\.source), [.webSession])
        XCTAssertEqual(plan.primaryCandidates.map(\.reason), ["active-account-web-session"])
        XCTAssertNil(plan.preferredPrimarySource)
    }

    func testLegacyMigratedWebAccountDoesNotEmitOAuthCandidateWhenTokenUnavailable() {
        // 폴백 대상 OAuth 가 사용 불가하면 candidate 도 출력하지 않는다.
        // 무용한 candidate 가 추가돼서 후속 로직이 헷갈리지 않도록 명시.
        let planner = ClaudeSourcePlanner()
        let context = ClaudeFetchContext(
            accountKind: .webSession,
            sourcePreference: .auto,
            webSessionAvailable: true,
            oauthAvailable: false
        )

        let plan = planner.makePlan(from: context)

        XCTAssertEqual(plan.primaryCandidates.map(\.source), [.webSession])
    }

    func testWebAccountNeverEmitsOAuthCandidateEvenWhenBothCredentialsExist() {
        let planner = ClaudeSourcePlanner()
        let context = ClaudeFetchContext(
            accountKind: .webSession,
            sourcePreference: .auto,
            webSessionAvailable: true,
            oauthAvailable: true
        )

        let plan = planner.makePlan(from: context)

        XCTAssertEqual(plan.primaryCandidates.map(\.source), [.webSession])
        XCTAssertEqual(plan.preferredPrimarySource, .webSession)
    }

    func testClaudeCodeAccountUsesOnlyOAuth() {
        let planner = ClaudeSourcePlanner()
        let context = ClaudeFetchContext(
            accountKind: .claudeCodeExternal,
            sourcePreference: .auto,
            webSessionAvailable: true,
            oauthAvailable: true
        )

        let plan = planner.makePlan(from: context)

        XCTAssertEqual(plan.primaryCandidates.map(\.source), [.oauth])
    }

    func testClaudeCodeAccountDoesNotFallbackToWebSession() {
        let planner = ClaudeSourcePlanner()
        let context = ClaudeFetchContext(
            accountKind: .claudeCodeExternal,
            sourcePreference: .recentSuccess,
            webSessionAvailable: true,
            oauthAvailable: false,
            webSessionValidationState: .verified,
            oauthValidationState: .failed,
            recentSuccessfulSource: .webSession
        )

        let plan = planner.makePlan(from: context)

        XCTAssertEqual(plan.primaryCandidates.map(\.source), [.oauth])
        XCTAssertNil(plan.preferredPrimarySource)
    }
}
