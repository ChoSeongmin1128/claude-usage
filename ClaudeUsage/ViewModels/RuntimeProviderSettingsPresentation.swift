import Foundation

enum RuntimeProviderAuthStage: String, Sendable, Equatable {
    case disabled
    case installRequired
    case unsupportedConfiguration
    case authRequired
    case refreshingCredential
    case waitingForApp
    case probingRuntime
}

struct RuntimeProviderAuthPresentation: Sendable, Equatable {
    enum BadgeTone: String, Sendable, Equatable {
        case secondary
        case blue
        case orange
        case red
    }

    enum AvailableAction: String, Sendable, Equatable {
        case enableService
    }

    let stage: RuntimeProviderAuthStage
    let badgeTitle: String
    let badgeTone: BadgeTone
    let summary: String
    let nextStepTitle: String
    let nextStepDetail: String
    let availableAction: AvailableAction?
}

enum RuntimeProviderSettingsPresentation {
    static func authPresentation(
        for provider: AppProviderKind,
        isEnabled: Bool,
        antigravityState:
            AntigravitySettingsViewState? = nil
    ) -> RuntimeProviderAuthPresentation? {
        switch provider {
        case .antigravity:
            return makeAntigravity(
                isEnabled: isEnabled,
                state: antigravityState
            )
        case .claude, .codex:
            return nil
        }
    }

    static func makeAntigravity(
        isEnabled: Bool,
        state: AntigravitySettingsViewState?
    ) -> RuntimeProviderAuthPresentation {
        if !isEnabled {
            return .init(
                stage: .disabled,
                badgeTitle: "비활성",
                badgeTone: .secondary,
                summary:
                    "Antigravity 사용을 켜면 연결 상태를 확인합니다",
                nextStepTitle: "서비스 켜기",
                nextStepDetail:
                    "켜면 저장된 연결 설정으로 사용량을 확인합니다.",
                availableAction: .enableService
            )
        }

        guard let state else {
            return .init(
                stage: .probingRuntime,
                badgeTitle: "준비 중",
                badgeTone: .secondary,
                summary:
                    "저장된 연결 상태를 불러오는 중입니다",
                nextStepTitle: "잠시 기다리기",
                nextStepDetail:
                    "준비가 끝나면 화면이 자동으로 바뀝니다.",
                availableAction: nil
            )
        }

        if state.activity.isBusy {
            return .init(
                stage: .probingRuntime,
                badgeTitle: "확인 중",
                badgeTone: .blue,
                summary:
                    "선택한 제품의 로그인 계정과 사용량을 확인하고 있습니다",
                nextStepTitle: "확인 완료 기다리기",
                nextStepDetail:
                    "현재 작업이 끝나면 검증된 결과로 갱신됩니다.",
                availableAction: nil
            )
        }

        switch state.presentation {
        case .ready:
            return .init(
                stage: .probingRuntime,
                badgeTitle: "연결됨",
                badgeTone: .blue,
                summary:
                    quotaSummary(state),
                nextStepTitle: "사용량 확인 완료",
                nextStepDetail:
                    "아래에서 조회할 계정을 바꿀 수 있습니다.",
                availableAction: nil
            )
        case .partial:
            return .init(
                stage: .probingRuntime,
                badgeTitle: "일부 확인",
                badgeTone: .orange,
                summary:
                    quotaSummary(state),
                nextStepTitle: "표시 가능한 한도만 사용",
                nextStepDetail:
                    "지원되지 않는 항목은 숫자로 추정하지 않습니다.",
                availableAction: nil
            )
        case .refreshing:
            return .init(
                stage: .probingRuntime,
                badgeTitle: "새로고침",
                badgeTone: .blue,
                summary:
                    "선택한 조회 대상의 연결을 확인하고 있습니다",
                nextStepTitle: "확인 완료 기다리기",
                nextStepDetail:
                    "계정 경계가 일치하는 결과만 반영합니다.",
                availableAction: nil
            )
        case .stale:
            return .init(
                stage: .waitingForApp,
                badgeTitle: "이전 결과",
                badgeTone: .orange,
                summary:
                    "새 조회가 실패해 마지막 검증 결과를 유지합니다",
                nextStepTitle: "연결 확인 후 다시 시도",
                nextStepDetail:
                    "선택한 제품의 로그인 상태를 확인한 뒤 새로고침해 주세요.",
                availableAction: nil
            )
        case .setupRequired(
            .noSelectedOAuthAccount
        ):
            return .init(
                stage: .authRequired,
                badgeTitle: "계정 필요",
                badgeTone: .red,
                summary:
                    "이전 조회 경로는 지원하지 않습니다",
                nextStepTitle: "AGY CLI 확인",
                nextStepDetail:
                    "AGY CLI에 로그인한 뒤 새로고침해 주세요.",
                availableAction: nil
            )
        case .setupRequired(.usageTargetSelection):
            return .init(
                stage: .unsupportedConfiguration, badgeTitle: "대상 선택", badgeTone: .orange,
                summary: "AGY CLI를 확인해 주세요", nextStepTitle: "AGY CLI 확인",
                nextStepDetail: "AGY CLI에 로그인한 뒤 새로고침해 주세요.", availableAction: nil)
        case .setupRequired(.ambiguousLocalSessions):
            return .init(
                stage: .waitingForApp, badgeTitle: "연결 확인", badgeTone: .orange,
                summary: "실행 중인 연결의 계정이 서로 다릅니다", nextStepTitle: "이전 실행 종료",
                nextStepDetail: "선택한 제품의 현재 실행만 남긴 뒤 새로고침해 주세요.", availableAction: nil)
        case .setupRequired(
            .noAmbientLocalSession
        ):
            return .init(
                stage: .waitingForApp,
                badgeTitle: "로그인 필요",
                badgeTone: .orange,
                summary:
                    "AGY CLI 로그인을 찾지 못했습니다",
                nextStepTitle: "AGY CLI 로그인",
                nextStepDetail:
                    "터미널에서 agy를 실행해 로그인한 뒤 다시 확인해 주세요.",
                availableAction: nil
            )
        case .accountMismatch:
            return .init(
                stage: .authRequired,
                badgeTitle: "계정 불일치",
                badgeTone: .red,
                summary:
                    "선택한 계정과 다른 세션의 수치는 표시하지 않았습니다",
                nextStepTitle: "조회 계정 확인",
                nextStepDetail:
                    "의도한 계정을 선택한 뒤 다시 시도해 주세요.",
                availableAction: nil
            )
        case .limited, .identityOnly:
            return .init(
                stage: .probingRuntime,
                badgeTitle: "수치 없음",
                badgeTone: .orange,
                summary:
                    "계정은 확인했지만 수치형 사용 한도를 받지 못했습니다",
                nextStepTitle: "로그인 상태 확인",
                nextStepDetail:
                    "선택한 조회 대상에서 수치 제공 여부를 확인해 주세요.",
                availableAction: nil
            )
        case .failed(let failure):
            let detail = AntigravityPopoverPresentationAdapter.failureSummary(failure)
            let authFailure = isAuthenticationFailure(failure)
            return .init(stage: authFailure ? .authRequired : .probingRuntime,
                badgeTitle: authFailure ? "인증 필요" : "조회 실패", badgeTone: .red,
                summary: detail.title, nextStepTitle: detail.actionTitle ?? "다시 시도",
                nextStepDetail: detail.message, availableAction: nil)
        case .disabled:
            return .init(
                stage: .probingRuntime,
                badgeTitle: "준비 중",
                badgeTone: .secondary,
                summary:
                    "Antigravity 런타임을 준비하고 있습니다",
                nextStepTitle: "준비 완료 기다리기",
                nextStepDetail:
                    "저장소와 설정 검증이 끝나면 상태가 바뀝니다.",
                availableAction: nil
            )
        }
    }

    private static func quotaSummary(
        _ state: AntigravitySettingsViewState
    ) -> String {
        guard case .content(let presentation) =
                state.quotaPresentation
        else {
            return "검증된 사용량을 확인했습니다"
        }
        return "\(presentation.observedLaneCount)개 사용 한도를 확인했습니다"
    }

    private static func isAuthenticationFailure(
        _ failure: AntigravityFailure
    ) -> Bool {
        switch failure {
        case .authenticationRequired,
             .selectedAccountUnavailable,
             .selectedAccountIdentityUnavailable:
            return true
        case .cancelled,
            .accountChanged,
             .appShuttingDown,
             .invalidRefreshContext,
             .generationExhausted,
             .repositoryUnavailable,
             .repositoryRevisionChanged,
             .credentialCommitFailed,
             .credentialCommitAmbiguous,
             .noEligibleSource,
             .sourceUnavailable,
             .interactionRequired,
             .deadlineExceeded,
             .schemaChanged,
             .transportUnavailable,
             .sourceContractViolation,
             .localAuthentication,
             .numericQuotaUnavailable,
            .runtimeUnavailable,
            .cliReportFailed:
            return false
        }
    }
}
