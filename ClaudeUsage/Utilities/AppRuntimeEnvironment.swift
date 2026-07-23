import Foundation

enum AppRuntimeEnvironment {
    nonisolated static var isRunningUnitTests: Bool {
        isRunningUnitTests(environment: ProcessInfo.processInfo.environment)
    }

    nonisolated static func isRunningUnitTests(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }
}
