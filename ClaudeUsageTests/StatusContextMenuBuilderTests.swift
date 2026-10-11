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
                $0.title == "게이지 모양"
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

    func testEachServiceSubmenuOwnsItsExternalActions() throws {
        let menu = StatusContextMenuBuilder.build(
            settings: try isolatedSettings(),
            runtimeServices: [.claude, .codex, .antigravity],
            refreshableServiceSet: [.claude, .codex, .antigravity],
            styleConfigurations: [
                .claude: ProviderStyleMenuConfiguration(currentStyle: .batteryBar, availableStyles: [.batteryBar])
            ],
            actions: Self.actions
        )

        let expected: [(PopoverService, [String], [String])] = [
            (
                .claude, ["새로고침", "게이지 모양", "사용량 보기", "서비스 상태 보기", "", "사용 켜기"],
                ["https://claude.ai/settings/usage", "https://status.claude.com/"]
            ),
            (
                .codex, ["새로고침", "사용량 보기", "서비스 상태 보기", "", "사용 켜기"],
                ["https://chatgpt.com/codex/settings/usage", "https://status.openai.com/"]
            ),
            (.antigravity, ["새로고침", "", "사용 켜기"], []),
        ]
        for (service, titles, destinations) in expected {
            let submenu = try XCTUnwrap(
                menu.items.first { $0.title == service.displayName }?.submenu)
            XCTAssertEqual(submenu.items.map(\.title), titles, service.rawValue)
            let external = submenu.items.filter {
                $0.action == Self.actions.openProviderExternalAction
            }
            XCTAssertEqual(external.compactMap { $0.representedObject as? String }, destinations, service.rawValue)
            XCTAssertTrue(external.allSatisfy { $0.keyEquivalent.isEmpty }, service.rawValue)
        }
    }

    func testTopLevelMenuHasNoExternalActionsAndOpensUpdatePanelAboveSettings() throws {
        let menu = StatusContextMenuBuilder.build(
            settings: try isolatedSettings(),
            runtimeServices: [.claude, .codex],
            refreshableServiceSet: [.claude, .codex],
            styleConfigurations: [:],
            actions: Self.actions
        )

        XCTAssertEqual(
            menu.items.map(\.title),
            ["전체 새로고침", "", "Claude", "Codex", "", "업데이트 확인...", "설정...", "종료"]
        )
        XCTAssertFalse(menu.items.contains { $0.action == Self.actions.openProviderExternalAction })
        XCTAssertEqual(
            menu.items.map(\.keyEquivalent).filter { !$0.isEmpty },
            ["r", ",", "q"]
        )

        let updateCheck = try XCTUnwrap(menu.items.first { $0.title == "업데이트 확인..." })
        XCTAssertEqual(updateCheck.action, Self.actions.openSettingsPanel)
        let rawValue = try XCTUnwrap(updateCheck.representedObject as? String)
        XCTAssertEqual(SettingsProviderPanel.resolve(storedValue: rawValue)?.panel, .updates)
    }

    func testMonitoringToggleTitleFollowsEnabledStateWithoutCheckmark() throws {
        let settings = try isolatedSettings()
        settings.setProviderEnabled(true, for: .codex)
        let menu = StatusContextMenuBuilder.build(
            settings: settings,
            runtimeServices: [.claude, .codex],
            refreshableServiceSet: [],
            styleConfigurations: [:],
            actions: Self.actions
        )

        let claude = try XCTUnwrap(menu.items.first { $0.title == "Claude" })
        let codex = try XCTUnwrap(menu.items.first { $0.title == "Codex" })
        XCTAssertEqual(claude.state, .off)
        XCTAssertEqual(codex.state, .on)
        let codexToggle = try XCTUnwrap(codex.submenu?.items.last)
        XCTAssertEqual(codexToggle.title, "사용 끄기")
        XCTAssertEqual(codexToggle.action, Self.actions.toggleProvider)
        XCTAssertEqual(codexToggle.state, .off)
        XCTAssertEqual(codexToggle.representedObject as? String, PopoverService.codex.rawValue)
        XCTAssertFalse(try XCTUnwrap(codex.submenu?.items.first).isEnabled)
    }

    func testAntigravityContextMenuDoesNotInventExternalActions() {
        let menu = StatusContextMenuBuilder.build(
            settings: AppSettings.shared,
            runtimeServices: [.antigravity],
            refreshableServiceSet: [.antigravity],
            styleConfigurations: [:],
            actions: Self.actions
        )

        let allItems = menu.items + menu.items.flatMap { $0.submenu?.items ?? [] }
        XCTAssertFalse(
            allItems.contains {
                $0.title.contains("사용량 보기")
                    || $0.title.contains("서비스 상태 보기")
            }
        )
    }

    private func isolatedSettings() throws -> AppSettings {
        let suite = "StatusContextMenuBuilderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        for kind in AppProviderKind.allCases { settings.setProviderEnabled(false, for: kind) }
        return settings
    }

    private static let actions =
        StatusContextMenuActions(
            refreshAll:
                NSSelectorFromString(
                    "refreshAll:"
                ),
            openSettingsPanel:
                NSSelectorFromString(
                    "openSettingsPanel:"
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
