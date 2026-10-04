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
        case .setupRequired(let reason):
            return summary(
                icon: setupIcon(reason),
                tone: .warning,
                title: setupTitle(reason),
                message: setupMessage(reason),
                actionTitle: "설정 열기",
                action: .openSettings,
                actionIsProminent: true
            )
        case .refreshing:
            return summary(
                showsProgress: true,
                title: "사용량 확인 중",
                message: nil
            )
        case .accountMismatch:
            return summary(
                icon:
                    "person.crop.circle.badge.exclamationmark",
                tone: .critical,
                title: "계정이 다름",
                message: "조회 중 계정이 바뀌었습니다. 선택한 제품의 로그인을 확인하세요.",
                actionTitle: "설정 열기",
                action: .openSettings,
                actionIsProminent: true
            )
        case .limited:
            return summary(
                icon: "chart.bar.doc.horizontal",
                tone: .warning,
                title: "한도 수치 없음",
                message: "이 조회 경로는 한도 수치를 제공하지 않습니다.",
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
                title: "한도 수치 없음",
                message:
                    "\(account) 계정의 한도 수치를 받지 못했습니다.",
                actionTitle: "계정 확인",
                action: .openSettings
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

    private static func setupIcon(
        _ reason: AntigravitySetupReason
    ) -> String {
        switch reason {
        case .noAmbientLocalSession, .usageTargetSelection, .ambiguousLocalSessions:
            "person.badge.key"
        }
    }

    private static func setupTitle(
        _ reason: AntigravitySetupReason
    ) -> String {
        switch reason {
        case .noAmbientLocalSession:
            "로그인 필요"
        case .usageTargetSelection:
            "조회 대상 선택 필요"
        case .ambiguousLocalSessions:
            "실행 중인 계정이 서로 다름"
        }
    }

    private static func setupMessage(
        _ reason: AntigravitySetupReason
    ) -> String {
        switch reason {
        case .noAmbientLocalSession:
            "Antigravity 앱이나 AGY CLI에 로그인한 뒤 새로고침하세요."
        case .usageTargetSelection:
            "AGY CLI에 로그인한 뒤 새로고침하세요."
        case .ambiguousLocalSessions:
            "이전 실행을 종료하고 새로고침하세요."
        }
    }

    static func failureSummary(
        _ failure: AntigravityFailure
    ) -> ProviderRuntimeSummary {
        switch failure {
        case .accountChanged:
            settingsFailure(title: "계정이 바뀜", message: "조회 중 계정이 바뀌었습니다. 새로고침하세요.")
        case .localAuthentication(_, let problem):
            switch problem {
            case .required:
                retryFailure(title: "AGY 다시 연결 필요", message: "AGY 연결이 끊겼습니다. 다시 시도하세요.")
            case .rejected:
                retryFailure(title: "AGY 다시 연결 필요", message: "AGY 연결 정보가 바뀌었습니다. 다시 시도하세요.")
            case .unavailable:
                settingsFailure(title: "AGY 연결 실패", message: "실행 중인 AGY에 연결하지 못했습니다. AGY CLI 상태를 확인하세요.")
            }
        case .runtimeUnavailable(let reason):
            switch reason {
            case .executableMissing:
                settingsFailure(title: "AGY CLI 설치 필요", message: "공식 AGY CLI를 설치한 뒤 다시 시도하세요.")
            case .executableChanged:
                retryFailure(title: "AGY CLI 변경됨", message: "업데이트가 끝난 뒤 다시 시도하세요.")
            case .verificationRejected:
                settingsFailure(title: "AGY CLI 실행 차단", message: "공식 서명이나 파일 권한을 확인하지 못했습니다. 공식 AGY CLI 설치 상태를 확인하세요.")
            case .unsupportedVersion:
                settingsFailure(
                    title: "AGY CLI 업데이트 필요",
                    message:
                        "설치된 AGY CLI는 사용량 보고를 지원하지 않습니다. AGY CLI를 \(AntigravityCLIVersion.minimumUsageReport) 이상으로 업데이트하세요."
                )
            case .reportDisabled:
                settingsFailure(
                    title: "AGY 사용량 보고 중지",
                    message:
                        "AGY가 사용량 대신 모델 응답을 실행해 한도가 더 쓰이지 않도록 자동 조회를 멈췄습니다. AGY CLI를 업데이트하거나 앱을 다시 실행하면 다시 조회합니다."
                )
            }
        case .authenticationRequired(let source), .interactionRequired(let source):
            if source == .googleOAuth {
                settingsFailure(
                    title: "이전 조회 경로는 지원하지 않습니다", message: "설정에서 조회 대상(Antigravity 앱이나 AGY CLI)과 그 제품의 로그인을 확인하세요.")
            } else {
                settingsFailure(title: "Antigravity 로그인 필요", message: "Antigravity 앱이나 AGY CLI에 로그인한 뒤 다시 시도하세요.")
            }
        case .noEligibleSource, .sourceUnavailable:
            settingsFailure(
                title: "사용 가능한 조회 경로 없음",
                message: "선택한 조회 대상이 실행 중인지, 로그인했는지 확인하세요."
            )
        case .invalidRefreshContext,
             .generationExhausted,
             .sourceContractViolation:
            settingsFailure(
                title: "조회 중 설정 변경",
                message: "조회 중 설정이 바뀌었습니다. 다시 시도하세요."
            )
        case .deadlineExceeded:
            retryFailure(title: "조회 시간 초과", message: "제한 시간 안에 응답이 없었습니다. 잠시 뒤 다시 시도하세요.")
        case .transportUnavailable:
            retryFailure(
                title: "연결 실패",
                message: "Antigravity에 연결하지 못했습니다. 잠시 뒤 다시 시도하세요."
            )
        case .schemaChanged:
            retryFailure(
                title: "응답 형식 변경",
                message: "응답을 읽지 못했습니다. 앱을 업데이트하세요."
            )
        case .numericQuotaUnavailable:
            settingsFailure(
                title: "한도 수치 없음",
                message: "이 조회 경로는 한도 수치를 제공하지 않습니다."
            )
        case .cancelled:
            retryFailure(
                title: "조회 취소됨",
                message: "계정이나 설정이 바뀌어 이전 조회를 취소했습니다."
            )
        case .appShuttingDown:
            retryFailure(
                title: "앱 종료 중",
                message: "진행 중인 조회를 정리하는 중입니다."
            )
        case .cliReportFailed:
            retryFailure(
                title: "AGY 사용량 없음",
                message: "터미널에서 AGY CLI 로그인을 확인한 뒤 다시 시도하세요."
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
