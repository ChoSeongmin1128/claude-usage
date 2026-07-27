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

struct ProviderStyleMenuConfiguration {
    let currentStyle: MenuBarStyle
    let availableStyles: [MenuBarStyle]
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
        styleConfigurations:
            [PopoverService:
                ProviderStyleMenuConfiguration],
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

        // 프로바이더당 3행씩 늘어놓는 대신 서브메뉴 하나로 묶는다.
        // 부모 항목의 체크 표시가 모니터링 on/off 상태를 한눈에 알려준다.
        for service in runtimeServices {
            menu.addItem(providerSubmenuItem(
                service,
                settings: settings,
                canRefresh: refreshableServiceSet.contains(service),
                styleConfiguration:
                    styleConfigurations[service],
                actions: actions))
        }

        menu.addItem(.separator())
        menu.addItem(makeItem(title: "설정...", action: actions.settings, keyEquivalent: ","))
        menu.addItem(makeItem(title: "사용량 상세 보기", action: actions.openUsage, keyEquivalent: "u"))
        menu.addItem(makeItem(title: "종료", action: actions.quit, keyEquivalent: "q"))
        return menu
    }

    private static func providerSubmenuItem(
        _ service: PopoverService,
        settings: AppSettings,
        canRefresh: Bool,
        styleConfiguration:
            ProviderStyleMenuConfiguration?,
        actions: StatusContextMenuActions
    ) -> NSMenuItem {
        let serviceName = service.displayName
        let kind = service.providerKind
        let isMonitoring = settings.isProviderEnabled(kind)

        let submenu = NSMenu()
        submenu.addItem(refreshItem(
            title: "새로고침",
            isEnabled: canRefresh,
            action: actions.refreshProvider,
            representedObject: service.rawValue))
        if let styleConfiguration {
            submenu.addItem(styleItem(
                title: "아이콘 스타일",
                service: service,
                currentStyle:
                    styleConfiguration.currentStyle,
                availableStyles:
                    styleConfiguration.availableStyles,
                action: actions.changeProviderStyle))
        }
        submenu.addItem(.separator())
        // 컨트롤 문구는 실행 결과를 그대로 말한다: 켜기/끄기
        submenu.addItem(toggleItem(
            title: isMonitoring ? "모니터링 끄기" : "모니터링 켜기",
            isEnabled: false,
            action: actions.toggleProvider,
            representedObject: service.rawValue))

        let parent = NSMenuItem(title: serviceName, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        parent.state = isMonitoring ? .on : .off
        return parent
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
        availableStyles: [MenuBarStyle],
        action: Selector
    ) -> NSMenuItem {
        let submenu = NSMenu()
        for style in availableStyles {
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
