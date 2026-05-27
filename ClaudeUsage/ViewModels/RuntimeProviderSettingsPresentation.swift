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
    static func authPresentation(for provider: AppProviderKind, isEnabled: Bool) -> RuntimeProviderAuthPresentation? {
        switch provider {
        case .antigravity:
            let environmentStatus = ProviderEnvironmentDetector.staleWhileRevalidate(for: .antigravity)
            guard let signals = ProviderEnvironmentDetector.cachedAntigravitySignals() else {
                return makeProbingFallback(provider: .antigravity, isEnabled: isEnabled)
            }
            return makeAntigravity(
                isEnabled: isEnabled,
                environmentStatus: environmentStatus,
                signals: signals
            )
        case .claude, .codex:
            return nil
        }
    }

    private static func makeProbingFallback(
        provider: AppProviderKind,
        isEnabled: Bool
    ) -> RuntimeProviderAuthPresentation {
        let providerName = provider.displayName

        if !isEnabled {
            return .init(
                stage: .disabled,
                badgeTitle: "비활성",
                badgeTone: .secondary,
                summary: "\(providerName) 사용을 켜면 상태를 확인합니다",
                nextStepTitle: "서비스 켜기",
                nextStepDetail: "켜면 상태를 자동으로 다시 확인합니다.",
                availableAction: .enableService
            )
        }

        return .init(
            stage: .probingRuntime,
            badgeTitle: "환경 읽는 중",
            badgeTone: .blue,
            summary: "\(providerName) 상태를 확인하는 중입니다",
            nextStepTitle: "잠시 기다리기",
            nextStepDetail: "확인이 끝나면 화면이 자동으로 바뀝니다.",
            availableAction: nil
        )
    }

    static func makeAntigravity(
        isEnabled: Bool,
        environmentStatus: ProviderEnvironmentStatus?,
        signals: AntigravityEnvironmentSignals
    ) -> RuntimeProviderAuthPresentation {
        guard isEnabled else {
            return .init(
                stage: .disabled,
                badgeTitle: "비활성",
                badgeTone: .secondary,
                summary: "Antigravity 사용을 켜면 앱 상태를 확인합니다",
                nextStepTitle: "서비스 켜기",
                nextStepDetail: "켜면 앱 상태를 자동으로 다시 확인합니다.",
                availableAction: .enableService
            )
        }

        if signals.hasOAuthCredential {
            return .init(
                stage: .probingRuntime,
                badgeTitle: "계정 연결",
                badgeTone: .blue,
                summary: signals.hasBrokenCLICommand
                    ? "계정은 연결됐지만 CLI 명령은 복구가 필요합니다"
                    : "계정은 연결됐고 사용량을 확인합니다",
                nextStepTitle: "사용량 조회",
                nextStepDetail: "계정만 보이면 Antigravity가 아직 사용량 수치를 제공하지 않은 상태입니다.",
                availableAction: nil
            )
        }

        let hasRelevantPersistedAuthState = signals.hasCredentialRelevant(to: .auto)

        if signals.hasRuntimeConnection {
            return .init(
                stage: .probingRuntime,
                badgeTitle: "연결 확인 중",
                badgeTone: .blue,
                summary: "앱 연결은 확인됐고 사용량을 불러오는 중입니다",
                nextStepTitle: "앱을 켜 둔 채 기다리기",
                nextStepDetail: "첫 사용량이 들어오면 화면이 바뀝니다.",
                availableAction: nil
            )
        }

        if signals.appRunning && hasRelevantPersistedAuthState {
            return .init(
                stage: .waitingForApp,
                badgeTitle: "연결 준비",
                badgeTone: .orange,
                summary: "앱은 열려 있지만 아직 준비가 끝나지 않았습니다",
                nextStepTitle: "앱을 켜 둔 채 잠시 기다리기",
                nextStepDetail: "잠시 기다린 뒤 다시 확인해 주세요.",
                availableAction: nil
            )
        }

        if hasRelevantPersistedAuthState {
            if signals.hasCLIBinary {
                return .init(
                    stage: .probingRuntime,
                    badgeTitle: "조회 준비",
                    badgeTone: .blue,
                    summary: "사용량 조회를 준비 중입니다",
                    nextStepTitle: "사용량 조회",
                    nextStepDetail: "CLI 로그인 선택이나 trust prompt가 뜨면 터미널에서 `agy`를 먼저 한 번 열어 주세요.",
                    availableAction: nil
                )
            }
            return .init(
                stage: .waitingForApp,
                badgeTitle: "앱 필요",
                badgeTone: .orange,
                summary: "로그인은 보이지만 앱이 열려 있지 않습니다",
                nextStepTitle: "Antigravity 앱 열기",
                nextStepDetail: "앱을 실행한 뒤 다시 확인해 주세요.",
                availableAction: .openAntigravityApp
            )
        }

        if signals.hasCLISurface {
            return .init(
                stage: signals.hasCLIBinary ? .probingRuntime : .authRequired,
                badgeTitle: signals.hasBrokenCLICommand ? "CLI 복구" : (signals.hasCLIBinary ? "조회 준비" : "CLI 설정"),
                badgeTone: signals.hasBrokenCLICommand ? .red : .orange,
                summary: signals.hasBrokenCLICommand
                    ? "agy 명령은 감지됐지만 현재 실행 대상이 없습니다"
                    : signals.hasCLIBinary
                    ? "사용량 조회를 준비 중입니다"
                    : "CLI 설정은 감지됐지만 실행 파일이 필요합니다",
                nextStepTitle: signals.hasBrokenCLICommand ? "CLI 재설치" : "AGY CLI 확인",
                nextStepDetail: signals.hasBrokenCLICommand
                    ? "PATH의 agy 래퍼가 없는 대상 파일을 가리킵니다. Antigravity 2.0 또는 CLI를 다시 설치해 주세요."
                    : "터미널에서 `agy`가 실행되는지 확인해 주세요.",
                availableAction: nil
            )
        }

        if signals.appRunning {
            return .init(
                stage: .authRequired,
                badgeTitle: "로그인 필요",
                badgeTone: .red,
                summary: "앱은 열려 있지만 아직 로그인되지 않았습니다",
                nextStepTitle: "앱 안에서 로그인",
                nextStepDetail: "앱 안에서 로그인을 완료한 뒤 다시 확인해 주세요.",
                availableAction: nil
            )
        }

        if environmentStatus?.isDetected == true {
            return .init(
                stage: .waitingForApp,
                badgeTitle: "앱 필요",
                badgeTone: .orange,
                summary: "준비 흔적은 있지만 앱이 열려 있지 않습니다",
                nextStepTitle: "Antigravity 앱 열기",
                nextStepDetail: "앱을 실행한 뒤 다시 확인해 주세요.",
                availableAction: .openAntigravityApp
            )
        }

        return .init(
            stage: .authRequired,
            badgeTitle: "초기 준비",
            badgeTone: .red,
            summary: "앱을 열고 로그인해야 합니다",
            nextStepTitle: "앱 열기 후 로그인",
            nextStepDetail: "로그인을 마치면 여기서 바로 확인할 수 있습니다.",
            availableAction: .openAntigravityApp
        )
    }
}
