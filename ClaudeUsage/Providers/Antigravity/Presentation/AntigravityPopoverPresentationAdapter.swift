import Foundation

nonisolated enum AntigravityPopoverPresentationAdapter {
    static func statusSummary(
        for snapshot: AntigravityRuntimeSnapshot
    ) -> ProviderRuntimeSummary {
        switch snapshot.readiness {
        case .bootstrapping:
            return summary(
                showsProgress: true,
                title: "Antigravity 준비 중",
                message: nil
            )
        case .blocked(let blocker):
            return summary(
                icon: "exclamationmark.shield",
                tone: .critical,
                title: "설정 오류",
                message: blockerMessage(blocker),
                actionTitle: "설정 열기",
                action: .openSettings,
                actionIsProminent: true
            )
        case .shuttingDown:
            return summary(
                showsProgress: true,
                title: "Antigravity 종료 중",
                message: nil
            )
        case .idle, .ready:
            break
        }

        switch snapshot.presentationState {
        case .disabled:
            return summary(
                icon: "pause.circle",
                title: "Antigravity 사용 중지됨",
                message: "설정에서 Antigravity를 켜면 사용량을 확인합니다.",
                actionTitle: "설정 열기",
                action: .openSettings
            )
        case .refreshing:
            return summary(
                showsProgress: true,
                title: "사용량 확인 중",
                message: nil
            )
        case .failed(let failure):
            return failureSummary(failure)
        case .ready, .partial, .stale:
            return summary(
                icon: "exclamationmark.triangle",
                tone: .warning,
                title: "표시 오류",
                message: "사용량을 표시하지 못했습니다. 다시 시도하세요.",
                actionTitle: "다시 시도",
                action: .retry
            )
        }
    }

    private static func blockerMessage(
        _ blocker: AntigravityRuntimeBlocker
    ) -> String {
        switch blocker {
        case .settingsMigration:
            "기존 Antigravity 설정을 옮기지 못했습니다. 설정을 확인하세요."
        case .typedSettings:
            "자동 조회 설정을 불러오지 못했습니다. 설정을 다시 여세요."
        }
    }

    static func failureSummary(
        _ failure: AntigravityFailure
    ) -> ProviderRuntimeSummary {
        let presentation = AntigravityFailurePresentation(failure)
        switch presentation.remedy {
        case .settings:
            return settingsFailure(title: presentation.title, message: presentation.message)
        case .retry, .signIn:
            return retryFailure(title: presentation.title, message: presentation.message)
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
        message: String
    ) -> ProviderRuntimeSummary {
        summary(
            icon: "exclamationmark.triangle",
            tone: .warning,
            title: title,
            message: message,
            actionTitle: "다시 시도",
            action: .retry
        )
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
            actionIsProminent: actionIsProminent
        )
    }
}
