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
        case openAntigravityApp
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
                    "선택한 계정에 맞는 조회 경로를 확인하고 있습니다",
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
                    "선택한 계정과 출처를 다시 검증하고 있습니다",
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
                    "현재 계정과 로컬 또는 Google 로그인 상태를 확인한 뒤 새로고침해 주세요.",
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
                    "조회할 Google 계정이 선택되지 않았습니다",
                nextStepTitle: "Google 계정 연결",
                nextStepDetail:
                    "아래 계정 관리에서 계정을 연결해 주세요.",
                availableAction: nil
            )
        case .setupRequired(
            .noAmbientLocalSession
        ):
            return .init(
                stage: .waitingForApp,
                badgeTitle: "앱 필요",
                badgeTone: .orange,
                summary:
                    "로그인된 로컬 Antigravity 세션이 없습니다",
                nextStepTitle: "Antigravity 앱 열기",
                nextStepDetail:
                    "앱에서 로그인을 완료한 뒤 다시 확인해 주세요.",
                availableAction: .openAntigravityApp
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
                    "AGY CLI 또는 연결된 Google 계정에서 수치 제공 여부를 확인해 주세요.",
                availableAction: nil
            )
        case .failed(let failure):
            let authFailure =
                isAuthenticationFailure(failure)
            return .init(
                stage:
                    authFailure
                        ? .authRequired
                        : .probingRuntime,
                badgeTitle:
                    authFailure
                        ? "인증 필요"
                        : "조회 실패",
                badgeTone: .red,
                summary:
                    authFailure
                        ? "현재 계정으로 인증할 수 없습니다"
                        : "자동 조회 경로에서 사용량을 확인하지 못했습니다",
                nextStepTitle:
                    authFailure
                        ? "계정 다시 연결"
                        : "연결 확인 후 다시 시도",
                nextStepDetail:
                    "아래 조회 계정과 로그인 상태를 확인해 주세요.",
                availableAction: nil
            )
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
             .numericQuotaUnavailable:
            return false
        }
    }
}
