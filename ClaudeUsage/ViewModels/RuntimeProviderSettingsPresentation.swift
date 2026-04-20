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

    let stage: RuntimeProviderAuthStage
    let badgeTitle: String
    let badgeTone: BadgeTone
    let summary: String
    let primaryActionTitle: String
    let primaryActionDetail: String
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
                summary: "\(providerName) 사용을 켜면 준비 상태를 확인합니다",
                primaryActionTitle: "서비스 켜기",
                primaryActionDetail: "켜면 상태를 자동으로 다시 확인합니다."
            )
        }

        return .init(
            stage: .probingRuntime,
            badgeTitle: "환경 읽는 중",
            badgeTone: .blue,
            summary: "\(providerName) 준비 상태를 확인하는 중입니다",
            primaryActionTitle: "잠시 기다리기",
            primaryActionDetail: "확인이 끝나면 화면이 자동으로 바뀝니다."
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
                primaryActionTitle: "서비스 켜기",
                primaryActionDetail: "켜면 로그인과 준비 상태를 자동으로 확인합니다."
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
                primaryActionTitle: "Gemini 설치 또는 다시 설치",
                primaryActionDetail: detail
            )
        }

        switch signals.authType {
        case .apiKey, .vertexAI:
            return .init(
                stage: .unsupportedConfiguration,
                badgeTitle: "구성 변경",
                badgeTone: .orange,
                summary: "현재 로그인 방식으로는 여기서 확인할 수 없습니다",
                primaryActionTitle: "개인 계정으로 다시 로그인",
                primaryActionDetail: "Gemini는 개인 로그인 상태만 읽습니다."
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
                primaryActionTitle: "Gemini에서 로그인",
                primaryActionDetail: "로그인이 끝나면 여기서 바로 확인할 수 있습니다."
            )
        case .refreshOnly:
            return .init(
                stage: .refreshingCredential,
                badgeTitle: "갱신 필요",
                badgeTone: .blue,
                summary: "로그인 정보를 새로 고치는 중입니다",
                primaryActionTitle: "잠시 기다리기",
                primaryActionDetail: "새로 고친 뒤 다시 확인합니다."
            )
        case .usable:
            if environmentStatus?.runtimeReachability == true {
                return .init(
                    stage: .probingRuntime,
                    badgeTitle: "연결 확인 중",
                    badgeTone: .blue,
                    summary: "로그인은 확인됐고 사용량을 불러오는 중입니다",
                    primaryActionTitle: "잠시 기다리기",
                    primaryActionDetail: "첫 사용량이 들어오면 화면이 바뀝니다."
                )
            }
            return .init(
                stage: .installRequired,
                badgeTitle: "경로 확인",
                badgeTone: .orange,
                summary: "Gemini는 보이지만 아직 바로 사용할 수 없습니다",
                primaryActionTitle: "설치 상태 다시 확인",
                primaryActionDetail: "설치 상태나 실행 경로를 확인한 뒤 다시 확인해 주세요."
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
                primaryActionTitle: "서비스 켜기",
                primaryActionDetail: "켜면 준비 상태를 자동으로 다시 확인합니다."
            )
        }

        if signals.hasRuntimeConnection {
            return .init(
                stage: .probingRuntime,
                badgeTitle: "연결 확인 중",
                badgeTone: .blue,
                summary: "앱 연결은 확인됐고 사용량을 불러오는 중입니다",
                primaryActionTitle: "앱을 켜 둔 채 기다리기",
                primaryActionDetail: "첫 사용량이 들어오면 화면이 바뀝니다."
            )
        }

        if signals.appRunning && signals.hasPersistedAuthState {
            return .init(
                stage: .waitingForApp,
                badgeTitle: "연결 준비",
                badgeTone: .orange,
                summary: "앱은 열려 있지만 아직 준비가 끝나지 않았습니다",
                primaryActionTitle: "앱을 켜 둔 채 잠시 기다리기",
                primaryActionDetail: "잠시 기다린 뒤 다시 확인해 주세요."
            )
        }

        if signals.hasPersistedAuthState {
            return .init(
                stage: .waitingForApp,
                badgeTitle: "앱 필요",
                badgeTone: .orange,
                summary: "로그인은 보이지만 앱이 열려 있지 않습니다",
                primaryActionTitle: "Antigravity 앱 열기",
                primaryActionDetail: "앱을 실행한 뒤 다시 확인해 주세요."
            )
        }

        if signals.appRunning {
            return .init(
                stage: .authRequired,
                badgeTitle: "로그인 필요",
                badgeTone: .red,
                summary: "앱은 열려 있지만 아직 로그인되지 않았습니다",
                primaryActionTitle: "앱 안에서 로그인",
                primaryActionDetail: "앱 안에서 로그인을 완료한 뒤 다시 확인해 주세요."
            )
        }

        if environmentStatus?.isDetected == true {
            return .init(
                stage: .waitingForApp,
                badgeTitle: "앱 필요",
                badgeTone: .orange,
                summary: "준비 흔적은 있지만 앱이 열려 있지 않습니다",
                primaryActionTitle: "Antigravity 앱 열기",
                primaryActionDetail: "앱을 실행한 뒤 다시 확인해 주세요."
            )
        }

        return .init(
            stage: .authRequired,
            badgeTitle: "초기 준비",
            badgeTone: .red,
            summary: "앱을 열고 로그인해야 합니다",
            primaryActionTitle: "앱 열기 후 로그인",
            primaryActionDetail: "로그인을 마치면 여기서 바로 확인할 수 있습니다."
        )
    }
}
