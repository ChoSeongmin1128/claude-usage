import AppKit
import Foundation

struct StatusContextMenuActions {
    let target: AnyObject
    let refreshAll: Selector
    let settings: Selector
    let openUsage: Selector
    let quit: Selector
    let claudeToggle: Selector
    let codexToggle: Selector
    let claudeRefresh: Selector
    let codexRefresh: Selector
    let claudeStyleChange: Selector
    let codexStyleChange: Selector
}

enum StatusContextMenuBuilder {
    static func build(
        settings: AppSettings,
        runtimeServices: [PopoverService],
        refreshableServiceSet: Set<PopoverService>,
        actions: StatusContextMenuActions
    ) -> NSMenu {
        let menu = NSMenu()

        let refreshAll = makeItem(
            title: "전체 새로고침",
            action: actions.refreshAll,
            target: actions.target,
            keyEquivalent: "r")
        refreshAll.isEnabled = !refreshableServiceSet.isEmpty
        menu.addItem(refreshAll)
        menu.addItem(.separator())

        for (index, service) in runtimeServices.enumerated() {
            if index > 0 {
                menu.addItem(.separator())
            }
            addRuntimeServiceSection(
                service,
                settings: settings,
                canRefresh: refreshableServiceSet.contains(service),
                actions: actions,
                to: menu)
        }

        menu.addItem(.separator())
        menu.addItem(makeItem(title: "설정...", action: actions.settings, target: actions.target, keyEquivalent: ","))
        menu.addItem(makeItem(title: "사용량 상세 보기", action: actions.openUsage, target: actions.target, keyEquivalent: "u"))
        menu.addItem(makeItem(title: "종료", action: actions.quit, target: actions.target, keyEquivalent: "q"))
        return menu
    }

    private static func addRuntimeServiceSection(
        _ service: PopoverService,
        settings: AppSettings,
        canRefresh: Bool,
        actions: StatusContextMenuActions,
        to menu: NSMenu
    ) {
        let serviceName = service.displayName
        switch service {
        case .claude:
            menu.addItem(toggleItem(
                title: "\(serviceName) 모니터링 활성화",
                isEnabled: settings.isProviderEnabled(.claude),
                action: actions.claudeToggle,
                target: actions.target))
            menu.addItem(refreshItem(
                title: "\(serviceName) 새로고침",
                isEnabled: canRefresh,
                action: actions.claudeRefresh,
                target: actions.target))
            menu.addItem(styleItem(
                title: "\(serviceName) 아이콘 스타일",
                currentStyle: settings.menuBarStyle,
                action: actions.claudeStyleChange,
                target: actions.target))
        case .codex:
            menu.addItem(toggleItem(
                title: "\(serviceName) 모니터링 활성화",
                isEnabled: settings.isProviderEnabled(.codex),
                action: actions.codexToggle,
                target: actions.target))
            menu.addItem(refreshItem(
                title: "\(serviceName) 새로고침",
                isEnabled: canRefresh,
                action: actions.codexRefresh,
                target: actions.target))
            menu.addItem(styleItem(
                title: "\(serviceName) 아이콘 스타일",
                currentStyle: settings.codexMenuBarStyle,
                action: actions.codexStyleChange,
                target: actions.target))
        }
    }

    private static func makeItem(
        title: String,
        action: Selector,
        target: AnyObject,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = target
        return item
    }

    private static func toggleItem(
        title: String,
        isEnabled: Bool,
        action: Selector,
        target: AnyObject
    ) -> NSMenuItem {
        let item = makeItem(title: title, action: action, target: target)
        item.state = isEnabled ? .on : .off
        return item
    }

    private static func refreshItem(
        title: String,
        isEnabled: Bool,
        action: Selector,
        target: AnyObject
    ) -> NSMenuItem {
        let item = makeItem(title: title, action: action, target: target)
        item.isEnabled = isEnabled
        return item
    }

    private static func styleItem(
        title: String,
        currentStyle: MenuBarStyle,
        action: Selector,
        target: AnyObject
    ) -> NSMenuItem {
        let submenu = NSMenu()
        for style in MenuBarStyle.allCases {
            let item = makeItem(title: style.displayName, action: action, target: target)
            item.representedObject = style
            item.state = currentStyle == style ? .on : .off
            submenu.addItem(item)
        }

        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }
}
