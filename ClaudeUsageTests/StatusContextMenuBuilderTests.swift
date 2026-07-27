import AppKit
import XCTest
@testable import ClaudeUsage

@MainActor
final class StatusContextMenuBuilderTests:
    XCTestCase
{
    func testAntigravityStyleMenuUsesTypedSupportedStyles()
        throws
    {
        let menu = StatusContextMenuBuilder.build(
            settings: AppSettings.shared,
            runtimeServices: [.antigravity],
            refreshableServiceSet: [.antigravity],
            styleConfigurations: [
                .antigravity:
                    ProviderStyleMenuConfiguration(
                        currentStyle: .batteryBar,
                        availableStyles: [
                            .none,
                            .batteryBar,
                            .circular,
                        ]
                    ),
            ],
            actions: Self.actions
        )

        let provider = try XCTUnwrap(
            menu.items.first {
                $0.title == "Antigravity"
            }
        )
        let styleRoot = try XCTUnwrap(
            provider.submenu?.items.first {
                $0.title == "아이콘 스타일"
            }
        )
        let styles = try XCTUnwrap(
            styleRoot.submenu?.items
        )

        XCTAssertEqual(
            styles.map(\.title),
            ["없음", "배터리바", "원형"]
        )
        XCTAssertEqual(
            styles.map(\.state),
            [.off, .on, .off]
        )
    }

    private static let actions =
        StatusContextMenuActions(
            refreshAll:
                NSSelectorFromString(
                    "refreshAll:"
                ),
            settings:
                NSSelectorFromString(
                    "settings:"
                ),
            openUsage:
                NSSelectorFromString(
                    "openUsage:"
                ),
            quit:
                NSSelectorFromString(
                    "quit:"
                ),
            toggleProvider:
                NSSelectorFromString(
                    "toggleProvider:"
                ),
            refreshProvider:
                NSSelectorFromString(
                    "refreshProvider:"
                ),
            changeProviderStyle:
                NSSelectorFromString(
                    "changeProviderStyle:"
                )
        )
}
