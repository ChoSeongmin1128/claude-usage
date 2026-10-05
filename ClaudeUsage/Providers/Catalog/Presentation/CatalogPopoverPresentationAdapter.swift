import Foundation

nonisolated enum CatalogPopoverPresentationAdapter {
    static func statusSummary(
        phase: PopoverContentPhase,
        error: APIError?,
        service: PopoverService,
        claudeUsesCodeCredentials: Bool = false,
        claudeCodeCredentialIssue: ClaudeCodeCredentialIssue? = nil
    ) -> ProviderRuntimeSummary? {
        switch phase {
        case .content:
            return nil
        case .authRequired:
            if service == .claude {
                return claudeAuthRequiredSummary(
                    claudeCodeCredentialIssue: claudeCodeCredentialIssue
                )
            }
            return summary(
                icon: "lock.shield",
                tone: .warning,
                title: "로그인 필요",
                message:
                    "설정에서 로그인을 확인하세요.",
                actionTitle: "설정 열기",
                action: .openSettings,
                actionIsProminent: true
            )
        case .loading:
            return summary(
                showsProgress: true,
                title: "불러오는 중",
                message: nil
            )
        case .error:
            guard let error else {
                return summary(
                    icon:
                        "exclamationmark.triangle",
                    tone: .warning,
                    title: "조회 실패",
                    message:
                        "오류 세부 정보를 확인하지 못했습니다.",
                    actionTitle: "다시 시도",
                    action: .retry
                )
            }
            return errorSummary(
                error,
                service: service,
                claudeUsesCodeCredentials:
                    claudeUsesCodeCredentials
            )
        case .empty:
            return summary(
                icon: "tray",
                title: "데이터 없음",
                message:
                    "아직 가져온 사용량이 없습니다."
            )
        }
    }

    static func emptySelectionSummary()
        -> ProviderRuntimeSummary
    {
        summary(
            icon: "slider.horizontal.3",
            title: "표시할 항목 없음",
            message:
                "팝업 표시 설정에서 한 항목 이상 고르세요.",
            actionTitle: "팝업 표시 설정",
            action: .openDisplaySettings
        )
    }

    // 팝오버 미인증 패널의 간소화/일반 보기가 같은 문구를 쓴다.
    static func claudeAuthRequiredSummary(
        claudeCodeCredentialIssue: ClaudeCodeCredentialIssue?
    ) -> ProviderRuntimeSummary {
        switch claudeCodeCredentialIssue {
        case .reconnectRequired:
            return summary(
                icon: "arrow.triangle.2.circlepath",
                tone: .warning,
                title: "Claude Code 다시 연결 필요",
                message:
                    "Claude Code 로그인을 다시 가져와야 합니다.",
                actionTitle: "다시 연결",
                action: .startClaudeLogin,
                actionIsProminent: true
            )
        case .reauthenticationRequired:
            return summary(
                icon: "person.badge.key",
                tone: .warning,
                title: "Claude Code 로그인 만료",
                message:
                    "터미널에서 `claude auth login`을 실행한 뒤 다시 연결하세요.",
                actionTitle: "다시 연결",
                action: .startClaudeLogin,
                actionIsProminent: true
            )
        case .executableNotFound:
            return claudeExecutableNotFoundSummary()
        case nil:
            return summary(
                icon: "person.badge.key",
                tone: .warning,
                title: "Claude 로그인 필요",
                message:
                    "브라우저, Claude 앱, Claude Code 로그인을 가져옵니다.",
                actionTitle: "로그인 시작",
                action: .startClaudeLogin,
                actionIsProminent: true
            )
        }
    }

    private static func errorSummary(
        _ error: APIError,
        service: PopoverService,
        claudeUsesCodeCredentials: Bool
    ) -> ProviderRuntimeSummary {
        switch error {
        case .invalidSessionKey:
            switch service {
            case .claude
                where claudeUsesCodeCredentials:
                return settingsFailure(
                    title:
                        "Claude Code 로그인 만료",
                    message:
                        "터미널에서 `claude auth login`을 실행한 뒤 새로고침하세요."
                )
            case .claude:
                return summary(
                    icon:
                        "exclamationmark.triangle",
                    tone: .critical,
                    title: "Claude 로그인 만료",
                    message:
                        "claude.ai 로그인이 만료됐습니다.",
                    actionTitle:
                        "로그인 시작",
                    action:
                        .startClaudeLogin,
                    actionIsProminent: true
                )
            case .codex:
                return settingsFailure(
                    title:
                        "Codex 로그인 만료",
                    message:
                        "터미널에서 `codex login`을 실행한 뒤 새로고침하세요."
                )
            case .antigravity:
                return settingsFailure(
                    title:
                        "Antigravity 다시 연결 필요",
                    message:
                        "설정에서 Antigravity를 다시 연결하세요."
                )
            }
        case .claudeCodeCredentialUnavailable:
            return settingsFailure(
                title:
                    "Claude Code 로그인 없음",
                message:
                    "터미널에서 `claude auth login`을 실행하세요."
            )
        case .claudeCodeReauthenticationRequired:
            return settingsFailure(
                title:
                    "Claude Code 로그인 만료",
                message:
                    "터미널에서 `claude auth login`을 실행하세요."
            )
        case .claudeCodeReconnectRequired:
            return settingsFailure(
                title:
                    "Claude Code 다시 연결 필요",
                message:
                    "설정에서 Claude Code를 다시 연결하세요."
            )
        case .claudeCodeExecutableNotFound:
            return claudeExecutableNotFoundSummary()
        case .codexReauthRequired:
            return settingsFailure(
                title:
                    "Codex 로그인 만료",
                message:
                    "터미널에서 `codex login`을 실행하세요."
            )
        case .codexTokenRefreshTemporary:
            return retryFailure(
                title: "Codex 응답 없음",
                message:
                    "Codex 서버가 응답하지 않습니다. 잠시 뒤 다시 시도합니다.",
                actionTitle: "지금 다시 시도"
            )
        case .cloudflareBlocked(let retryAfter):
            return retryFailure(
                title: "요청 막힘",
                message:
                    "요청이 잠시 막혔습니다. \(formatRetryDuration(retryAfter)) 다시 시도합니다.",
                actionTitle: "지금 다시 시도"
            )
        case .rateLimited(let retryAfter):
            return retryFailure(
                title: "요청 제한",
                message:
                    "\(service.displayName) 사용량 조회가 잠시 제한됐습니다. \(formatRetryDuration(retryAfter)) 다시 시도합니다.",
                actionTitle: "지금 다시 시도"
            )
        case .networkError(let detail):
            return retryFailure(
                title: "네트워크 오류",
                message:
                    "인터넷 연결을 확인하세요. (\(detail))"
            )
        case .permissionDenied(let detail):
            return summary(
                icon:
                    "exclamationmark.triangle",
                tone: .warning,
                title: "조회 권한 없음",
                message:
                    detail.isEmpty
                    ? "이 계정은 사용량을 볼 권한이 없습니다."
                    : detail,
                actionTitle: "설정 열기",
                action: .openSettings
            )
        case .parseError:
            return retryFailure(
                title: "응답 형식 변경",
                message:
                    "응답을 읽지 못했습니다. 앱을 업데이트하세요."
            )
        case .serverError(let code):
            return retryFailure(
                title: "서버 오류",
                message:
                    "서버가 오류(HTTP \(code))를 보냈습니다. 잠시 뒤 다시 시도하세요."
            )
        case .unknownError(let detail):
            return retryFailure(
                title: "조회 실패",
                message:
                    detail.isEmpty
                    ? "원인을 파악하지 못했습니다."
                    : detail
            )
        }
    }

    private static func claudeExecutableNotFoundSummary() -> ProviderRuntimeSummary {
        summary(
            icon: "terminal", tone: .warning, title: "Claude Code를 찾지 못함",
            message: ClaudeCodeCredentialIssue.executableNotFoundExplanation,
            actionTitle: "설정 열기", action: .openSettings)
    }

    private static func settingsFailure(
        title: String,
        message: String
    ) -> ProviderRuntimeSummary {
        summary(
            icon: "exclamationmark.triangle",
            tone: .critical,
            title: title,
            message: message,
            actionTitle: "설정 열기",
            action: .openSettings,
            actionIsProminent: true
        )
    }

    private static func retryFailure(
        title: String,
        message: String,
        actionTitle: String = "다시 시도"
    ) -> ProviderRuntimeSummary {
        summary(
            icon: "exclamationmark.triangle",
            tone: .warning,
            title: title,
            message: message,
            actionTitle: actionTitle,
            action: .retry
        )
    }

    private static func formatRetryDuration(
        _ seconds: Int?
    ) -> String {
        guard let seconds, seconds > 0 else {
            return "잠시 후"
        }
        if seconds >= 3_600 {
            let hours = seconds / 3_600
            let minutes =
                (seconds % 3_600) / 60
            return minutes > 0
                ? "약 \(hours)시간 \(minutes)분 후"
                : "약 \(hours)시간 후"
        }
        if seconds >= 60 {
            return "약 \((seconds + 30) / 60)분 후"
        }
        return "\(seconds)초 후"
    }

    private static func summary(
        icon: String? = nil,
        tone: ProviderRuntimeSummary.Tone =
            .secondary,
        showsProgress: Bool = false,
        title: String,
        message: String?,
        actionTitle: String? = nil,
        action: ProviderRuntimeSummary.Action? =
            nil,
        actionIsProminent: Bool = false
    ) -> ProviderRuntimeSummary {
        ProviderRuntimeSummary(
            icon: icon,
            tone: tone,
            showsProgress: showsProgress,
            title: title,
            message: message,
            actionTitle: actionTitle,
            action: action,
            actionIsProminent:
                actionIsProminent
        )
    }
}
