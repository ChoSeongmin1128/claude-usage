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
                message: "계정과 조회 설정을 확인하고 있습니다."
            )
        case .blocked(let blocker):
            return summary(
                icon: "exclamationmark.shield",
                tone: .critical,
                title: "초기 설정 확인 필요",
                message: blockerMessage(blocker),
                actionTitle: "설정 열기",
                action: .openSettings,
                actionIsProminent: true
            )
        case .shuttingDown:
            return summary(
                showsProgress: true,
                title: "Antigravity 종료 중",
                message: "진행 중인 조회를 안전하게 정리하고 있습니다."
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
        case .setupRequired(let reason):
            return summary(
                icon: "person.badge.key",
                tone: .warning,
                title: "조회 계정 또는 로그인 필요",
                message: setupMessage(reason),
                actionTitle: "설정 열기",
                action: .openSettings,
                actionIsProminent: true
            )
        case .refreshing:
            return summary(
                showsProgress: true,
                title: "사용량 확인 중",
                message: "선택한 계정에 맞는 조회 경로를 자동으로 다시 확인하고 있습니다."
            )
        case .accountMismatch:
            return summary(
                icon:
                    "person.crop.circle.badge.exclamationmark",
                tone: .critical,
                title: "계정이 일치하지 않음",
                message: "선택한 계정과 다른 세션의 숫자는 표시하지 않았습니다. 조회 계정을 다시 선택해 주세요.",
                actionTitle: "설정 열기",
                action: .openSettings,
                actionIsProminent: true
            )
        case .limited:
            return summary(
                icon: "chart.bar.doc.horizontal",
                tone: .warning,
                title: "수치형 사용량 미지원",
                message: "현재 연결은 계정과 기능만 확인하며 표시 가능한 quota 수치를 제공하지 않습니다.",
                actionTitle: "계정 확인",
                action: .openSettings
            )
        case .identityOnly(let observation):
            let account =
                observation.identity.email
                    ?? observation.identity
                        .stableAccountID
                    ?? "연결된 계정"
            return summary(
                icon: "person.crop.circle",
                tone: .warning,
                title: "계정만 확인됨",
                message:
                    "\(account)은(는) 확인했지만 표시 가능한 quota 수치를 받지 못했습니다.",
                actionTitle: "계정 확인",
                action: .openSettings
            )
        case .failed(let failure):
            return failureSummary(failure)
        case .ready, .partial, .stale:
            return summary(
                icon: "exclamationmark.triangle",
                tone: .warning,
                title: "표시 데이터 확인 필요",
                message: "검증된 사용량 presentation을 만들지 못했습니다. 다시 조회해 주세요.",
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
            "기존 Antigravity 설정 이전을 완료하지 못했습니다. 설정에서 이전 상태를 확인해 주세요."
        case .canonicalAccountState:
            "계정 저장 상태를 검증하지 못했습니다. 설정에서 계정을 다시 확인해 주세요."
        case .typedSettings:
            "자동 조회 설정을 준비하지 못했습니다. 설정을 다시 열어 상태를 확인해 주세요."
        case .managedRuntimeRecovery:
            "이전 AGY 실행을 안전하게 정리하지 못했습니다. 설정의 진단 항목을 확인해 주세요."
        }
    }

    private static func setupMessage(
        _ reason: AntigravitySetupReason
    ) -> String {
        switch reason {
        case .noSelectedOAuthAccount:
            "Google 계정을 연결한 뒤 사용할 계정을 선택해 주세요."
        case .noAmbientLocalSession:
            "Antigravity 앱 또는 AGY CLI에 로그인한 뒤 로컬 세션 조회를 다시 시도해 주세요."
        }
    }

    private static func failureSummary(
        _ failure: AntigravityFailure
    ) -> ProviderRuntimeSummary {
        switch failure {
        case .authenticationRequired, .interactionRequired:
            settingsFailure(
                title: "Google 계정 다시 연결 필요",
                message: "현재 계정의 인증을 갱신할 수 없습니다. 설정에서 Google 계정을 다시 연결해 주세요."
            )
        case .selectedAccountUnavailable,
             .selectedAccountIdentityUnavailable:
            settingsFailure(
                title: "선택한 계정 확인 필요",
                message: "선택한 계정이 없거나 계정 경계를 검증할 수 없습니다. 설정에서 사용할 계정을 다시 선택해 주세요."
            )
        case .credentialCommitFailed,
             .credentialCommitAmbiguous:
            settingsFailure(
                title: "계정 정보 저장 확인 필요",
                message: "갱신한 계정 정보를 안전하게 저장했는지 확인할 수 없습니다. 기존 숫자는 표시하지 않습니다."
            )
        case .noEligibleSource, .sourceUnavailable:
            settingsFailure(
                title: "사용 가능한 조회 경로 없음",
                message: "AGY CLI 또는 Antigravity 앱 로그인 상태를 확인하거나 설정에서 Google 계정을 선택해 주세요."
            )
        case .repositoryUnavailable,
             .repositoryRevisionChanged,
             .invalidRefreshContext,
             .generationExhausted,
             .sourceContractViolation:
            settingsFailure(
                title: "로컬 상태 확인 필요",
                message: "계정 또는 자동 조회 상태가 갱신 중 변경되어 결과를 폐기했습니다. 설정을 확인한 뒤 다시 시도해 주세요."
            )
        case .deadlineExceeded, .transportUnavailable:
            retryFailure(
                title: "연결 일시 실패",
                message: "조회 경로가 제시간에 응답하지 않았습니다. 잠시 후 다시 시도해 주세요."
            )
        case .schemaChanged:
            retryFailure(
                title: "응답 형식 변경",
                message: "Antigravity 응답 형식이 달라 수치를 안전하게 해석하지 못했습니다. 이전 숫자는 표시하지 않습니다."
            )
        case .numericQuotaUnavailable:
            settingsFailure(
                title: "수치형 사용량 미지원",
                message: "현재 조회 경로는 표시 가능한 quota 수치를 제공하지 않습니다."
            )
        case .cancelled:
            retryFailure(
                title: "조회 취소됨",
                message: "새 계정 또는 조회 설정으로 전환되어 이전 요청을 취소했습니다."
            )
        case .appShuttingDown:
            retryFailure(
                title: "앱 종료 중",
                message: "진행 중인 조회를 안전하게 정리하고 있습니다."
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
            actionIsProminent: actionIsProminent
        )
    }
}
