import Darwin
import Foundation

/// 짧게 끝나는 외부 명령(공식 CLI, `/usr/bin/security`)을 찾고 실행한다.
nonisolated enum ExternalCommand {
    struct Output: Sendable {
        let status: Int32
        let data: Data

        var succeeded: Bool { status == 0 }
    }

    /// 앱은 로그인 셸 환경을 물려받지 않으므로 CLI가 설치되는 위치를 직접 넣는다.
    /// npm으로 설치한 CLI는 `#!/usr/bin/env node`라 node가 있는 위치도 PATH에 있어야 한다.
    static func searchDirectories(home: URL = FileManager.default.realHomeDirectory) -> [String] {
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .map(String.init).filter { $0.hasPrefix("/") }
        let preferred = ["/opt/homebrew/bin", "/usr/local/bin"]
        let userLocal = [".local/bin", ".npm-global/bin", ".npm/bin", ".bun/bin", "bin"].map {
            home.appendingPathComponent($0).path
        }
        var seen: Set<String> = []
        return (preferred + inherited + userLocal + ["/usr/bin", "/bin"]).filter { seen.insert($0).inserted }
    }

    static func searchPath(home: URL = FileManager.default.realHomeDirectory) -> String {
        searchDirectories(home: home).joined(separator: ":")
    }

    /// 다른 사용자가 바꿔 둘 수 없는 일반 실행 파일만 실행한다.
    static func isTrustedExecutable(_ url: URL) -> Bool {
        var info = stat()
        return stat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_mode & 0o022 == 0
            && (info.st_uid == getuid() || info.st_uid == 0) && access(url.path, X_OK) == 0
    }

    static func firstTrustedExecutable(in candidates: [URL]) -> URL? {
        candidates.lazy.map { $0.resolvingSymlinksInPath() }.first(where: isTrustedExecutable)
    }

    /// 출력은 실행 중에 계속 읽어 파이프가 가득 차 멈추지 않게 한다. 시간이 지나거나 작업이 취소되면
    /// 프로세스 그룹을 종료하고 nil을 돌려준다. 종료 요청에 응하지 않으면 잠시 뒤 강제로 끝낸다. 실행하지 못해도 nil이다.
    static func run(
        _ executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL? = nil,
        input: Data? = nil, timeout: TimeInterval
    ) async -> Output? {
        await run(
            OwnedProcessRun.Request(
                executable: executable, arguments: arguments, environment: environment,
                currentDirectory: currentDirectory, input: input, timeout: timeout))
    }

    static func run(_ request: OwnedProcessRun.Request) async -> Output? {
        let running = OwnedProcessRun()
        return await withTaskCancellationHandler {
            await BlockingWork.run { running.run(request) }
        } onCancel: {
            running.cancel()
        }
    }
}
