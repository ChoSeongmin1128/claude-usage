import Foundation

struct ProviderEnvironmentStatus: Sendable, Equatable {
    let isDetected: Bool
    let summary: String
}

enum ProviderEnvironmentDetector {
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
        let credsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/oauth_creds.json")
        let hasCreds = FileManager.default.fileExists(atPath: credsURL.path)

        switch (hasBinary, hasCreds) {
        case (true, true):
            return ProviderEnvironmentStatus(isDetected: true, summary: "Gemini CLI와 OAuth 자격 감지")
        case (true, false):
            return ProviderEnvironmentStatus(isDetected: false, summary: "Gemini CLI 감지됨 · 로그인 필요")
        case (false, true):
            return ProviderEnvironmentStatus(isDetected: false, summary: "Gemini 자격 흔적은 있지만 CLI가 없습니다")
        case (false, false):
            return ProviderEnvironmentStatus(isDetected: false, summary: "Gemini CLI 미설치")
        }
    }

    private static func antigravityStatus() -> ProviderEnvironmentStatus {
        let antigravityURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity")
        let hasStateDirectory = FileManager.default.fileExists(atPath: antigravityURL.path)
        let runningProcess = AntigravityStatusProbe.runningProcess()

        switch (runningProcess != nil, hasStateDirectory) {
        case (true, true):
            return ProviderEnvironmentStatus(
                isDetected: true,
                summary: "Antigravity language server와 로컬 상태 디렉토리 감지"
            )
        case (true, false):
            return ProviderEnvironmentStatus(
                isDetected: true,
                summary: "Antigravity language server 감지"
            )
        case (false, true):
            return ProviderEnvironmentStatus(
                isDetected: false,
                summary: "Antigravity 상태 디렉토리는 있지만 실행 중인 language server는 없습니다"
            )
        case (false, false):
            return ProviderEnvironmentStatus(
                isDetected: false,
                summary: "Antigravity 상태 미감지"
            )
        }
    }

    private static func binaryExists(named name: String) -> Bool {
        let envPaths = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        let fallbackPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let candidates = Array(Set(envPaths + fallbackPaths))
        let fm = FileManager.default
        return candidates.contains { fm.isExecutableFile(atPath: ($0 as NSString).appendingPathComponent(name)) }
    }
}
