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
}
