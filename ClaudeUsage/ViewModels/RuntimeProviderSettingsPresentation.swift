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
        case .gemini:
            let environmentStatus = ProviderEnvironmentDetector.staleWhileRevalidate(for: .gemini)
            guard let signals = ProviderEnvironmentDetector.cachedGeminiSignals() else {
                return makeProbingFallback(provider: .gemini, isEnabled: isEnabled)
            }
            return makeGemini(
                isEnabled: isEnabled,
                environmentStatus: environmentStatus,
                signals: signals
            )
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
        let providerName: String = {
            switch provider {
            case .gemini: return "Gemini"
            case .antigravity: return "Antigravity"
            default: return "provider"
            }
        }()

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

    static func makeGemini(
        isEnabled: Bool,
        environmentStatus: ProviderEnvironmentStatus?,
        signals: GeminiEnvironmentSignals
    ) -> RuntimeProviderAuthPresentation {
        guard isEnabled else {
            return .init(
                stage: .disabled,
                badgeTitle: "비활성",
                badgeTone: .secondary,
                summary: "Gemini 사용을 켜면 로그인 상태를 확인합니다",
                nextStepTitle: "서비스 켜기",
                nextStepDetail: "켜면 로그인 상태를 자동으로 확인합니다.",
                availableAction: .enableService
            )
        }

        if !signals.hasBinary {
            let detail = signals.credentialState == .missing
                ? "Gemini를 먼저 설치하고 로그인해 주세요."
                : "로그인은 되어 있지만 Gemini를 실행할 수 없습니다."
            return .init(
                stage: .installRequired,
                badgeTitle: "설치 필요",
                badgeTone: .orange,
                summary: "Gemini를 실행할 준비가 필요합니다",
                nextStepTitle: "Gemini 설치 또는 다시 설치",
                nextStepDetail: detail,
                availableAction: nil
            )
        }

        switch signals.authType {
        case .apiKey, .vertexAI:
            return .init(
                stage: .unsupportedConfiguration,
                badgeTitle: "구성 변경",
                badgeTone: .orange,
                summary: "현재 로그인 방식으로는 여기서 확인할 수 없습니다",
                nextStepTitle: "개인 계정으로 다시 로그인",
                nextStepDetail: "Gemini는 개인 로그인 상태만 읽습니다.",
                availableAction: nil
            )
        case .oauthPersonal, .unknown:
            break
        }

        switch signals.credentialState {
        case .missing:
            return .init(
                stage: .authRequired,
                badgeTitle: "로그인 필요",
                badgeTone: .red,
                summary: "Gemini 로그인 후 다시 확인해 주세요",
                nextStepTitle: "Gemini에서 로그인",
                nextStepDetail: "로그인이 끝나면 여기서 바로 확인할 수 있습니다.",
                availableAction: nil
            )
        case .refreshOnly:
            return .init(
                stage: .refreshingCredential,
                badgeTitle: "갱신 필요",
                badgeTone: .blue,
                summary: "로그인 정보를 새로 고치는 중입니다",
                nextStepTitle: "잠시 기다리기",
                nextStepDetail: "새로 고친 뒤 다시 확인합니다.",
                availableAction: nil
            )
        case .usable:
            if environmentStatus?.runtimeReachability == true {
                return .init(
                    stage: .probingRuntime,
                    badgeTitle: "연결 확인 중",
                    badgeTone: .blue,
                    summary: "로그인은 확인됐고 사용량을 불러오는 중입니다",
                    nextStepTitle: "잠시 기다리기",
                    nextStepDetail: "첫 사용량이 들어오면 화면이 바뀝니다.",
                    availableAction: nil
                )
            }
            return .init(
                stage: .installRequired,
                badgeTitle: "경로 확인",
                badgeTone: .orange,
                summary: "Gemini는 보이지만 아직 바로 사용할 수 없습니다",
                nextStepTitle: "설치 상태 다시 확인",
                nextStepDetail: "설치 상태를 확인한 뒤 다시 확인해 주세요.",
                availableAction: nil
            )
        }
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

        if signals.appRunning && signals.hasPersistedAuthState {
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

        if signals.hasPersistedAuthState {
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
