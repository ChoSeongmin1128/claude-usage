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
            selectedService: .antigravity,
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

    func testCodexContextMenuUsesProviderExternalActions() throws {
        let menu = StatusContextMenuBuilder.build(
            settings: AppSettings.shared,
            runtimeServices: [.codex],
            selectedService: .codex,
            refreshableServiceSet: [.codex],
            styleConfigurations: [:],
            actions: Self.actions
        )

        let usage = try XCTUnwrap(
            menu.items.first {
                $0.title == "Codex 사용량 보기"
            }
        )
        let status = try XCTUnwrap(
            menu.items.first {
                $0.title == "Codex 서비스 상태 보기"
            }
        )

        XCTAssertEqual(usage.keyEquivalent, "u")
        XCTAssertEqual(
            usage.representedObject as? String,
            "https://chatgpt.com/codex/settings/usage"
        )
        XCTAssertEqual(status.keyEquivalent, "")
        XCTAssertEqual(
            status.representedObject as? String,
            "https://status.openai.com/"
        )
    }

    func testAntigravityContextMenuDoesNotInventExternalActions() {
        let menu = StatusContextMenuBuilder.build(
            settings: AppSettings.shared,
            runtimeServices: [.antigravity],
            selectedService: .antigravity,
            refreshableServiceSet: [.antigravity],
            styleConfigurations: [:],
            actions: Self.actions
        )

        XCTAssertFalse(
            menu.items.contains {
                $0.title.contains("사용량 보기")
                    || $0.title.contains("서비스 상태 보기")
            }
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
            openProviderExternalAction:
                NSSelectorFromString(
                    "openProviderExternalAction:"
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
