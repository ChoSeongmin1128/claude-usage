import Foundation

struct ProviderEnvironmentStatus: Sendable, Equatable {
    let isDetected: Bool
    let summary: String
}

enum ProviderEnvironmentDetector {
    private enum GeminiAuthType: String {
        case oauthPersonal = "oauth-personal"
        case apiKey = "api-key"
        case vertexAI = "vertex-ai"
        case unknown
    }

    static func status(for kind: AppProviderKind) -> ProviderEnvironmentStatus? {
        switch kind {
        case .claude:
            return nil
        case .codex:
            return ProviderEnvironmentStatus(
                isDetected: CodexAuthManager.shared.isAuthenticated,
                summary: CodexAuthManager.shared.isAuthenticated ? "CLI/OAuth 인증 감지" : "CLI/OAuth 인증 미감지"
            )
        case .gemini:
            return geminiStatus()
        case .antigravity:
            return antigravityStatus()
        }
    }

    private static func geminiStatus() -> ProviderEnvironmentStatus {
        let hasBinary = binaryExists(named: "gemini")
        let authType = geminiAuthType()
        let credentialState = geminiCredentialState()

        switch authType {
        case .apiKey:
            return ProviderEnvironmentStatus(
                isDetected: false,
                summary: hasBinary ? "Gemini CLI 감지됨 · 현재 인증 방식은 API 키입니다" : "Gemini CLI 미설치"
            )
        case .vertexAI:
            return ProviderEnvironmentStatus(
                isDetected: false,
                summary: hasBinary ? "Gemini CLI 감지됨 · 현재 인증 방식은 Vertex AI입니다" : "Gemini CLI 미설치"
            )
        case .oauthPersonal, .unknown:
            break
        }

        switch (hasBinary, credentialState) {
        case (true, .usable):
            return ProviderEnvironmentStatus(isDetected: true, summary: "Gemini CLI OAuth 감지")
        case (true, .refreshOnly):
            return ProviderEnvironmentStatus(isDetected: true, summary: "Gemini CLI OAuth 감지 · 액세스 토큰은 갱신이 필요합니다")
        case (true, .missing):
            return ProviderEnvironmentStatus(isDetected: false, summary: "Gemini CLI 감지됨 · 로그인 필요")
        case (false, .usable), (false, .refreshOnly):
            return ProviderEnvironmentStatus(isDetected: false, summary: "Gemini OAuth 자격은 있지만 CLI가 없습니다")
        case (false, .missing):
            return ProviderEnvironmentStatus(isDetected: false, summary: "Gemini CLI 미설치")
        }
    }

    private static func antigravityStatus() -> ProviderEnvironmentStatus {
        let hasLegacyStateDirectory = FileManager.default.fileExists(
            atPath: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".gemini/antigravity").path
        )
        let hasHomeStateDirectory = FileManager.default.fileExists(
            atPath: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".antigravity").path
        )
        let hasApplicationSupportDirectory = FileManager.default.fileExists(
            atPath: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Antigravity").path
        )
        let hasStateDirectory = hasLegacyStateDirectory || hasHomeStateDirectory || hasApplicationSupportDirectory
        let appRunning = AntigravityStatusProbe.appProcessRunning()
        let runningProcess = AntigravityStatusProbe.runningProcess()

        switch (runningProcess, hasStateDirectory) {
        case let (.some(process), true) where process.csrfToken != nil:
            return ProviderEnvironmentStatus(
                isDetected: true,
                summary: "Antigravity language server와 로컬 상태 디렉토리 감지"
            )
        case let (.some(process), false) where process.csrfToken != nil:
            return ProviderEnvironmentStatus(
                isDetected: true,
                summary: "Antigravity language server 감지"
            )
        case let (.some(process), _):
            let portSuffix = process.extensionPort.map { " · 포트 \($0)" } ?? ""
            return ProviderEnvironmentStatus(
                isDetected: false,
                summary: "Antigravity language server는 실행 중이지만 연결 토큰이 없습니다\(portSuffix)"
            )
        case (nil, _) where appRunning:
            return ProviderEnvironmentStatus(
                isDetected: false,
                summary: "Antigravity 앱은 실행 중이지만 quota language server가 아직 준비되지 않았습니다"
            )
        case (nil, true):
            return ProviderEnvironmentStatus(
                isDetected: false,
                summary: "Antigravity 로컬 상태는 있지만 quota language server는 아직 실행되지 않았습니다"
            )
        case (nil, false):
            return ProviderEnvironmentStatus(
                isDetected: false,
                summary: "Antigravity 상태 미감지"
            )
        }
    }

    private static func binaryExists(named name: String) -> Bool {
        let candidates = binaryCandidateDirectories()
        let fm = FileManager.default
        return candidates.contains { fm.isExecutableFile(atPath: ($0 as NSString).appendingPathComponent(name)) }
    }

    private static func binaryCandidateDirectories() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let envPaths = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        let fallbackPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "\(home)/.bun/bin",
            "\(home)/.npm/bin",
            "\(home)/.local/bin",
            "\(home)/bin",
        ]
        return Array(Set(envPaths + fallbackPaths))
    }

    private enum GeminiCredentialState {
        case usable
        case refreshOnly
        case missing
    }

    private static func geminiAuthType() -> GeminiAuthType {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/settings.json")

        guard
            let data = try? Data(contentsOf: settingsURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let security = json["security"] as? [String: Any],
            let auth = security["auth"] as? [String: Any],
            let selectedType = auth["selectedType"] as? String
        else {
            return .unknown
        }

        return GeminiAuthType(rawValue: selectedType) ?? .unknown
    }

    private static func geminiCredentialState() -> GeminiCredentialState {
        let credsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/oauth_creds.json")
        guard
            let data = try? Data(contentsOf: credsURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .missing
        }

        let accessToken = (json["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let refreshToken = (json["refresh_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let accessToken, !accessToken.isEmpty {
            return .usable
        }
        if let refreshToken, !refreshToken.isEmpty {
            return .refreshOnly
        }
        return .missing
    }
}
