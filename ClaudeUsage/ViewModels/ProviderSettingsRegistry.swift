import Foundation

enum SettingsProviderPanel: String, CaseIterable, Identifiable, Sendable {
    case welcome
    case common
    case accounts
    case limits
    case display
    case updates

    var id: String { rawValue }

    /// 저장된 탭 값을 패널로 바꾼다. 이전 버전의 서비스별 탭은 계정 패널의 그 서비스로 연다.
    nonisolated static func resolve(storedValue: String) -> (panel: SettingsProviderPanel, provider: AppProviderKind?)?
    {
        if let panel = SettingsProviderPanel(rawValue: storedValue) { return (panel, nil) }
        if storedValue == "notifications" { return (.limits, nil) }
        if let provider = AppProviderKind(rawValue: storedValue) { return (.accounts, provider) }
        return nil
    }
}

struct SettingsProviderPanelDescriptor: Identifiable, Sendable, Equatable {
    enum Availability: Sendable, Equatable {
        case active
        case comingSoon(message: String)

        var badgeTitle: String? {
            switch self {
            case .active:
                return nil
            case .comingSoon:
                return "준비 중"
            }
        }

        var detailMessage: String? {
            switch self {
            case .active:
                return nil
            case .comingSoon(let message):
                return message
            }
        }
    }

    let panel: SettingsProviderPanel
    let title: String
    let icon: String?
    let providerKind: AppProviderKind?
    let availability: Availability

    var id: String { panel.rawValue }
}

enum SettingsProviderRegistry {
    nonisolated static let providerDescriptors: [ProviderDescriptor] = AppProviderKind.allCases.map(\.descriptor)

    nonisolated static var sidebarPanels: [SettingsProviderPanelDescriptor] {
        sidebarPanels(exposurePolicy: .allSupported)
    }

    nonisolated static func sidebarPanels(exposurePolicy: ProviderExposurePolicy) -> [SettingsProviderPanelDescriptor] {
        [
            .init(panel: .common, title: "일반", icon: "gearshape", providerKind: nil, availability: .active),
            .init(panel: .accounts, title: "계정", icon: "person.crop.circle", providerKind: nil, availability: .active),
            .init(
                panel: .limits, title: "한도", icon: "gauge.with.dots.needle.33percent", providerKind: nil,
                availability: .active),
            .init(panel: .display, title: "모양", icon: "paintbrush", providerKind: nil, availability: .active),
            .init(panel: .updates, title: "업데이트", icon: "arrow.down.circle", providerKind: nil, availability: .active),
        ]
    }
}
