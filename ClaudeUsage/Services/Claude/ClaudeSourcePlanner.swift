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
            // 계정 선택은 사용자 의도이자 데이터 귀속 경계다. 시스템 Claude Code OAuth는
            // 다른 계정일 수 있으므로 웹 계정 refresh 중에는 절대로 후보로 섞지 않는다.
            return [
                ClaudeSourceCandidate(
                    source: .webSession,
                    isAvailable: self.isAvailable(.webSession, in: context),
                    reason: "active-account-web-session")
            ]
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
