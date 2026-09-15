import Foundation

/// One committed scheduling decision, including values emitted before @Published's setter finishes.
struct RuntimeRefreshConfiguration: Equatable, Sendable {
    let autoRefresh: Bool
    let interval: TimeInterval
    let usePerProviderIntervals: Bool
    let claudeInterval: TimeInterval
    let codexInterval: TimeInterval
    let antigravityInterval: TimeInterval
    let reducedOnBattery: Bool
    let isOnBattery: Bool

    init(settings: AppSettings, isOnBattery: Bool) {
        self.init(
            autoRefresh: settings.autoRefresh,
            interval: settings.refreshInterval,
            usePerProviderIntervals: settings.usePerProviderRefreshIntervals,
            claudeInterval: settings.claudeRefreshInterval,
            codexInterval: settings.codexRefreshInterval,
            antigravityInterval: settings.antigravityRefreshInterval,
            reducedOnBattery: settings.reducedRefreshOnBattery,
            isOnBattery: isOnBattery
        )
    }

    init(
        autoRefresh: Bool, interval: TimeInterval, usePerProviderIntervals: Bool,
        claudeInterval: TimeInterval, codexInterval: TimeInterval, antigravityInterval: TimeInterval,
        reducedOnBattery: Bool, isOnBattery: Bool
    ) {
        self.autoRefresh = autoRefresh
        self.interval = AppSettings.normalizedRefreshInterval(interval)
        self.usePerProviderIntervals = usePerProviderIntervals
        self.claudeInterval = AppSettings.normalizedRefreshInterval(claudeInterval)
        self.codexInterval = AppSettings.normalizedRefreshInterval(codexInterval)
        self.antigravityInterval = AppSettings.normalizedRefreshInterval(antigravityInterval)
        self.reducedOnBattery = reducedOnBattery
        self.isOnBattery = isOnBattery
    }

    func interval(for service: PopoverService) -> TimeInterval {
        let value: TimeInterval
        if usePerProviderIntervals {
            switch service {
            case .claude: value = claudeInterval
            case .codex: value = codexInterval
            case .antigravity: value = antigravityInterval
            }
        } else {
            value = interval
        }
        return isOnBattery && reducedOnBattery ? max(value, 60) : value
    }

    func intervals(for services: [PopoverService]) -> [PopoverService: TimeInterval] {
        services.reduce(into: [:]) { result, service in result[service] = interval(for: service) }
    }
}
