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
        return migrationNotice(
            snapshot.migrationStatus
        )
            ?? displayMigrationNotice(
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
        case .changingAccount:
            title =
                "Google 계정 변경을 저장하지 못했습니다"
        case .changingConnection:
            title =
                "연결 설정을 저장하지 못했습니다"
        case .changingDisplay:
            title =
                "표시 설정을 저장하지 못했습니다"
        case .migrating:
            title =
                "이전 작업을 완료하지 못했습니다"
        case .idle,
             .loading,
             .checkingMigration,
             .authenticating:
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
            message =
                "다른 창이나 더 최근 작업에서 설정이 변경되어 이 결과는 적용하지 않았습니다. 현재 상태를 확인해 주세요."
        } else {
            message =
                "저장 상태를 다시 읽어 화면을 동기화했습니다. 상태를 확인한 뒤 다시 시도해 주세요."
        }
        return AntigravitySettingsNotice(
            tone: .failure,
            title: title,
            message: message,
            action: .retryLoad
        )
    }

    static func migrationReachedCutover(
        _ status: AntigravityMigrationStatus?
    ) -> Bool {
        guard let status,
              !status.authorizationCancelledThisSession
        else {
            return false
        }
        switch status.phase {
        case .canonicalVerified,
             .cleanupPending,
             .complete:
            return true
        case .notStarted,
             .preflight,
             .blockedBeforeCutover,
             .awaitingImportAuthorization,
             .writingCanonical:
            return false
        }
    }

    static func refreshOutcomeNotice(
        _ presentation:
            AntigravityPresentationState
    ) -> AntigravitySettingsNotice? {
        switch presentation {
        case .ready:
            return nil
        case .partial:
            return warning(
                title: "일부 한도를 읽지 못했습니다",
                message:
                    "확인된 사용량은 유지하고 읽지 못한 항목은 비워 두었습니다."
            )
        case .limited:
            return warning(
                title:
                    "수치형 사용량을 제공하지 않는 연결입니다",
                message:
                    "계정과 연결은 확인했지만 이 경로에서는 quota 수치를 제공하지 않습니다."
            )
        case .identityOnly:
            return warning(
                title:
                    "확인 가능한 사용량 한도가 없습니다",
                message:
                    "계정 정보는 확인했지만 표시할 수 있는 사용량 한도를 받지 못했습니다."
            )
        case .stale:
            return warning(
                title:
                    "새 사용량을 확인하지 못했습니다",
                message:
                    "마지막 확인 데이터는 유지했습니다. 연결 상태를 확인해 주세요."
            )
        case .refreshing:
            return nil
        case .setupRequired(.managedRecoveryBlocked):
            return warning(
                title:
                    "이전 AGY 실행 기록을 정리하지 못했습니다",
                message:
                    "자동 실행이 중지됐습니다. Antigravity 앱이나 AGY CLI를 실행하면 조회는 가능하며, ClaudeUsage를 재시동하면 정리를 다시 시도합니다."
            )
        case .setupRequired:
            return warning(
                title:
                    "사용량 조회 방법을 선택해 주세요",
                message:
                    "Google 계정을 연결하거나 로그인된 Antigravity/AGY 세션을 사용하세요."
            )
        case .accountMismatch:
            return failure(
                title:
                    "선택한 계정과 실행 중인 계정이 다릅니다",
                message:
                    "이전 계정의 수치는 표시하지 않았습니다. Google 계정 또는 Antigravity 로그인을 확인해 주세요."
            )
        case .failed:
            return failure(
                title:
                    "사용량 조회에 실패했습니다",
                message:
                    "계정과 연결 상태를 확인한 뒤 다시 새로고침해 주세요."
            )
        case .disabled:
            return nil
        }
    }

    private static func migrationNotice(
        _ status: AntigravityMigrationStatus?
    ) -> AntigravitySettingsNotice? {
        guard let status else {
            return nil
        }
        if status.authorizationCancelledThisSession {
            return warning(
                title: "이전 인증을 취소했습니다",
                message:
                    "이번 앱 실행에서는 Keychain 인증을 다시 요청하지 않습니다."
            )
        }
        switch status.phase {
        case .complete:
            return nil
        case .notStarted:
            return AntigravitySettingsNotice(
                tone: .warning,
                title:
                    "계정 이전 상태를 확인하지 못했습니다",
                message:
                    "저장된 계정을 변경하기 전에 이전 상태를 다시 확인해 주세요.",
                action: .retryMigrationCheck
            )
        case .preflight,
             .writingCanonical,
             .canonicalVerified:
            return AntigravitySettingsNotice(
                tone: .progress,
                title:
                    "Antigravity 계정 이전 중",
                message:
                    "기존 계정 데이터를 검증하고 있습니다.",
                action: nil
            )
        case .awaitingImportAuthorization:
            return AntigravitySettingsNotice(
                tone: .warning,
                title:
                    "기존 계정 이전이 필요합니다",
                message:
                    "계정을 새 저장소로 옮길 때 Keychain 인증을 한 번 요청할 수 있습니다.",
                action: .continueMigration
            )
        case .cleanupPending:
            let action:
                AntigravitySettingsNotice.Action =
                    status.requiredAction
                        == .removeLegacyCredential
                        ? .removeLegacyData
                        : .continueMigration
            return AntigravitySettingsNotice(
                tone: .warning,
                title:
                    "이전 데이터 정리가 남아 있습니다",
                message:
                    "새 계정 저장은 유지됩니다. 기존 ClaudeUsage 데이터 정리를 다시 진행해 주세요.",
                action: action
            )
        case .blockedBeforeCutover:
            return AntigravitySettingsNotice(
                tone: .failure,
                title:
                    "계정 이전을 시작할 수 없습니다",
                message:
                    "기존 데이터는 삭제하지 않았습니다. 상태를 다시 확인해 주세요.",
                action: .retryMigrationCheck
            )
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
                "기존 표시 설정을 안전하게 이전하지 못해 새 설정 쓰기를 중단했습니다."
        case .canonicalAccountState:
            detail =
                "계정 저장 상태를 검증하지 못했습니다. 기존 데이터는 삭제하지 않았습니다."
        case .typedSettings:
            detail =
                "현재 Antigravity 설정을 읽을 수 없어 자동 초기화하지 않았습니다."
        case .managedRuntimeRecovery:
            detail =
                "ClaudeUsage가 시작한 이전 AGY 프로세스 정리를 확인하지 못했습니다."
        }
        return AntigravitySettingsNotice(
            tone: .failure,
            title:
                "Antigravity 준비를 완료하지 못했습니다",
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
