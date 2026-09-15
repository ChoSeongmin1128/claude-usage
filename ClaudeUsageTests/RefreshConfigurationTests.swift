import Combine
import XCTest
@testable import ClaudeUsage

@MainActor
final class RefreshConfigurationTests: XCTestCase {
    func testPublishedValuesReachSchedulingBeforeSettingsSetterCompletes() throws {
        let settings = try makeSettings()
        let battery = CurrentValueSubject<Bool, Never>(false)
        let coordinator = AppRuntimeObservationCoordinator()
        var received: [RuntimeRefreshConfiguration] = []
        coordinator.bind(
            settings: settings, batteryPublisher: battery.eraseToAnyPublisher(),
            onRefreshConfigurationChanged: { received.append($0) },
            onUpdateConfigurationChanged: {}, onMenuBarDisplayChanged: {},
            onProviderSelectionChanged: { _ in }, onClaudeCredentialContextChanged: {}
        )
        settings.autoRefresh = false
        XCTAssertEqual(received.last?.autoRefresh, false)
        settings.refreshInterval = 60
        XCTAssertEqual(received.last?.interval, 60)
        settings.autoRefresh = true
        XCTAssertEqual(received.last?.autoRefresh, true)
        settings.refreshInterval = 30
        XCTAssertEqual(received.last?.interval, 30)
        settings.reducedRefreshOnBattery = true
        battery.send(true)
        XCTAssertEqual(received.last?.interval(for: .codex), 60)
        settings.reducedRefreshOnBattery = false
        XCTAssertEqual(received.last?.interval(for: .codex), 30)
        let count = received.count
        settings.refreshInterval = 30
        XCTAssertEqual(received.count, count)
        coordinator.cancelAll()
        settings.refreshInterval = 90
        XCTAssertEqual(received.count, count)
    }

    func testStoppedAndReplacedTimersCannotDeliverQueuedTicks() {
        var ticks: [@MainActor @Sendable () -> Void] = []
        var delivered = 0
        let scheduler = RefreshScheduler { interval, tick in
            ticks.append(tick)
            return Timer(timeInterval: interval, repeats: true) { _ in }
        }
        XCTAssertEqual(
            scheduler.sync(autoRefresh: true, shouldPoll: true, interval: 30) { delivered += 1 }, .started(30))
        ticks[0]()
        XCTAssertEqual(delivered, 1)
        XCTAssertEqual(scheduler.sync(autoRefresh: false, shouldPoll: true, interval: 30) { delivered += 1 }, .stopped)
        ticks[0]()
        XCTAssertEqual(delivered, 1)
        _ = scheduler.sync(autoRefresh: true, shouldPoll: true, interval: 60) { delivered += 1 }
        ticks[0]()
        ticks[1]()
        XCTAssertEqual(delivered, 2)
        XCTAssertEqual(scheduler.sync(autoRefresh: true, shouldPoll: true, interval: 60) { delivered += 1 }, .unchanged)
        XCTAssertEqual(ticks.count, 2)
        scheduler.stop()
        ticks[1]()
        XCTAssertEqual(delivered, 2)
    }

    func testProviderIntervalsAndBatteryPolicyUseSameConfiguration() throws {
        let settings = try makeSettings()
        settings.refreshInterval = 120
        settings.usePerProviderRefreshIntervals = true
        settings.claudeRefreshInterval = 120
        settings.codexRefreshInterval = 30
        settings.reducedRefreshOnBattery = true
        let configuration = RuntimeRefreshConfiguration(settings: settings, isOnBattery: false)
        XCTAssertEqual(configuration.timerInterval(for: [.claude, .codex]), 30)
        let actions = RefreshOrchestration.actionsForRefreshAll(
            supportedServices: [.claude, .codex], refreshableServices: [.claude, .codex],
            settings: settings, configuration: configuration, force: false,
            lastRefreshedAt: [.claude: Date(timeIntervalSinceNow: -40), .codex: Date(timeIntervalSinceNow: -40)]
        )
        XCTAssertEqual(actions.count, 1)
        guard case .refresh(service: .codex, force: false) = actions.first else {
            return XCTFail("Only the due provider should refresh")
        }
        let battery = RuntimeRefreshConfiguration(settings: settings, isOnBattery: true)
        XCTAssertEqual(battery.timerInterval(for: [.claude, .codex]), 60)
        XCTAssertEqual(battery.interval(for: .claude), 120)
        XCTAssertTrue(
            RefreshOrchestration.actionsForRefreshAll(
                supportedServices: [.codex], refreshableServices: [.codex],
                settings: settings, configuration: battery, force: false,
                lastRefreshedAt: [.codex: Date(timeIntervalSinceNow: -40)]
            ).isEmpty)
        settings.autoRefresh = false
        XCTAssertEqual(
            RefreshOrchestration.actionsForRefreshAll(
                supportedServices: [.codex], refreshableServices: [.codex],
                settings: settings, configuration: battery, force: true
            ).count, 1)
    }

    private func makeSettings() throws -> AppSettings {
        let suite = "RefreshConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AppSettings(defaults: defaults)
    }
}
