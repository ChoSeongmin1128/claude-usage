import Foundation

/// `codex` CLI 바이너리 경로를 탐색한다.
///
/// macOS 메뉴바 앱은 launchd 가 띄우는 환경이라 사용자가 `~/.zshrc` 등으로 추가한
/// PATH 가 ProcessInfo.environment 에 포함되지 않는다. 그래서 환경변수 override →
/// well-known 설치 경로 → login shell `which` 순으로 탐색한다.
///
/// 차용: CodexBar (MIT License) Sources/CodexBarCore/PathEnvironment.swift 의 패턴을 축약.
/// Copyright (c) 2026 Peter Steinberger
enum CodexBinaryLocator {
    /// 환경변수로 codex 경로를 명시 override. 디버그/CI 환경에 유용.
    static let environmentOverrideKey = "CLAUDEUSAGE_CODEX_CLI_PATH"

    /// 사용자가 codex 를 설치할 가능성이 높은 경로들. 우선순위 순.
    static func wellKnownPaths(home: String = NSHomeDirectory()) -> [String] {
        [
            "\(home)/.local/bin/codex",
            "\(home)/.bun/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex"
        ]
    }

    /// 탐색 절차:
    ///   1) `CLAUDEUSAGE_CODEX_CLI_PATH` 환경변수 — 명시 override
    ///   2) ProcessInfo PATH 안의 `codex`
    ///   3) 미리 정의된 well-known 경로 중 실제 실행 가능한 첫 번째
    ///   4) login shell `which codex` (npm/bun 같은 동적 설치 경로 대응)
    /// 모두 실패 시 nil. 호출자는 CLI 미설치로 안내.
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        loginShellWhich: (String) -> String? = Self.defaultLoginShellWhich
    ) -> String? {
        // 1) 명시 override
        if let override = environment[environmentOverrideKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty,
           fileManager.isExecutableFile(atPath: override)
        {
            return override
        }

        // 2) ProcessInfo PATH
        if let path = environment["PATH"], !path.isEmpty {
            for component in path.split(separator: ":") {
                let candidate = "\(component)/codex"
                if fileManager.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }

        // 3) Well-known 경로
        for candidate in wellKnownPaths() where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }

        // 4) Login shell `which codex` (zsh/bash -lc)
        if let resolved = loginShellWhich("codex"),
           fileManager.isExecutableFile(atPath: resolved)
        {
            return resolved
        }

        return nil
    }

    /// 사용자의 login shell (zsh / bash) 안에서 `which BINARY` 실행.
    /// 출력의 첫 줄을 trim 후 반환. 타임아웃 1.5초.
    static func defaultLoginShellWhich(_ binary: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "command -v \(binary)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()  // 무시

        do {
            try process.run()
        } catch {
            return nil
        }

        // 1.5초 timeout
        let deadline = Date().addingTimeInterval(1.5)
        while process.isRunning, Date() < deadline {
            usleep(50_000) // 50ms
        }
        if process.isRunning {
            process.terminate()
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?
            .components(separatedBy: .newlines)
            .first(where: { !$0.isEmpty })?
            .trimmingCharacters(in: .whitespaces)
        return text?.isEmpty == false ? text : nil
    }
}
