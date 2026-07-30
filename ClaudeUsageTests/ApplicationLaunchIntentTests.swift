import XCTest
@testable import ClaudeUsage

final class ApplicationLaunchIntentTests: XCTestCase {
    func testParsesSupportedSettingsDestination() {
        for destination in [
            "common",
            "display",
            "notifications",
            "updates",
            "claude",
            "codex",
            "antigravity",
        ] {
            let intent = ApplicationLaunchIntent.parse(
                arguments: [
                    "/Applications/ClaudeUsage-stg.app/Contents/MacOS/ClaudeUsage-stg",
                    "--show-settings=\(destination.uppercased())",
                ]
            )

            XCTAssertEqual(
                intent.settingsPanelRawValue,
                destination
            )
            XCTAssertNil(
                intent.requestedPopoverService
            )
        }
    }

    func testParsesSupportedPopoverProvider() {
        for service in PopoverService.allCases {
            let intent =
                ApplicationLaunchIntent.parse(
                    arguments: [
                        "ClaudeUsage-stg",
                        "--show-popover=\(service.rawValue.uppercased())",
                    ]
                )

            XCTAssertEqual(
                intent.requestedPopoverService,
                service
            )
        }
    }

    func testSettingsTakesPriorityOverPopover() {
        let intent = ApplicationLaunchIntent
            .parse(
                arguments: [
                    "ClaudeUsage-stg",
                    "--show-settings=display",
                    "--show-popover=antigravity",
                ]
            )

        XCTAssertEqual(
            intent.settingsPanelRawValue,
            "display"
        )
        XCTAssertNil(
            intent.requestedPopoverService
        )
    }

    func testIgnoresUnsupportedOrUnrelatedArguments() {
        let unsupported =
            ApplicationLaunchIntent.parse(
                arguments: [
                    "ClaudeUsage-stg",
                    "--show-settings=unknown",
                    "--show-popover=unknown",
                ]
            )
        XCTAssertNil(
            unsupported.settingsPanelRawValue
        )
        XCTAssertNil(
            unsupported.requestedPopoverService
        )

        XCTAssertNil(
            ApplicationLaunchIntent.parse(
                arguments: [
                    "ClaudeUsage-stg",
                    "--unrelated",
                ]
            ).settingsPanelRawValue
        )
    }
}
