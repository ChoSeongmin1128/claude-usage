import Foundation

struct ClaudeSourcePlanner {
    nonisolated init() {}

    nonisolated func makePlan(from context: ClaudeFetchContext) -> ClaudeFetchPlan {
        let candidates = self.primaryCandidates(for: context)
        return ClaudeFetchPlan(
            context: context,
            primaryCandidates: candidates,
            fallbackPolicy: context.fallbackPolicy)
    }

    private nonisolated func primaryCandidates(for context: ClaudeFetchContext) -> [ClaudeSourceCandidate] {
        if let accountKind = context.accountKind {
            return accountScopedCandidates(for: accountKind, context: context)
        }

        let orderedSources: [ClaudeUsageSource] = switch context.sourcePreference {
        case .auto:
            self.autoOrder(for: context)
        case .webSession:
            [.webSession, .oauth]
        case .oauth:
            [.oauth, .webSession]
        case .recentSuccess:
            self.recentSuccessOrder(for: context)
        }

        return orderedSources.map { source in
            ClaudeSourceCandidate(
                source: source,
                isAvailable: self.isAvailable(source, in: context),
                reason: self.reason(for: source, context: context))
        }
    }

    private nonisolated func accountScopedCandidates(
        for accountKind: ClaudeAccountKind,
        context: ClaudeFetchContext
    ) -> [ClaudeSourceCandidate] {
        switch accountKind {
        case .webSession:
            // 사용자 설정 "Claude Code OAuth 우선 시도" 가 켜졌고 OAuth 토큰이 있으면
            // 활성 계정이 web 이어도 OAuth 를 primary 로 잡는다. CodexBar 패턴.
            // 명시 선택된 web 계정의 권위를 일시적으로 뒤집는 글로벌 토글이며,
            // OAuth 실패 시 web 으로 자연 폴백된다.
            if context.preferOAuthOverActiveAccount, context.oauthAvailable {
                return [
                    ClaudeSourceCandidate(
                        source: .oauth,
                        isAvailable: self.isAvailable(.oauth, in: context),
                        reason: "user-prefers-oauth"),
                    ClaudeSourceCandidate(
                        source: .webSession,
                        isAvailable: self.isAvailable(.webSession, in: context),
                        reason: "user-prefers-oauth-fallback-web")
                ]
            }

            var candidates: [ClaudeSourceCandidate] = [
                ClaudeSourceCandidate(
                    source: .webSession,
                    isAvailable: self.isAvailable(.webSession, in: context),
                    reason: "active-account-web-session")
            ]
            // 사용자가 명시적으로 선택한 web 계정이 아니라 레거시 자동 마이그레이션
            // 결과(claude-session-key → web 계정)인 경우, 그 sessionKey 가
            // 만료·차단되어 있어도 사용자는 "그냥 안 보임" 으로 인식한다.
            // OAuth 토큰이 사용 가능하면 secondary candidate 로 추가해 안전하게
            // 폴백한다. 명시 선택된 web 계정에는 이 폴백을 적용하지 않아 사용자
            // 의도("회사 web 계정으로만 보겠다") 가 다른 OAuth 자격으로 잠식되지 않게 한다.
            if !context.webSessionExplicitlySelected, context.oauthAvailable {
                candidates.append(
                    ClaudeSourceCandidate(
                        source: .oauth,
                        isAvailable: self.isAvailable(.oauth, in: context),
                        reason: "legacy-web-fallback-to-oauth"))
            }
            return candidates
        case .claudeCodeExternal:
            return [
                ClaudeSourceCandidate(
                    source: .oauth,
                    isAvailable: self.isAvailable(.oauth, in: context),
                    reason: "active-account-claude-code-external")
            ]
        }
    }

    private nonisolated func autoOrder(for context: ClaudeFetchContext) -> [ClaudeUsageSource] {
        if context.webSessionValidationState == .failed,
           context.oauthAvailable {
            return [.oauth, .webSession]
        }
        if let recentSuccessfulSource = context.recentSuccessfulSource,
           recentSuccessfulSource != .messagesHeaderFallback
        {
            return self.recentSuccessOrder(for: context)
        }
        return [.webSession, .oauth]
    }

    private nonisolated func recentSuccessOrder(for context: ClaudeFetchContext) -> [ClaudeUsageSource] {
        guard let recentSuccessfulSource = context.recentSuccessfulSource,
              recentSuccessfulSource != .messagesHeaderFallback
        else {
            return [.webSession, .oauth]
        }

        if recentSuccessfulSource == .webSession,
           context.webSessionValidationState == .failed,
           context.oauthAvailable {
            return [.oauth, .webSession]
        }

        if recentSuccessfulSource == .oauth,
           context.oauthValidationState == .failed,
           context.webSessionAvailable {
            return [.webSession, .oauth]
        }

        let fallback = recentSuccessfulSource == .webSession ? ClaudeUsageSource.oauth : .webSession
        return [recentSuccessfulSource, fallback]
    }

    private nonisolated func isAvailable(_ source: ClaudeUsageSource, in context: ClaudeFetchContext) -> Bool {
        switch source {
        case .webSession:
            context.webSessionAvailable
        case .oauth:
            context.oauthAvailable
        case .messagesHeaderFallback:
            context.fallbackPolicy.isEnabled
        }
    }

    private nonisolated func reason(for source: ClaudeUsageSource, context: ClaudeFetchContext) -> String {
        switch (context.sourcePreference, source) {
        case (.auto, .webSession):
            return "default-web-session-first"
        case (.auto, .oauth):
            return "default-oauth-fallback"
        case (.webSession, .webSession):
            return "explicit-web-session"
        case (.webSession, .oauth):
            return "web-session-then-oauth"
        case (.oauth, .oauth):
            return "explicit-oauth"
        case (.oauth, .webSession):
            return "oauth-then-web-session"
        case (.recentSuccess, _):
            return "recent-success-first"
        default:
            return "auto"
        }
    }
}
