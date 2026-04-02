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

    static func canAttemptRefresh(for kind: AppProviderKind) -> Bool {
        switch kind {
        case .claude, .codex:
            return false
        case .gemini:
            switch geminiCredentialState() {
            case .usable, .refreshOnly:
                return true
            case .missing:
                return false
            }
        case .antigravity:
            return antigravitySignals().canAttemptRefresh
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
        let signals = antigravitySignals()
        let hasStateDirectory = signals.hasStateDirectory
        let appRunning = signals.appRunning
        let runningProcess = signals.runningProcess

        switch (runningProcess, hasStateDirectory, appRunning) {
        case let (.some(process), _, _) where process.csrfToken != nil:
            return ProviderEnvironmentStatus(
                isDetected: true,
                summary: "Antigravity language server와 로컬 상태 디렉토리 감지"
            )
        case let (.some(process), _, _):
            let portSuffix = process.extensionPort.map { " · 포트 \($0)" } ?? ""
            return ProviderEnvironmentStatus(
                isDetected: true,
                summary: "Antigravity language server 감지 · 연결 토큰 확인 중\(portSuffix)"
            )
        case (nil, _, true):
            return ProviderEnvironmentStatus(
                isDetected: true,
                summary: "Antigravity 앱은 실행 중이며 quota language server를 준비 중입니다"
            )
        case (nil, true, _):
            return ProviderEnvironmentStatus(
                isDetected: false,
                summary: "Antigravity 로컬 상태는 있지만 quota language server는 아직 실행되지 않았습니다"
            )
        case (nil, false, false):
            return ProviderEnvironmentStatus(
                isDetected: false,
                summary: "Antigravity 상태 미감지"
            )
        }
    }

    private struct AntigravitySignals {
        let hasStateDirectory: Bool
        let appRunning: Bool
        let runningProcess: AntigravityProcessSnapshot?

        var canAttemptRefresh: Bool {
            runningProcess != nil || appRunning || hasStateDirectory
        }
    }

    private static func antigravitySignals() -> AntigravitySignals {
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
        return AntigravitySignals(
            hasStateDirectory: hasLegacyStateDirectory || hasHomeStateDirectory || hasApplicationSupportDirectory,
            appRunning: AntigravityStatusProbe.appProcessRunning(),
            runningProcess: AntigravityStatusProbe.runningProcess()
        )
    }

    private static func binaryExists(named name: String) -> Bool {
        resolvedBinaryURL(named: name) != nil
    }

    private static func resolvedBinaryURL(named name: String) -> URL? {
        let fm = FileManager.default
        for directory in binaryCandidateDirectories() {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        if let shellPath = shellBinaryPath(named: name) {
            let url = URL(fileURLWithPath: shellPath)
            if fm.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        return nil
    }

    private static func shellBinaryPath(named name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(name)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
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
