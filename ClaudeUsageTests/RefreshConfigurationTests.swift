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
        let harness = SchedulerHarness()
        var delivered: [[PopoverService]] = []
        XCTAssertEqual(
            harness.scheduler.sync(autoRefresh: true, shouldPoll: true, intervals: [.codex: 30]) {
                delivered.append($0)
            }, .started(30))
        harness.fire(after: 30)
        XCTAssertEqual(delivered, [[.codex]])
        let oldTicks = harness.ticks
        XCTAssertEqual(harness.scheduler.stop(), .stopped)
        oldTicks.forEach { $0() }
        XCTAssertEqual(delivered.count, 1)
        _ = harness.scheduler.sync(autoRefresh: true, shouldPoll: true, intervals: [.codex: 60]) {
            delivered.append($0)
        }
        oldTicks.forEach { $0() }
        harness.fire(after: 60)
        XCTAssertEqual(delivered, [[.codex], [.codex]])
        let count = harness.ticks.count
        XCTAssertEqual(
            harness.scheduler.sync(autoRefresh: true, shouldPoll: true, intervals: [.codex: 60]) {
                delivered.append($0)
            }, .unchanged)
        XCTAssertEqual(harness.ticks.count, count)
        harness.scheduler.stop()
        harness.fire(after: 60)
        XCTAssertEqual(delivered.count, 2)
    }

    func testResponseCompletionDoesNotSkipTheNextThirtySecondRefresh() {
        let harness = SchedulerHarness()
        var delivered = 0
        _ = harness.scheduler.sync(autoRefresh: true, shouldPoll: true, intervals: [.antigravity: 30]) { _ in
            delivered += 1
        }
        harness.fire(after: 30)
        XCTAssertEqual(delivered, 1)
        // A successful response and runtime resynchronization arrive one second
        // after the request. The original next deadline must remain at t=60.
        harness.advance(1)
        XCTAssertEqual(
            harness.scheduler.sync(autoRefresh: true, shouldPoll: true, intervals: [.antigravity: 30]) { _ in
                delivered += 1
            }, .unchanged)
        harness.fire(after: 29)
        XCTAssertEqual(delivered, 2)
        harness.fire(after: 30)
        XCTAssertEqual(delivered, 3)
    }

    func testDifferentProviderIntervalsKeepIndependentDeadlines() {
        let harness = SchedulerHarness()
        var delivered: [[PopoverService]] = []
        _ = harness.scheduler.sync(autoRefresh: true, shouldPoll: true, intervals: [.claude: 30, .codex: 45]) {
            delivered.append($0)
        }
        harness.fire(after: 30)
        XCTAssertEqual(harness.delays.last, 15)
        harness.fire(after: 15)
        harness.fire(after: 15)
        harness.fire(after: 30)
        XCTAssertEqual(delivered, [[.claude], [.codex], [.claude], [.claude, .codex]])
    }

    func testChangingOneProviderPreservesOtherDeadlinesAndRejectsOldCallbacks() {
        let harness = SchedulerHarness()
        var delivered: [[PopoverService]] = []
        _ = harness.scheduler.sync(autoRefresh: true, shouldPoll: true, intervals: [.claude: 30, .codex: 45]) {
            delivered.append($0)
        }
        let oldTick = harness.ticks[0]
        harness.advance(10)
        _ = harness.scheduler.sync(autoRefresh: true, shouldPoll: true, intervals: [.claude: 60, .codex: 45]) {
            delivered.append($0)
        }
        XCTAssertEqual(harness.delays.last, 35)
        harness.advance(20)
        oldTick()
        XCTAssertTrue(delivered.isEmpty)
        harness.fire(after: 15)
        XCTAssertEqual(delivered, [[.codex]])
        XCTAssertEqual(harness.delays.last, 25)
        harness.fire(after: 25)
        XCTAssertEqual(delivered.last, [.claude])
        _ = harness.scheduler.sync(autoRefresh: true, shouldPoll: true, intervals: [.claude: 60]) {
            delivered.append($0)
        }
        XCTAssertEqual(harness.delays.last, 60)
    }

    func testMissedTicksAfterSleepCoalesceWithoutDriftingOrBursting() {
        let harness = SchedulerHarness()
        var delivered: [[PopoverService]] = []
        _ = harness.scheduler.sync(autoRefresh: true, shouldPoll: true, intervals: [.claude: 30, .codex: 45]) {
            delivered.append($0)
        }
        let oldTick = harness.ticks[0]
        harness.fire(after: 300)
        XCTAssertEqual(delivered, [[.claude, .codex]])
        XCTAssertEqual(harness.delays.last, 15)
        oldTick()
        XCTAssertEqual(delivered.count, 1)
        harness.fire(after: 15)
        XCTAssertEqual(delivered.last, [.codex])
        XCTAssertEqual(harness.delays.last, 15)
    }

    func testEarlyWakeAndSynchronousDisableCannotProduceExtraRefreshes() {
        let harness = SchedulerHarness()
        var delivered = 0
        _ = harness.scheduler.sync(autoRefresh: true, shouldPoll: true, intervals: [.codex: 30]) { _ in
            delivered += 1
            harness.scheduler.stop()
        }
        harness.fire(after: 29)
        XCTAssertEqual(delivered, 0)
        XCTAssertEqual(harness.delays.last, 1)
        harness.fire(after: 1)
        XCTAssertEqual(delivered, 1)
        harness.fire(after: 30)
        XCTAssertEqual(delivered, 1)
    }

    func testProviderIntervalsAndBatteryPolicyUseSameConfiguration() throws {
        let settings = try makeSettings()
        settings.refreshInterval = 120
        settings.usePerProviderRefreshIntervals = true
        settings.claudeRefreshInterval = 120
        settings.codexRefreshInterval = 30
        settings.reducedRefreshOnBattery = true
        let configuration = RuntimeRefreshConfiguration(settings: settings, isOnBattery: false)
        XCTAssertEqual(configuration.intervals(for: [.claude, .codex]), [.claude: 120, .codex: 30])
        let battery = RuntimeRefreshConfiguration(settings: settings, isOnBattery: true)
        XCTAssertEqual(battery.intervals(for: [.claude, .codex]), [.claude: 120, .codex: 60])
        let harness = SchedulerHarness()
        var delivered: [[PopoverService]] = []
        _ = harness.scheduler.sync(
            autoRefresh: true, shouldPoll: true, intervals: configuration.intervals(for: [.claude, .codex])
        ) {
            delivered.append($0)
        }
        harness.fire(after: 30)
        harness.advance(10)
        _ = harness.scheduler.sync(
            autoRefresh: true, shouldPoll: true, intervals: battery.intervals(for: [.claude, .codex])
        ) {
            delivered.append($0)
        }
        harness.fire(after: 60)
        harness.fire(after: 20)
        XCTAssertEqual(delivered, [[.codex], [.codex], [.claude]])
        XCTAssertEqual(
            harness.scheduler.sync(
                autoRefresh: false, shouldPoll: true, intervals: battery.intervals(for: [.claude, .codex])
            ) { _ in
                XCTFail("Disabled automatic refresh must not fire")
            }, .stopped)
        settings.autoRefresh = false
        XCTAssertEqual(
            RefreshOrchestration.actionsForRefreshAll(
                supportedServices: [.codex], refreshableServices: [.codex], settings: settings, force: true
            ).count, 1)
    }

    private func makeSettings() throws -> AppSettings {
        let suite = "RefreshConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AppSettings(defaults: defaults)
    }
}

@MainActor
private final class SchedulerHarness {
    var instant = ContinuousClock.now
    var ticks: [@MainActor @Sendable () -> Void] = []
    var delays: [TimeInterval] = []
    lazy var scheduler = RefreshScheduler(now: { [unowned self] in instant }) { [unowned self] interval, tick in
        delays.append(interval)
        ticks.append(tick)
        return Timer(timeInterval: interval, repeats: false) { _ in }
    }
    func advance(_ seconds: Double) { instant = instant.advanced(by: .seconds(seconds)) }
    func fire(after seconds: Double) { advance(seconds); ticks.last?() }
}
