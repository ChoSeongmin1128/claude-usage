import Foundation

nonisolated enum CatalogPopoverPresentationAdapter {
    static func statusSummary(
        phase: PopoverContentPhase,
        error: APIError?,
        service: PopoverService,
        claudeUsesCodeCredentials: Bool = false
    ) -> ProviderRuntimeSummary? {
        switch phase {
        case .content:
            return nil
        case .authRequired:
            if service == .claude {
                return summary(
                    icon: "person.badge.key",
                    tone: .warning,
                    title: "Claude 로그인 필요",
                    message:
                        "Chrome 또는 Claude Code 로그인을 연결해 주세요.",
                    actionTitle: "로그인 시작",
                    action: .startClaudeLogin,
                    actionIsProminent: true
                )
            }
            return summary(
                icon: "lock.shield",
                tone: .warning,
                title: "연결 필요",
                message:
                    "인증이 필요합니다. 설정에서 연결을 다시 확인해 주세요.",
                actionTitle: "설정 열기",
                action: .openSettings,
                actionIsProminent: true
            )
        case .loading:
            return summary(
                showsProgress: true,
                title: "데이터 로딩 중",
                message:
                    "현재 연결 상태를 확인하고 있습니다."
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
                "표시 편집에서 최소 한 항목을 선택해 주세요.",
            actionTitle: "표시 편집",
            action: .openDisplayEditor
        )
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
                        "터미널에서 `claude auth login`을 다시 실행한 뒤 사용량 새로고침을 눌러 주세요."
                )
            case .claude:
                return summary(
                    icon:
                        "exclamationmark.triangle",
                    tone: .critical,
                    title: "Claude 로그인 만료",
                    message:
                        "Claude.ai 로그인이 만료됐습니다. 메뉴바의 'Claude 로그인 시작'으로 다시 연결해 주세요.",
                    actionTitle:
                        "Claude 로그인 시작",
                    action:
                        .startClaudeLogin,
                    actionIsProminent: true
                )
            case .codex:
                return settingsFailure(
                    title:
                        "Codex 로그인 만료",
                    message:
                        "터미널에서 `codex login`을 다시 실행한 뒤 사용량 새로고침을 눌러 주세요."
                )
            case .antigravity:
                return settingsFailure(
                    title:
                        "Antigravity 연결 필요",
                    message:
                        "Antigravity 연결 토큰이 만료됐거나 Google 계정 연결을 갱신할 수 없습니다. 설정에서 연결 상태를 확인해 주세요."
                )
            }
        case .claudeCodeCredentialUnavailable:
            return settingsFailure(
                title:
                    "Claude Code 자격 증명 없음",
                message:
                    "Claude Code 로그인 정보를 찾을 수 없습니다. 터미널에서 `claude auth login`을 실행한 뒤 다시 확인해 주세요."
            )
        case .claudeCodeReauthenticationRequired:
            return settingsFailure(
                title:
                    "Claude Code 인증 갱신 필요",
                message:
                    "로그인 파일은 있지만 refresh token이 더 이상 유효하지 않습니다. 터미널에서 `claude auth login`을 한 번 다시 실행해 주세요."
            )
        case .claudeCodeReconnectRequired:
            return settingsFailure(
                title:
                    "Claude Code 연결 확인 필요",
                message:
                    "Claude Code 로그인은 유지되고 있지만 현재 연결 정보를 사용할 수 없습니다. 설정에서 다시 연결해 주세요."
            )
        case .codexReauthRequired(let reason):
            return settingsFailure(
                title:
                    "Codex 재로그인 필요",
                message:
                    "Codex 토큰이 영구 무효화됐습니다. 터미널에서 `codex login`을 다시 실행해 주세요. (\(reason))"
            )
        case .codexTokenRefreshTemporary(
            let reason
        ):
            return retryFailure(
                title: "Codex 갱신 일시 실패",
                message:
                    reason.isEmpty
                    ? "Codex 토큰 갱신 서버가 일시적으로 응답하지 않았습니다. 잠시 후 자동 재시도합니다."
                    : "Codex 토큰 갱신 서버가 일시적으로 응답하지 않았습니다. 잠시 후 자동 재시도합니다. (\(reason))",
                actionTitle: "지금 다시 시도"
            )
        case .cloudflareBlocked(let retryAfter):
            return retryFailure(
                title: "일시 차단됨",
                message:
                    "Cloudflare가 잠시 호출을 차단했습니다. \(formatRetryDuration(retryAfter)) 자동 재시도합니다.",
                actionTitle: "지금 다시 시도"
            )
        case .rateLimited(let retryAfter):
            return retryFailure(
                title: "조회 한도 도달",
                message:
                    "\(service.displayName) 사용량 조회가 잠시 제한됐습니다. \(formatRetryDuration(retryAfter)) 자동 재시도합니다.",
                actionTitle: "지금 다시 시도"
            )
        case .networkError(let detail):
            return retryFailure(
                title: "네트워크 오류",
                message:
                    "인터넷 연결을 확인해 주세요. (\(detail))"
            )
        case .permissionDenied(let detail):
            return summary(
                icon:
                    "exclamationmark.triangle",
                tone: .warning,
                title: "조회 권한 없음",
                message:
                    detail.isEmpty
                    ? "이 계정으로 해당 사용량 API를 호출할 권한이 없습니다."
                    : detail,
                actionTitle: "설정 열기",
                action: .openSettings
            )
        case .parseError:
            return retryFailure(
                title: "응답 형식 변경",
                message:
                    "응답 형식이 달라 파싱하지 못했습니다. 앱 업데이트가 있는지 확인해 주세요."
            )
        case .serverError(let code):
            return retryFailure(
                title: "서버 오류",
                message:
                    "원격 서버가 HTTP \(code)로 응답했습니다. 잠시 후 다시 시도해 주세요."
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
        message: String,
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
