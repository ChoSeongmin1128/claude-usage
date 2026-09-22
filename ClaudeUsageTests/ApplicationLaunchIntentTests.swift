import XCTest
@testable import ClaudeUsage

@MainActor
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

    func testRelaunchAfterMoveIsAbsentUnlessRequested() {
        XCTAssertNil(
            ApplicationLaunchIntent.parse(
                arguments: [
                    "ClaudeUsage-stg",
                    "--show-settings=common",
                ]
            ).relaunchAfterMovePredecessor
        )
    }

    func testRelaunchAfterMoveCarriesPredecessorProcess() {
        XCTAssertEqual(
            ApplicationLaunchIntent.parse(
                arguments: [
                    "ClaudeUsage-stg",
                    ApplicationLaunchIntent
                        .relaunchAfterMoveArgument(
                            predecessor: 4_321
                        ),
                ]
            ).relaunchAfterMovePredecessor,
            4_321
        )
    }

    /// 프로세스를 지목하지 못하는 값은 대기 근거가 되지 못하므로 무시한다.
    func testRelaunchAfterMoveRejectsUnusableProcessValues() {
        for rawValue in ["", "0", "-1", "abc", "12.5"] {
            XCTAssertNil(
                ApplicationLaunchIntent.parse(
                    arguments: [
                        "ClaudeUsage-stg",
                        ApplicationLaunchIntent
                            .relaunchAfterMovePrefix
                            + rawValue,
                    ]
                ).relaunchAfterMovePredecessor,
                rawValue
            )
        }
    }
}
