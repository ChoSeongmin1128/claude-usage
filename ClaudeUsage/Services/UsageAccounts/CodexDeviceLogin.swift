import Combine
import Foundation

/// `CODEX_HOME=<앱이 만든 폴더> codex login --device-auth`를 실행하고 링크와 일회용 코드를 보여준다.
/// auth.json을 폴더 사이에 복사하지 않는다.
@MainActor
final class CodexDeviceLogin: ObservableObject {
    enum Phase: Equatable {
        case idle, starting, succeeded
        case waiting(URL, String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    private var process: Process?
    private var folder: URL?
    private var output = ""
    /// 이전 실행의 종료 처리가 새 실행의 상태를 바꾸지 않게 실행마다 번호를 붙인다.
    private var run = 0

    var isRunning: Bool { process?.isRunning == true }

    func start(onSuccess: @escaping @MainActor (URL) -> Void) {
        guard !isRunning else { return }
        guard let codex = try? CodexOwnerCLI().resolvedExecutable() else {
            phase = .failed("Codex를 찾지 못했습니다. ChatGPT 앱이나 Codex CLI를 설치하세요.")
            return
        }
        let folder = AppStoragePaths.codexAccountsDirectory().appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            phase = .failed("계정 폴더를 만들지 못했습니다.")
            return
        }
        run += 1
        let current = run
        self.folder = folder
        output = ""

        let process = Process()
        process.executableURL = codex
        process.arguments = ["login", "--device-auth"]
        process.environment = [
            "HOME": FileManager.default.realHomeDirectory.path, "CODEX_HOME": folder.path,
            "PATH": ExternalCommand.searchPath(), "LANG": "en_US.UTF-8",
        ]
        process.currentDirectoryURL = folder
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            Task { @MainActor in
                guard let self, self.run == current else { return }
                self.consume(text)
            }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in
                pipe.fileHandleForReading.readabilityHandler = nil
                guard let self, self.run == current else { return }
                self.process = nil
                if status == 0, FileManager.default.fileExists(atPath: CodexHomeAccount.authFile(in: folder).path) {
                    self.phase = .succeeded
                    self.folder = nil
                    onSuccess(folder)
                } else if self.phase != .idle {
                    self.phase = .failed("로그인을 마치지 못했습니다. 다시 시도하세요.")
                    self.discardFolder()
                }
            }
        }
        phase = .starting
        do {
            try process.run()
            self.process = process
        } catch {
            phase = .failed("Codex 로그인을 시작하지 못했습니다.")
            discardFolder()
        }
    }

    func cancel() {
        guard let process, process.isRunning else { return }
        phase = .idle
        process.terminate()
        discardFolder()
    }

    private func consume(_ text: String) {
        output += text
        guard let urlRange = output.range(of: #"https://auth\.openai\.com/\S+"#, options: .regularExpression),
            let url = URL(string: String(output[urlRange]))
        else { return }
        let code = output.range(of: #"\b[A-Z0-9]{4,}-[A-Z0-9]{4,}\b"#, options: .regularExpression).map {
            String(output[$0])
        }
        switch phase {
        case .starting, .waiting(_, ""): phase = .waiting(url, code ?? "")
        default: break
        }
    }

    /// 로그인을 마치지 못한 빈 폴더만 휴지통으로 옮긴다.
    private func discardFolder() {
        guard let folder else { return }
        try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        self.folder = nil
    }
}
