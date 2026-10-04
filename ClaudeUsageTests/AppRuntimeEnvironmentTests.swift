import XCTest
@testable import ClaudeUsage

final class AppRuntimeEnvironmentTests: XCTestCase {
    func testUnitTestDetectionRequiresXCTestConfigurationPath() {
        XCTAssertFalse(AppRuntimeEnvironment.isRunningUnitTests(environment: [:]))
        XCTAssertFalse(
            AppRuntimeEnvironment.isRunningUnitTests(
                environment: ["UNRELATED_ENVIRONMENT_VARIABLE": "1"]
            )
        )
        XCTAssertTrue(
            AppRuntimeEnvironment.isRunningUnitTests(
                environment: ["XCTestConfigurationFilePath": "/private/tmp/test.xctestconfiguration"]
            )
        )
    }

    func testUnitTestsDoNotRunInstalledClaudeCodeUnlessAskedTo() {
        let test = ["XCTestConfigurationFilePath": "/private/tmp/test.xctestconfiguration"]
        XCTAssertTrue(AppRuntimeEnvironment.mayRunInstalledClaudeCode(environment: [:]))
        XCTAssertFalse(AppRuntimeEnvironment.mayRunInstalledClaudeCode(environment: test))
        XCTAssertTrue(
            AppRuntimeEnvironment.mayRunInstalledClaudeCode(
                environment: test.merging(["CLAUDEUSAGE_RUN_LIVE_CLAUDE_TESTS": "1"]) { $1 }))
        XCTAssertNil(ClaudeCodeCLI.executable(), "테스트 중에는 설치된 Claude Code를 고르지 않습니다")
    }
}
