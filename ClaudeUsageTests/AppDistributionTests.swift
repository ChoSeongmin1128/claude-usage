import XCTest
@testable import ClaudeUsage

final class AppDistributionTests: XCTestCase {
    func testProductionDescriptorUsesProductionIdentity() {
        XCTAssertEqual(
            AppDistributionDescriptor.resolve(
                releaseChannelValue: "prod",
                bundleIdentifier:
                    "com.seongmin.ClaudeUsage"
            ),
            AppDistributionDescriptor(
                channel: .prod,
                appName: "ClaudeUsage",
                bundleIdentifier:
                    "com.seongmin.ClaudeUsage",
                applicationSupportDirectoryName:
                    "ClaudeUsage"
            )
        )
    }

    func testStagingDescriptorUsesSeparateIdentity() {
        XCTAssertEqual(
            AppDistributionDescriptor.resolve(
                releaseChannelValue: "staging",
                bundleIdentifier:
                    "com.seongmin.ClaudeUsage.staging"
            ),
            AppDistributionDescriptor(
                channel: .staging,
                appName: "ClaudeUsage-stg",
                bundleIdentifier:
                    "com.seongmin.ClaudeUsage.staging",
                applicationSupportDirectoryName:
                    "ClaudeUsage-stg"
            )
        )
    }

    func testStagingBundleIdentifierWinsWhenInfoKeyIsMissing() {
        XCTAssertEqual(
            AppDistributionDescriptor.resolve(
                releaseChannelValue: nil,
                bundleIdentifier:
                    "com.seongmin.ClaudeUsage.staging"
            ).channel,
            .staging
        )
    }

    func testSettingsWindowTitleUsesChannelAppName() {
        XCTAssertEqual(
            AppDistributionDescriptor.resolve(
                releaseChannelValue: "prod",
                bundleIdentifier:
                    "com.seongmin.ClaudeUsage"
            ).settingsWindowTitle,
            "ClaudeUsage 설정"
        )
        XCTAssertEqual(
            AppDistributionDescriptor.resolve(
                releaseChannelValue: "staging",
                bundleIdentifier:
                    "com.seongmin.ClaudeUsage.staging"
            ).settingsWindowTitle,
            "ClaudeUsage-stg 설정"
        )
    }
}
