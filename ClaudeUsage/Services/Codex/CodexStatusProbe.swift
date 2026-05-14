import Foundation

/// `codex /status` 슬래시 명령 응답에서 추출한 사용량 스냅샷.
struct CodexCLIStatusSnapshot: Equatable, Sendable {
    let credits: Double?
    let fiveHourPercentLeft: Int?
    let weeklyPercentLeft: Int?
    let fiveHourResetDescription: String?
    let weeklyResetDescription: String?
    let rawText: String
}

enum CodexStatusProbeError: Error, LocalizedError {
    case codexNotInstalled
    case parseFailed(String)
    case timedOut
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .codexNotInstalled:
            return "codex CLI 가 설치되어 있지 않습니다."
        case .parseFailed(let detail):
            return "codex 응답을 파싱하지 못했습니다 — \(detail)"
        case .timedOut:
            return "codex 응답 대기 시간 초과"
        case .launchFailed(let detail):
            return "codex 실행 실패 — \(detail)"
        }
    }
}

/// CodexPTYRunner 로 codex 를 띄워 `/status` 응답을 받고, 텍스트를 파싱한다.
///
/// OAuth 경로가 죽었거나 사용자가 명시 CLI 모드를 선택했을 때의 fallback 진입점.
/// 차용: CodexBar (MIT License) Sources/CodexBarCore/Providers/Codex/CodexStatusProbe.swift
struct CodexStatusProbe {
    private let runner: CodexPTYRunner

    init(runner: CodexPTYRunner = CodexPTYRunner()) {
        self.runner = runner
    }

    /// codex CLI 를 띄워 `/status` 출력을 캡처 + 파싱.
    /// CLI 미설치 / 응답 타임아웃 / 파싱 실패 시 throw.
    func fetch(timeout: TimeInterval = 8.0) async throws -> CodexCLIStatusSnapshot {
        guard let binary = CodexBinaryLocator.resolve() else {
            throw CodexStatusProbeError.codexNotInstalled
        }

        let result: CodexPTYRunner.Result
        do {
            result = try await runner.capture(
                binary: binary,
                slashCommand: "/status",
                markers: ["Credits:", "5h limit", "5-hour limit", "Weekly limit"],
                timeout: timeout
            )
        } catch let error as CodexPTYRunner.PTYError {
            switch error {
            case .openptyFailed, .spawnFailed:
                throw CodexStatusProbeError.launchFailed(error.localizedDescription)
            case .timedOut:
                throw CodexStatusProbeError.timedOut
            }
        } catch {
            throw CodexStatusProbeError.launchFailed(error.localizedDescription)
        }

        return try Self.parse(text: result.text)
    }

    /// 텍스트 응답에서 사용량 필드 추출.
    /// 5h / weekly 한 줄에서 "12% left" + "resets HH:MM on D MMM" 같은 형식.
    static func parse(text: String) throws -> CodexCLIStatusSnapshot {
        let clean = CodexTextParsing.stripANSICodes(text)
        guard !clean.isEmpty else {
            throw CodexStatusProbeError.parseFailed("응답이 비어 있음")
        }
        if clean.localizedCaseInsensitiveContains("data not available yet") {
            throw CodexStatusProbeError.parseFailed("Codex 가 'data not available yet' 응답")
        }

        let credits = CodexTextParsing.firstNumber(pattern: #"Credits:\s*([0-9][0-9.,]*)"#, text: clean)
        let fiveLine = CodexTextParsing.firstLine(matching: #"5h limit[^\n]*"#, text: clean)
            ?? CodexTextParsing.firstLine(matching: #"5-hour limit[^\n]*"#, text: clean)
        let weekLine = CodexTextParsing.firstLine(matching: #"Weekly limit[^\n]*"#, text: clean)

        let fivePct = fiveLine.flatMap(CodexTextParsing.percentLeft(fromLine:))
        let weekPct = weekLine.flatMap(CodexTextParsing.percentLeft(fromLine:))
        let fiveReset = fiveLine.flatMap(CodexTextParsing.resetString(fromLine:))
        let weekReset = weekLine.flatMap(CodexTextParsing.resetString(fromLine:))

        if credits == nil, fivePct == nil, weekPct == nil {
            throw CodexStatusProbeError.parseFailed(String(clean.prefix(400)))
        }

        return CodexCLIStatusSnapshot(
            credits: credits,
            fiveHourPercentLeft: fivePct,
            weeklyPercentLeft: weekPct,
            fiveHourResetDescription: fiveReset,
            weeklyResetDescription: weekReset,
            rawText: clean
        )
    }
}
