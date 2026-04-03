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
    static func authPresentation(for provider: AppProviderKind, isEnabled: Bool) -> RuntimeProviderAuthPresentation? {
        switch provider {
        case .gemini:
            return makeGemini(
                isEnabled: isEnabled,
                environmentStatus: ProviderEnvironmentDetector.status(for: .gemini),
                signals: ProviderEnvironmentDetector.geminiSignals()
            )
        case .antigravity:
            return makeAntigravity(
                isEnabled: isEnabled,
                environmentStatus: ProviderEnvironmentDetector.status(for: .antigravity),
                signals: ProviderEnvironmentDetector.antigravitySignals()
            )
        case .claude, .codex:
            return nil
        }
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
                summary: "Gemini provider를 켜야 실제 환경 검사를 이어갑니다",
                primaryActionTitle: "먼저 provider 활성화",
                primaryActionDetail: "활성화 후에만 OAuth 자격, CLI 경로, 첫 quota 조회를 계속 확인합니다.",
                detectorSummary: detectorSummary,
                steps: [
                    .init(title: "활성화", detail: "Gemini provider를 켭니다."),
                    .init(title: "환경 확인", detail: "CLI와 OAuth 자격을 다시 읽습니다."),
                    .init(title: "첫 조회", detail: "첫 quota 성공 전에는 준비됨으로 올리지 않습니다."),
                ],
                pathHints: geminiPathHints
            )
        }

        if !signals.hasBinary {
            let detail = signals.credentialState == .missing
                ? "CLI와 OAuth 자격이 모두 준비되어야 첫 quota 조회를 시작할 수 있습니다."
                : "OAuth 자격은 감지됐지만 Gemini CLI 실행 파일이 없어 조회를 시작하지 못합니다."
            return .init(
                stage: .installRequired,
                badgeTitle: "설치 필요",
                badgeTone: .orange,
                summary: "Gemini CLI 설치 또는 PATH 확인이 먼저 필요합니다",
                primaryActionTitle: "CLI 실행 경로 정리",
                primaryActionDetail: detail,
                detectorSummary: detectorSummary,
                steps: [
                    .init(title: "CLI 경로 확인", detail: "`gemini` 실행 파일이 현재 사용자 PATH에서 보여야 합니다."),
                    .init(title: "OAuth 유지", detail: "OAuth 자격은 그대로 두고 실행 파일만 복구하면 됩니다."),
                    .init(title: "첫 조회 대기", detail: "경로가 보이면 다음 refresh에서 quota를 다시 시도합니다."),
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
                summary: "현재 Gemini CLI는 API 키 모드라서 이 앱이 직접 quota를 읽지 못합니다",
                primaryActionTitle: "OAuth 모드로 다시 로그인",
                primaryActionDetail: "Gemini provider는 개인 OAuth 자격을 읽는 흐름을 전제로 합니다. API 키 모드는 지원 범위 밖입니다.",
                detectorSummary: detectorSummary,
                steps: [
                    .init(title: "인증 방식 변경", detail: "Gemini CLI를 API 키가 아닌 OAuth 기준으로 다시 설정합니다."),
                    .init(title: "OAuth 자격 생성", detail: "`oauth_creds.json` 이 생기는지 확인합니다."),
                    .init(title: "quota 재검증", detail: "다음 refresh에서 project/quota 경로를 다시 확인합니다."),
                ],
                pathHints: geminiPathHints
            )
        case .vertexAI:
            return .init(
                stage: .unsupportedConfiguration,
                badgeTitle: "구성 변경",
                badgeTone: .orange,
                summary: "현재 Gemini CLI는 Vertex AI 모드라서 이 앱의 직접 quota 조회와 맞지 않습니다",
                primaryActionTitle: "개인 OAuth 경로로 전환",
                primaryActionDetail: "이 앱은 현재 Vertex AI 자격이 아니라 개인 OAuth 흐름만 직접 읽습니다.",
                detectorSummary: detectorSummary,
                steps: [
                    .init(title: "인증 방식 전환", detail: "Vertex AI 대신 개인 OAuth 모드로 다시 구성합니다."),
                    .init(title: "설정 파일 확인", detail: "`settings.json` 과 OAuth 자격 파일 상태를 함께 확인합니다."),
                    .init(title: "첫 quota 조회", detail: "전환 후 첫 성공 fetch가 나기 전까지는 준비됨으로 승격하지 않습니다."),
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
                summary: "Gemini CLI OAuth 로그인 후 다시 확인해야 합니다",
                primaryActionTitle: "Gemini CLI에서 OAuth 로그인",
                primaryActionDetail: "OAuth 자격이 감지되어야 access token 갱신과 quota 조회를 이어갈 수 있습니다.",
                detectorSummary: detectorSummary,
                steps: [
                    .init(title: "OAuth 로그인", detail: "Gemini CLI에서 개인 OAuth 로그인을 완료합니다."),
                    .init(title: "자격 생성 확인", detail: "`oauth_creds.json` 이 생성됐는지 확인합니다."),
                    .init(title: "첫 조회 대기", detail: "첫 성공 fetch 전에는 여전히 연결 확인 단계로 남습니다."),
                ],
                pathHints: geminiPathHints
            )
        case .refreshOnly:
            return .init(
                stage: .refreshingCredential,
                badgeTitle: "갱신 필요",
                badgeTone: .blue,
                summary: "토큰 갱신 후 연결 확인 중입니다",
                primaryActionTitle: "CLI 자격 갱신 대기",
                primaryActionDetail: "다음 refresh에서 access token 재발급, project 탐색, quota 조회를 차례로 다시 시도합니다.",
                detectorSummary: detectorSummary,
                steps: [
                    .init(title: "토큰 재발급", detail: "refresh token 기반으로 새 access token 을 요청합니다."),
                    .init(title: "project 확인", detail: "Code Assist / project 경로를 다시 읽습니다."),
                    .init(title: "quota 확인", detail: "첫 성공 전에는 준비됨이 아니라 연결 확인 단계로 유지합니다."),
                ],
                pathHints: geminiPathHints
            )
        case .usable:
            if environmentStatus?.runtimeReachability == true {
                return .init(
                    stage: .probingRuntime,
                    badgeTitle: "연결 확인 중",
                    badgeTone: .blue,
                    summary: "자격은 준비됐고 첫 quota 조회를 확인하는 단계입니다",
                    primaryActionTitle: "첫 성공 fetch 대기",
                    primaryActionDetail: "실제 payload가 생기기 전까지는 준비됨으로 올리지 않고 연결 확인 중으로 유지합니다.",
                    detectorSummary: detectorSummary,
                    steps: [
                        .init(title: "자격 사용", detail: "현재 OAuth 자격으로 runtime refresh를 시도합니다."),
                        .init(title: "첫 payload 확인", detail: "실사용량이 내려와야 비로소 안정 상태로 볼 수 있습니다."),
                    ],
                    pathHints: geminiPathHints
                )
            }
            return .init(
                stage: .installRequired,
                badgeTitle: "경로 확인",
                badgeTone: .orange,
                summary: "OAuth 자격은 있지만 지금 바로 조회를 시도할 실행 경로가 부족합니다",
                primaryActionTitle: "CLI 경로 또는 런타임 환경 점검",
                primaryActionDetail: "자격은 준비됐지만 실행 파일 경로나 런타임 접근성이 막혀 refresh를 바로 시작하지 못합니다.",
                detectorSummary: detectorSummary,
                steps: [
                    .init(title: "실행 파일 확인", detail: "`gemini` 실행 파일이 현재 환경에서 보이는지 확인합니다."),
                    .init(title: "다시 감지", detail: "경로 복구 후 이 화면에서 환경을 다시 읽습니다."),
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
                summary: "Antigravity provider를 켜야 앱 실행 상태와 quota 서버 연결을 계속 확인합니다",
                primaryActionTitle: "먼저 provider 활성화",
                primaryActionDetail: "활성화 후에만 persisted auth, 앱 실행, connect port 상태를 함께 추적합니다.",
                detectorSummary: detectorSummary,
                steps: [
                    .init(title: "활성화", detail: "Antigravity provider를 켭니다."),
                    .init(title: "앱 실행", detail: "로컬 앱과 language server 상태를 다시 읽습니다."),
                    .init(title: "첫 조회", detail: "첫 payload 전까지는 준비됨으로 올리지 않습니다."),
                ],
                pathHints: antigravityPathHints
            )
        }

        if signals.hasRuntimeConnection {
            return .init(
                stage: .probingRuntime,
                badgeTitle: "연결 확인 중",
                badgeTone: .blue,
                summary: "quota 서버 연결은 보이지만 첫 성공 조회를 아직 기다리는 단계입니다",
                primaryActionTitle: "앱을 유지한 채 첫 fetch 대기",
                primaryActionDetail: "CSRF 토큰과 connect port는 보이지만, 실제 quota payload가 생기기 전에는 준비됨으로 승격하지 않습니다.",
                detectorSummary: detectorSummary,
                steps: [
                    .init(title: "connect API 사용", detail: "현재 로컬 connect 포트로 실제 quota 호출을 시도합니다."),
                    .init(title: "첫 payload 확인", detail: "첫 성공 fetch 전에는 계속 연결 확인 단계로 남습니다."),
                ],
                pathHints: antigravityPathHints
            )
        }

        if signals.appRunning && signals.hasPersistedAuthState {
            return .init(
                stage: .waitingForApp,
                badgeTitle: "연결 준비",
                badgeTone: .orange,
                summary: "앱은 실행 중이지만 quota 서버 연결 토큰이 아직 준비되지 않았습니다",
                primaryActionTitle: "앱을 완전히 연 뒤 잠시 대기",
                primaryActionDetail: "persisted auth만으로는 부족하고, CSRF 토큰과 connect port가 모두 잡혀야 첫 조회를 시작합니다.",
                detectorSummary: detectorSummary,
                steps: [
                    .init(title: "앱 유지", detail: "앱과 local language server를 계속 실행 상태로 둡니다."),
                    .init(title: "연결 토큰 대기", detail: "CSRF 토큰과 connect port가 모두 생기는지 확인합니다."),
                    .init(title: "첫 quota 조회", detail: "연결 토큰이 갖춰지면 다음 refresh에서 payload를 시도합니다."),
                ],
                pathHints: antigravityPathHints
            )
        }

        if signals.hasPersistedAuthState {
            return .init(
                stage: .waitingForApp,
                badgeTitle: "앱 필요",
                badgeTone: .orange,
                summary: "인증 흔적은 있지만 앱 실행 전이라 quota 조회를 시작할 수 없습니다",
                primaryActionTitle: "Antigravity 앱 실행",
                primaryActionDetail: "persisted auth만으로는 준비됨이 아니고, 앱과 language server가 실제로 올라와야 합니다.",
                detectorSummary: detectorSummary,
                steps: [
                    .init(title: "앱 실행", detail: "Antigravity 앱을 먼저 실행합니다."),
                    .init(title: "language server 확인", detail: "앱이 connect 포트와 토큰을 노출하는지 기다립니다."),
                    .init(title: "첫 payload 확인", detail: "첫 성공 조회 전에는 계속 앱 필요/연결 확인 단계로 남습니다."),
                ],
                pathHints: antigravityPathHints
            )
        }

        if signals.appRunning {
            return .init(
                stage: .authRequired,
                badgeTitle: "로그인 필요",
                badgeTone: .red,
                summary: "앱은 실행 중이지만 인증 상태가 아직 없어 quota 조회를 시작하지 못합니다",
                primaryActionTitle: "앱 안에서 로그인 완료",
                primaryActionDetail: "local state에 인증 흔적이 생겨야 connect API 초기화를 계속 확인할 수 있습니다.",
                detectorSummary: detectorSummary,
                steps: [
                    .init(title: "앱 로그인", detail: "Antigravity 앱에서 인증을 완료합니다."),
                    .init(title: "상태 저장 확인", detail: "local state DB 또는 설정 디렉터리에 인증 흔적이 생기는지 확인합니다."),
                    .init(title: "연결 토큰 대기", detail: "그 다음에야 CSRF/port 여부를 계속 추적합니다."),
                ],
                pathHints: antigravityPathHints
            )
        }

        if environmentStatus?.isDetected == true {
            return .init(
                stage: .waitingForApp,
                badgeTitle: "앱 필요",
                badgeTone: .orange,
                summary: "로컬 상태는 감지됐지만 앱 실행 전이라 runtime 연결을 만들 수 없습니다",
                primaryActionTitle: "앱 실행 후 다시 확인",
                primaryActionDetail: "상태 디렉터리만으로는 부족하고, 실제 앱 실행과 connect 초기화가 필요합니다.",
                detectorSummary: detectorSummary,
                steps: [
                    .init(title: "앱 실행", detail: "Antigravity를 먼저 실행합니다."),
                    .init(title: "연결 상태 확인", detail: "실행 후 connect port와 CSRF 토큰을 다시 읽습니다."),
                ],
                pathHints: antigravityPathHints
            )
        }

        return .init(
            stage: .authRequired,
            badgeTitle: "초기 준비",
            badgeTone: .red,
            summary: "앱 실행과 인증 둘 다 아직 필요합니다",
            primaryActionTitle: "앱을 한 번 실행하고 로그인",
            primaryActionDetail: "상태 디렉터리, 인증 흔적, connect port가 차례대로 생겨야 첫 quota 조회를 시작할 수 있습니다.",
            detectorSummary: detectorSummary,
            steps: [
                .init(title: "앱 실행", detail: "Antigravity 앱을 먼저 실행합니다."),
                .init(title: "인증 완료", detail: "앱 내부 로그인으로 persisted auth 상태를 만듭니다."),
                .init(title: "connect 초기화", detail: "그 다음 CSRF/port가 보이는지 확인합니다."),
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
