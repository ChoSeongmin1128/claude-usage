import Foundation

enum AppRuntimeEnvironment {
    nonisolated static var isRunningUnitTests: Bool {
        isRunningUnitTests(environment: ProcessInfo.processInfo.environment)
    }

    nonisolated static func isRunningUnitTests(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }

    /// 단위 테스트가 이 기기의 실제 Claude Code를 실행하지 않게 한다. 실행하면 테스트 결과가 설치와 로그인 상태에
    /// 따라 달라지고, Claude Code가 실제 로그인의 토큰을 갱신한다. 실제 CLI가 필요한 시험은 이 변수를 켜고 돌린다.
    nonisolated static var mayRunInstalledClaudeCode: Bool {
        mayRunInstalledClaudeCode(environment: ProcessInfo.processInfo.environment)
    }

    nonisolated static func mayRunInstalledClaudeCode(environment: [String: String]) -> Bool {
        !isRunningUnitTests(environment: environment) || environment["CLAUDEUSAGE_RUN_LIVE_CLAUDE_TESTS"] == "1"
    }
}
