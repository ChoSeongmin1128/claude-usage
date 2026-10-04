import Foundation

nonisolated enum AntigravitySettingsNoticePresenter {
    static func notice(
        for snapshot: AntigravityRuntimeSnapshot
    ) -> AntigravitySettingsNotice? {
        if case .blocked(let blocker) =
            snapshot.readiness
        {
            return blockedNotice(blocker)
        }
        return displayMigrationNotice(
            snapshot.settings?.display
                .pendingNotice
        )
            ?? refreshOutcomeNotice(
                snapshot.presentationState
            )
    }

    static func mutationFailureNotice(
        for activity:
            AntigravitySettingsViewState.Activity,
        error: Error
    ) -> AntigravitySettingsNotice {
        let title: String
        switch activity {
        case .changingConnection:
            title =
                "연결 설정을 저장하지 못했습니다"
        case .changingDisplay:
            title =
                "표시 설정을 저장하지 못했습니다"
        case .idle,
            .loading:
            title =
                "Antigravity 설정을 변경하지 못했습니다"
        }

        let message: String
        let controllerError =
            error as? AntigravityRuntimeControllerError
        if controllerError == .appShuttingDown {
            message =
                "앱이 종료 중이라 변경을 시작하지 않았습니다."
        } else if controllerError
            == .operationSuperseded
        {
            message = "다른 곳에서 설정이 바뀌어 이 변경은 적용하지 않았습니다."
        } else {
            message = "저장된 설정을 다시 읽었습니다. 다시 시도하세요."
        }
        return AntigravitySettingsNotice(
            tone: .failure,
            title: title,
            message: message,
            action: .retryLoad
        )
    }

    /// 설정 패널의 상태 배지 아래에 할 일을 보여준다. 정상이거나 확인 중이면 없다.
    static func refreshOutcomeNotice(
        _ presentation:
            AntigravityPresentationState
    ) -> AntigravitySettingsNotice? {
        let login = "터미널에서 agy를 실행해 로그인한 뒤 새로고침하세요."
        switch presentation {
        case .ready, .refreshing, .disabled:
            return nil
        case .partial:
            return warning(title: "일부 한도만 읽었습니다", message: "읽지 못한 한도는 비워 두었습니다.")
        case .limited, .identityOnly:
            return warning(title: "사용량 수치가 없습니다", message: "AGY CLI가 이 계정의 사용량 수치를 주지 않았습니다.")
        case .stale(_, let reason):
            let summary = AntigravityPopoverPresentationAdapter.failureSummary(reason)
            return warning(title: "이전 값을 보여줍니다", message: summary.message ?? summary.title)
        case .setupRequired(.ambiguousLocalSessions):
            return warning(title: "실행 중인 AGY의 계정이 서로 다릅니다", message: "AGY를 하나만 남긴 뒤 새로고침하세요.")
        case .setupRequired:
            return warning(title: "AGY CLI 로그인이 필요합니다", message: login)
        case .accountMismatch:
            return failure(title: "조회 중 계정이 바뀌었습니다", message: "다른 계정의 수치는 숨겼습니다. 새로고침하세요.")
        case .failed(let reason):
            let summary = AntigravityPopoverPresentationAdapter.failureSummary(reason)
            return failure(title: summary.title, message: summary.message ?? summary.title)
        }
    }

    private static func displayMigrationNotice(
        _ notice:
            AntigravitySettingsMigrationNotice?
    ) -> AntigravitySettingsNotice? {
        guard let notice else {
            return nil
        }
        return AntigravitySettingsNotice(
            tone: .success,
            title: notice.title,
            message: notice.message,
            action:
                .acknowledgeDisplayMigrationNotice
        )
    }

    private static func blockedNotice(
        _ blocker: AntigravityRuntimeBlocker
    ) -> AntigravitySettingsNotice {
        let detail: String
        switch blocker {
        case .settingsMigration:
            detail =
                "기존 표시 설정을 옮기지 못해 새 설정을 저장하지 않았습니다."
        case .typedSettings:
            detail =
                "Antigravity 설정을 읽지 못했습니다. 설정은 바꾸지 않았습니다."
        }
        return AntigravitySettingsNotice(
            tone: .failure,
            title:
                "Antigravity를 준비하지 못했습니다",
            message: detail,
            action: .retryLoad
        )
    }

    private static func warning(
        title: String,
        message: String
    ) -> AntigravitySettingsNotice {
        AntigravitySettingsNotice(
            tone: .warning,
            title: title,
            message: message,
            action: .dismiss
        )
    }

    private static func failure(
        title: String,
        message: String
    ) -> AntigravitySettingsNotice {
        AntigravitySettingsNotice(
            tone: .failure,
            title: title,
            message: message,
            action: .dismiss
        )
    }
}
