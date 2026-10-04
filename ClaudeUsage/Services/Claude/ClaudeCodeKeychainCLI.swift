import Foundation

/// Claude Code는 Keychain 항목을 `/usr/bin/security`로 쓰고 읽어서, 항목의 접근 목록이 `security`를 믿는다.
/// 같은 도구로 읽고 쓰면 Claude Code처럼 확인 창이 뜨지 않고, 앱이 직접 접근하면 로그인 Keychain 암호를 묻는다.
nonisolated enum ClaudeCodeKeychainCLI {
    enum Outcome: Equatable, Sendable {
        case payload(String)
        case notFound
        case failed
    }

    static let executable = URL(fileURLWithPath: "/usr/bin/security")
    static let itemNotFoundStatus: Int32 = 44
    static let timeout: TimeInterval = 5
    private static let environment = ["PATH": "/usr/bin:/bin"]

    static func read(service: String) async -> Outcome {
        guard
            let output = await ExternalCommand.run(
                executable, arguments: ["find-generic-password", "-w", "-s", service], environment: environment,
                timeout: timeout)
        else { return .failed }
        if output.status == itemNotFoundStatus { return .notFound }
        guard output.succeeded,
            let text = String(data: output.data, encoding: .utf8)?.trimmingCharacters(in: .newlines), !text.isEmpty
        else { return .failed }
        return .payload(text)
    }

    /// 항목이 있는지. 비밀 값은 읽지 않는다. 확인하지 못하면 nil이다.
    static func itemExists(service: String) async -> Bool? {
        guard
            let output = await ExternalCommand.run(
                executable, arguments: ["find-generic-password", "-s", service], environment: environment,
                timeout: timeout)
        else { return nil }
        if output.status == itemNotFoundStatus { return false }
        return output.succeeded ? true : nil
    }

    /// 항목의 계정 이름. 비밀 값은 읽지 않는다. 쓸 때 같은 항목을 고치려면 계정 이름이 같아야 한다.
    static func accountName(service: String) async -> String? {
        guard
            let output = await ExternalCommand.run(
                executable, arguments: ["find-generic-password", "-s", service], environment: environment,
                timeout: timeout),
            output.succeeded, let text = String(data: output.data, encoding: .utf8)
        else { return nil }
        let marker = "\"acct\"<blob>=\""
        guard let line = text.split(separator: "\n").first(where: { $0.contains(marker) }),
            let start = line.range(of: marker)?.upperBound, let end = line[start...].lastIndex(of: "\"")
        else { return nil }
        return String(line[start..<end])
    }

    /// 기존 항목의 값만 바꾼다. 명령을 표준 입력으로 넘겨 값이 프로세스 인자에 드러나지 않게 한다.
    /// 대화형 모드의 종료 코드는 명령 성공 여부를 보장하지 않아 다시 읽어 확인한다.
    static func update(service: String, account: String, payload: Data) async -> Bool {
        guard [service, account].allSatisfy({ !$0.contains("\"") && !$0.contains("\n") }) else { return false }
        let hex = payload.map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \(hex)\n"
        _ = await ExternalCommand.run(
            executable, arguments: ["-i"], environment: environment, input: Data(command.utf8), timeout: timeout)
        let expected = String(decoding: payload, as: UTF8.self).trimmingCharacters(in: .newlines)
        return await read(service: service) == .payload(expected)
    }
}
