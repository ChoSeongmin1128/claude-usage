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
            oauthValidationState: .detected,
            webSessionExplicitlySelected: true
        )

        let plan = planner.makePlan(from: context)

        XCTAssertEqual(plan.primaryCandidates.map(\.source), [.webSession])
        XCTAssertNil(plan.preferredPrimarySource)
    }

    func testLegacyMigratedWebAccountFallsBackToOAuthWhenAvailable() {
        // 레거시 `claude-session-key` 자동 마이그레이션으로 생긴 web 계정은 사용자
        // 의지가 명시되지 않은 상태이므로, OAuth(Claude Code CLI) 자격이 있으면
        // secondary candidate 로 추가해 web 실패 시 자동으로 폴백한다.
        // 사용자 시나리오: 업데이트 후 첫 실행에서 만료된 web session 만 마이그레이션되고
        // CLI 로그인은 따로 해 둔 케이스. 사용자가 별도 조작 없이도 사용량이 보이도록.
        let planner = ClaudeSourcePlanner()
        let context = ClaudeFetchContext(
            accountKind: .webSession,
            sourcePreference: .auto,
            webSessionAvailable: false,
            oauthAvailable: true,
            webSessionValidationState: .failed,
            oauthValidationState: .detected,
            webSessionExplicitlySelected: false
        )

        let plan = planner.makePlan(from: context)

        XCTAssertEqual(plan.primaryCandidates.map(\.source), [.webSession, .oauth])
        XCTAssertEqual(plan.primaryCandidates.map(\.reason), ["active-account-web-session", "legacy-web-fallback-to-oauth"])
        XCTAssertEqual(plan.preferredPrimarySource, .oauth)
    }

    func testLegacyMigratedWebAccountDoesNotEmitOAuthCandidateWhenTokenUnavailable() {
        // 폴백 대상 OAuth 가 사용 불가하면 candidate 도 출력하지 않는다.
        // 무용한 candidate 가 추가돼서 후속 로직이 헷갈리지 않도록 명시.
        let planner = ClaudeSourcePlanner()
        let context = ClaudeFetchContext(
            accountKind: .webSession,
            sourcePreference: .auto,
            webSessionAvailable: true,
            oauthAvailable: false,
            webSessionExplicitlySelected: false
        )

        let plan = planner.makePlan(from: context)

        XCTAssertEqual(plan.primaryCandidates.map(\.source), [.webSession])
    }

    func testPreferOAuthFlipsOrderForExplicitWebSessionAccountWhenOAuthAvailable() {
        // 사용자가 "Claude Code OAuth 우선 시도" 설정을 켜면, 명시 선택한 web 계정이어도
        // OAuth 가 primary 후보가 되고 web 은 fallback 으로 내려간다.
        // 활성 계정 = 진실의 출처라는 기본 원칙을 사용자가 의도적으로 뒤집은 케이스.
        let planner = ClaudeSourcePlanner()
        let context = ClaudeFetchContext(
            accountKind: .webSession,
            sourcePreference: .auto,
            webSessionAvailable: true,
            oauthAvailable: true,
            webSessionExplicitlySelected: true,
            preferOAuthOverActiveAccount: true
        )

        let plan = planner.makePlan(from: context)

        XCTAssertEqual(plan.primaryCandidates.map(\.source), [.oauth, .webSession])
        XCTAssertEqual(plan.primaryCandidates.map(\.reason), ["user-prefers-oauth", "user-prefers-oauth-fallback-web"])
        XCTAssertEqual(plan.preferredPrimarySource, .oauth)
    }

    func testPreferOAuthHasNoEffectWhenOAuthTokenIsUnavailable() {
        // preferOAuth 가 켜져 있어도 OAuth 토큰 자체가 없으면 기본 web-first 동작 유지.
        // 사용자가 토글만 켜고 CLI 로그인은 안 한 상태에서 잘못된 빈 candidate 가 생기지 않게.
        let planner = ClaudeSourcePlanner()
        let context = ClaudeFetchContext(
            accountKind: .webSession,
            sourcePreference: .auto,
            webSessionAvailable: true,
            oauthAvailable: false,
            webSessionExplicitlySelected: true,
            preferOAuthOverActiveAccount: true
        )

        let plan = planner.makePlan(from: context)

        XCTAssertEqual(plan.primaryCandidates.map(\.source), [.webSession])
        XCTAssertEqual(plan.preferredPrimarySource, .webSession)
    }

    func testPreferOAuthDoesNotChangeClaudeCodeAccountBehavior() {
        // 활성 계정이 CLI 일 때는 preferOAuth 토글이 무의미(이미 OAuth 만 시도) → 후보 1개 유지.
        let planner = ClaudeSourcePlanner()
        let context = ClaudeFetchContext(
            accountKind: .claudeCodeExternal,
            sourcePreference: .auto,
            webSessionAvailable: true,
            oauthAvailable: true,
            preferOAuthOverActiveAccount: true
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
