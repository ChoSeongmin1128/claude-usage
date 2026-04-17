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

    struct Step: Sendable, Equatable, Identifiable {
        let title: String
        let detail: String

        var id: String { "\(title)|\(detail)" }
    }

    let stage: RuntimeProviderAuthStage
    let badgeTitle: String
    let badgeTone: BadgeTone
    let summary: String
    let primaryActionTitle: String
    let primaryActionDetail: String
    let detectorSummary: String
    let steps: [Step]
    let pathHints: [String]
}

enum RuntimeProviderSettingsPresentation {
    /// UI 경로용 — cache-only. 캐시 miss 면 "환경 확인 중" presentation 리턴 +
    /// 백그라운드 warm-up. warm-up 끝나면 `.providerEnvironmentUpdated` 노티로
    /// SettingsView 가 재렌더.
    static func authPresentation(for provider: AppProviderKind, isEnabled: Bool) -> RuntimeProviderAuthPresentation? {
        switch provider {
        case .gemini:
            let environmentStatus = ProviderEnvironmentDetector.staleWhileRevalidate(for: .gemini)
            guard let signals = ProviderEnvironmentDetector.cachedGeminiSignals() else {
                return makeProbingFallback(provider: .gemini, isEnabled: isEnabled, environmentStatus: environmentStatus)
            }
            return makeGemini(
                isEnabled: isEnabled,
                environmentStatus: environmentStatus,
                signals: signals
            )
        case .antigravity:
            let environmentStatus = ProviderEnvironmentDetector.staleWhileRevalidate(for: .antigravity)
            guard let signals = ProviderEnvironmentDetector.cachedAntigravitySignals() else {
                return makeProbingFallback(provider: .antigravity, isEnabled: isEnabled, environmentStatus: environmentStatus)
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

    /// 캐시가 아직 없을 때 보여 줄 임시 "환경 읽는 중" 상태.
    /// 이 상태에서는 signals 가 없으므로 기본 힌트만 제공.
    private static func makeProbingFallback(
        provider: AppProviderKind,
        isEnabled: Bool,
        environmentStatus: ProviderEnvironmentStatus?
    ) -> RuntimeProviderAuthPresentation {
        let providerName: String = {
            switch provider {
            case .gemini: return "Gemini"
            case .antigravity: return "Antigravity"
            default: return "provider"
            }
        }()
        let pathHints: [String] = {
            switch provider {
            case .gemini: return geminiPathHints
            case .antigravity: return antigravityPathHints
            default: return []
            }
        }()
        let detectorSummary = environmentStatus?.summary ?? "\(providerName) 환경 상태를 아직 읽지 못했습니다"

        if !isEnabled {
            return .init(
                stage: .disabled,
                badgeTitle: "비활성",
                badgeTone: .secondary,
                summary: "\(providerName) provider를 켜야 상태 확인을 시작합니다",
                primaryActionTitle: "먼저 provider 활성화",
                primaryActionDetail: "활성화 후 환경을 다시 읽습니다.",
                detectorSummary: detectorSummary,
                steps: [
                    .init(title: "활성화", detail: "\(providerName) provider를 켭니다."),
                    .init(title: "환경 확인", detail: "첫 환경 감지를 기다립니다."),
                ],
                pathHints: pathHints
            )
        }

        return .init(
            stage: .probingRuntime,
            badgeTitle: "환경 읽는 중",
            badgeTone: .blue,
            summary: "\(providerName) 환경을 백그라운드에서 확인하는 중입니다",
            primaryActionTitle: "잠시 대기",
            primaryActionDetail: "확인이 끝나면 상태가 자동으로 갱신됩니다.",
            detectorSummary: detectorSummary,
            steps: [
                .init(title: "환경 감지", detail: "CLI · 앱 · 로그인 상태를 백그라운드에서 확인합니다."),
                .init(title: "자동 갱신", detail: "결과가 들어오면 화면이 바로 갱신됩니다."),
            ],
            pathHints: pathHints
        )
    }

    static func makeGemini(
        isEnabled: Bool,
        environmentStatus: ProviderEnvironmentStatus?,
        signals: GeminiEnvironmentSignals
    ) -> RuntimeProviderAuthPresentation {
        let detectorSummary = environmentStatus?.summary ?? "Gemini 환경 상태를 아직 읽지 못했습니다"

        guard isEnabled else {
            return .init(
                stage: .disabled,
                badgeTitle: "비활성",
                badgeTone: .secondary,
                summary: "Gemini provider를 켜야 상태 확인을 시작합니다",
                primaryActionTitle: "먼저 provider 활성화",
                primaryActionDetail: "활성화 후 CLI와 로그인 상태를 확인합니다.",
                detectorSummary: detectorSummary,
                steps: [
                    .init(title: "활성화", detail: "Gemini provider를 켭니다."),
                    .init(title: "환경 확인", detail: "CLI와 로그인 상태를 다시 읽습니다."),
                    .init(title: "첫 조회", detail: "첫 사용량 조회를 기다립니다."),
                ],
                pathHints: geminiPathHints
            )
        }

        if !signals.hasBinary {
            let detail = signals.credentialState == .missing
                ? "CLI와 로그인 상태를 먼저 준비해 주세요."
                : "로그인은 확인됐지만 Gemini CLI를 찾지 못했습니다."
            return .init(
                stage: .installRequired,
                badgeTitle: "설치 필요",
                badgeTone: .orange,
                summary: "Gemini CLI 설치 또는 PATH 확인이 필요합니다",
                primaryActionTitle: "CLI 실행 경로 정리",
                primaryActionDetail: detail,
                detectorSummary: detectorSummary,
                steps: [
                    .init(title: "CLI 경로 확인", detail: "`gemini` 실행 파일 경로를 확인합니다."),
                    .init(title: "로그인 상태 유지", detail: "로그인 정보는 그대로 두고 CLI만 복구하면 됩니다."),
                    .init(title: "다시 확인", detail: "경로가 보이면 다시 조회합니다."),
                ],
                pathHints: geminiPathHints
            )
        }

        switch signals.authType {
        case .apiKey:
            return .init(
                stage: .unsupportedConfiguration,
                badgeTitle: "구성 변경",
                badgeTone: .orange,
                summary: "현재 Gemini CLI는 API 키 모드라 직접 조회를 지원하지 않습니다",
                primaryActionTitle: "OAuth 모드로 다시 로그인",
                primaryActionDetail: "Gemini provider는 개인 OAuth 로그인만 사용합니다.",
                detectorSummary: detectorSummary,
                steps: [
                    .init(title: "인증 방식 변경", detail: "CLI를 OAuth 기준으로 다시 설정합니다."),
                    .init(title: "OAuth 자격 생성", detail: "`oauth_creds.json` 이 생기는지 확인합니다."),
                    .init(title: "다시 확인", detail: "설정을 바꾼 뒤 다시 조회합니다."),
                ],
                pathHints: geminiPathHints
            )
        case .vertexAI:
            return .init(
                stage: .unsupportedConfiguration,
                badgeTitle: "구성 변경",
                badgeTone: .orange,
                summary: "현재 Gemini CLI는 Vertex AI 모드라 직접 조회와 맞지 않습니다",
                primaryActionTitle: "개인 OAuth로 전환",
                primaryActionDetail: "이 앱은 개인 OAuth 흐름만 직접 읽습니다.",
                detectorSummary: detectorSummary,
                steps: [
                    .init(title: "인증 방식 전환", detail: "Vertex AI 대신 개인 OAuth로 다시 설정합니다."),
                    .init(title: "설정 확인", detail: "`settings.json` 과 OAuth 자격 파일을 확인합니다."),
                    .init(title: "다시 확인", detail: "전환 후 다시 조회합니다."),
                ],
                pathHints: geminiPathHints
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
                summary: "Gemini CLI 로그인 후 다시 확인해 주세요",
                primaryActionTitle: "Gemini CLI에서 로그인",
                primaryActionDetail: "로그인 정보가 있어야 quota 조회를 이어갈 수 있습니다.",
                detectorSummary: detectorSummary,
                steps: [
                    .init(title: "OAuth 로그인", detail: "Gemini CLI에서 개인 OAuth 로그인을 완료합니다."),
                    .init(title: "자격 확인", detail: "`oauth_creds.json` 생성 여부를 확인합니다."),
                    .init(title: "다시 확인", detail: "로그인 후 다시 조회합니다."),
                ],
                pathHints: geminiPathHints
            )
        case .refreshOnly:
            return .init(
                stage: .refreshingCredential,
                badgeTitle: "갱신 필요",
                badgeTone: .blue,
                summary: "토큰을 갱신한 뒤 다시 확인합니다",
                primaryActionTitle: "CLI 자격 갱신 대기",
                primaryActionDetail: "다음 갱신 때 로그인 상태와 quota를 다시 확인합니다.",
                detectorSummary: detectorSummary,
                steps: [
                    .init(title: "토큰 갱신", detail: "access token 을 다시 발급합니다."),
                    .init(title: "설정 확인", detail: "project 설정과 경로를 다시 읽습니다."),
                    .init(title: "다시 확인", detail: "갱신 뒤 quota를 다시 조회합니다."),
                ],
                pathHints: geminiPathHints
            )
        case .usable:
            if environmentStatus?.runtimeReachability == true {
                return .init(
                    stage: .probingRuntime,
                    badgeTitle: "연결 확인 중",
                    badgeTone: .blue,
                    summary: "로그인은 확인됐고 첫 사용량 조회를 기다리는 중입니다",
                    primaryActionTitle: "자동 조회 대기",
                    primaryActionDetail: "첫 사용량이 들어오면 상태가 갱신됩니다.",
                    detectorSummary: detectorSummary,
                    steps: [
                        .init(title: "자동 조회", detail: "현재 로그인 정보로 조회를 시도합니다."),
                        .init(title: "결과 확인", detail: "첫 사용량이 들어오는지 확인합니다."),
                    ],
                    pathHints: geminiPathHints
                )
            }
            return .init(
                stage: .installRequired,
                badgeTitle: "경로 확인",
                badgeTone: .orange,
                summary: "로그인은 확인됐지만 실행 경로를 더 확인해야 합니다",
                primaryActionTitle: "CLI 경로 점검",
                primaryActionDetail: "실행 파일 경로나 런타임 접근성을 확인해 주세요.",
                detectorSummary: detectorSummary,
                steps: [
                    .init(title: "실행 파일 확인", detail: "`gemini` 실행 파일이 보이는지 확인합니다."),
                    .init(title: "다시 감지", detail: "경로를 정리한 뒤 다시 읽습니다."),
                ],
                pathHints: geminiPathHints
            )
        }
    }

    static func makeAntigravity(
        isEnabled: Bool,
        environmentStatus: ProviderEnvironmentStatus?,
        signals: AntigravityEnvironmentSignals
    ) -> RuntimeProviderAuthPresentation {
        let detectorSummary = environmentStatus?.summary ?? "Antigravity 환경 상태를 아직 읽지 못했습니다"

        guard isEnabled else {
            return .init(
                stage: .disabled,
                badgeTitle: "비활성",
                badgeTone: .secondary,
                summary: "Antigravity provider를 켜야 상태 확인을 시작합니다",
                primaryActionTitle: "먼저 provider 활성화",
                primaryActionDetail: "활성화 후 앱 실행과 로그인 상태를 확인합니다.",
                detectorSummary: detectorSummary,
                steps: [
                    .init(title: "활성화", detail: "Antigravity provider를 켭니다."),
                    .init(title: "앱 실행", detail: "앱 실행 상태를 다시 읽습니다."),
                    .init(title: "첫 조회", detail: "첫 사용량 조회를 기다립니다."),
                ],
                pathHints: antigravityPathHints
            )
        }

        if signals.hasRuntimeConnection {
            return .init(
                stage: .probingRuntime,
                badgeTitle: "연결 확인 중",
                badgeTone: .blue,
                summary: "연결은 보이지만 첫 사용량 조회를 아직 기다리는 중입니다",
                primaryActionTitle: "자동 조회 대기",
                primaryActionDetail: "앱을 켜 둔 채 첫 사용량 조회를 기다려 주세요.",
                detectorSummary: detectorSummary,
                steps: [
                    .init(title: "자동 조회", detail: "현재 연결로 quota 조회를 시도합니다."),
                    .init(title: "결과 확인", detail: "첫 사용량이 들어오는지 확인합니다."),
                ],
                pathHints: antigravityPathHints
            )
        }

        if signals.appRunning && signals.hasPersistedAuthState {
            return .init(
                stage: .waitingForApp,
                badgeTitle: "연결 준비",
                badgeTone: .orange,
                summary: "앱은 실행 중이지만 연결 준비가 끝나지 않았습니다",
                primaryActionTitle: "앱을 켜 둔 채 잠시 대기",
                primaryActionDetail: "잠시 기다린 뒤 다시 확인해 주세요.",
                detectorSummary: detectorSummary,
                steps: [
                    .init(title: "앱 유지", detail: "앱을 계속 실행 상태로 둡니다."),
                    .init(title: "연결 준비", detail: "연결 토큰이 잡히는지 확인합니다."),
                    .init(title: "다시 확인", detail: "준비가 끝나면 다시 조회합니다."),
                ],
                pathHints: antigravityPathHints
            )
        }

        if signals.hasPersistedAuthState {
            return .init(
                stage: .waitingForApp,
                badgeTitle: "앱 필요",
                badgeTone: .orange,
                summary: "로그인 흔적은 있지만 앱이 실행 중이 아닙니다",
                primaryActionTitle: "Antigravity 앱 실행",
                primaryActionDetail: "앱을 실행한 뒤 다시 확인해 주세요.",
                detectorSummary: detectorSummary,
                steps: [
                    .init(title: "앱 실행", detail: "Antigravity 앱을 실행합니다."),
                    .init(title: "연결 준비", detail: "실행 후 연결 상태를 확인합니다."),
                    .init(title: "다시 확인", detail: "앱이 준비되면 다시 조회합니다."),
                ],
                pathHints: antigravityPathHints
            )
        }

        if signals.appRunning {
            return .init(
                stage: .authRequired,
                badgeTitle: "로그인 필요",
                badgeTone: .red,
                summary: "앱은 실행 중이지만 로그인 상태를 찾지 못했습니다",
                primaryActionTitle: "앱 안에서 로그인",
                primaryActionDetail: "앱 안에서 로그인을 완료한 뒤 다시 확인해 주세요.",
                detectorSummary: detectorSummary,
                steps: [
                    .init(title: "앱 로그인", detail: "Antigravity 앱에서 인증을 완료합니다."),
                    .init(title: "상태 확인", detail: "로그인 정보가 저장됐는지 확인합니다."),
                    .init(title: "다시 확인", detail: "그 뒤 연결 상태를 다시 읽습니다."),
                ],
                pathHints: antigravityPathHints
            )
        }

        if environmentStatus?.isDetected == true {
            return .init(
                stage: .waitingForApp,
                badgeTitle: "앱 필요",
                badgeTone: .orange,
                summary: "로컬 상태는 보이지만 앱이 실행 중이 아닙니다",
                primaryActionTitle: "앱 실행 후 다시 확인",
                primaryActionDetail: "앱을 실행한 뒤 연결 상태를 다시 읽습니다.",
                detectorSummary: detectorSummary,
                steps: [
                    .init(title: "앱 실행", detail: "Antigravity를 먼저 실행합니다."),
                    .init(title: "다시 확인", detail: "실행 후 연결 상태를 읽습니다."),
                ],
                pathHints: antigravityPathHints
            )
        }

        return .init(
            stage: .authRequired,
            badgeTitle: "초기 준비",
            badgeTone: .red,
            summary: "앱 실행과 로그인이 필요합니다",
            primaryActionTitle: "앱 실행 후 로그인",
            primaryActionDetail: "앱을 열고 로그인한 뒤 다시 확인해 주세요.",
            detectorSummary: detectorSummary,
            steps: [
                .init(title: "앱 실행", detail: "Antigravity 앱을 먼저 실행합니다."),
                .init(title: "인증 완료", detail: "앱 안에서 로그인을 완료합니다."),
                .init(title: "다시 확인", detail: "로그인 후 연결 상태를 다시 읽습니다."),
            ],
            pathHints: antigravityPathHints
        )
    }

    private static let geminiPathHints: [String] = [
        "~/.gemini/oauth_creds.json",
        "~/.gemini/settings.json",
    ]

    private static let antigravityPathHints: [String] = [
        "~/Library/Application Support/Antigravity/User/globalStorage/state.vscdb",
        "~/.antigravity",
    ]
}
