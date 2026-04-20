import AppKit
import Foundation

final class ProviderStyleMenuSelection: NSObject {
    let service: PopoverService
    let style: MenuBarStyle

    init(service: PopoverService, style: MenuBarStyle) {
        self.service = service
        self.style = style
    }
}

struct StatusContextMenuActions {
    let refreshAll: Selector
    let settings: Selector
    let openUsage: Selector
    let quit: Selector
    let toggleProvider: Selector
    let refreshProvider: Selector
    let changeProviderStyle: Selector
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
        menu.addItem(makeItem(title: "설정...", action: actions.settings, keyEquivalent: ","))
        menu.addItem(makeItem(title: "사용량 상세 보기", action: actions.openUsage, keyEquivalent: "u"))
        menu.addItem(makeItem(title: "종료", action: actions.quit, keyEquivalent: "q"))
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
        let kind = service.providerKind

        menu.addItem(toggleItem(
            title: "\(serviceName) 모니터링 활성화",
            isEnabled: settings.isProviderEnabled(kind),
            action: actions.toggleProvider,
            representedObject: service.rawValue))
        menu.addItem(refreshItem(
            title: "\(serviceName) 새로고침",
            isEnabled: canRefresh,
            action: actions.refreshProvider,
            representedObject: service.rawValue))
        menu.addItem(styleItem(
            title: "\(serviceName) 아이콘 스타일",
            service: service,
            currentStyle: settings.menuBarStyle(for: kind) ?? .none,
            action: actions.changeProviderStyle))
    }

    private static func makeItem(
        title: String,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
    }

    private static func toggleItem(
        title: String,
        isEnabled: Bool,
        action: Selector,
        representedObject: Any?
    ) -> NSMenuItem {
        let item = makeItem(title: title, action: action)
        item.state = isEnabled ? .on : .off
        item.representedObject = representedObject
        return item
    }

    private static func refreshItem(
        title: String,
        isEnabled: Bool,
        action: Selector,
        representedObject: Any?
    ) -> NSMenuItem {
        let item = makeItem(title: title, action: action)
        item.isEnabled = isEnabled
        item.representedObject = representedObject
        return item
    }

    private static func styleItem(
        title: String,
        service: PopoverService,
        currentStyle: MenuBarStyle,
        action: Selector
    ) -> NSMenuItem {
        let submenu = NSMenu()
        for style in MenuBarStyle.allCases {
            let item = makeItem(title: style.displayName, action: action)
            item.representedObject = ProviderStyleMenuSelection(service: service, style: style)
            item.state = currentStyle == style ? .on : .off
            submenu.addItem(item)
        }

        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }
}
