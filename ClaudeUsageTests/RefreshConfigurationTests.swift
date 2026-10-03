import Combine
import XCTest
@testable import ClaudeUsage

@MainActor
final class RefreshConfigurationTests: XCTestCase {
    func testAutoRefreshReachesSchedulingBeforeSettingsSetterCompletes() throws {
        let settings = try makeSettings()
        let coordinator = AppRuntimeObservationCoordinator()
        var received: [RuntimeRefreshConfiguration] = []
        coordinator.bind(
            settings: settings,
            onRefreshConfigurationChanged: { received.append($0) },
            onUpdateConfigurationChanged: {}, onMenuBarDisplayChanged: {},
            onProviderSelectionChanged: { _ in }, onClaudeCredentialContextChanged: {}
        )
        settings.autoRefresh = false
        XCTAssertEqual(received.last?.autoRefresh, false)
        settings.autoRefresh = true
        XCTAssertEqual(received.last?.autoRefresh, true)
        let count = received.count
        settings.autoRefresh = true
        XCTAssertEqual(received.count, count)
        coordinator.cancelAll()
        settings.autoRefresh = false
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
