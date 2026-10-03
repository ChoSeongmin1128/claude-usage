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

    func testDisplayNameFollowsBuildSettingButStorageNamesStayFixed() {
        let renamed = AppDistributionDescriptor.resolve(
            releaseChannelValue: "prod", bundleIdentifier: nil, displayName: "Usage Meter")
        XCTAssertEqual(renamed.appName, "Usage Meter")
        XCTAssertEqual(renamed.settingsWindowTitle, "Usage Meter 설정")
        XCTAssertEqual(renamed.bundleIdentifier, AppIdentifiers.productionBundleIdentifier)
        XCTAssertEqual(renamed.applicationSupportDirectoryName, AppIdentifiers.productionSupportDirectoryName)

        let unexpanded = AppDistributionDescriptor.resolve(
            releaseChannelValue: "staging", bundleIdentifier: nil, displayName: "$(CLAUDEUSAGE_APP_NAME)")
        XCTAssertEqual(unexpanded.appName, "ClaudeUsage-stg")
        XCTAssertEqual(unexpanded.applicationSupportDirectoryName, AppIdentifiers.stagingSupportDirectoryName)
    }
}
