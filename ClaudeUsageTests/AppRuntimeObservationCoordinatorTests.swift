import XCTest
@testable import ClaudeUsage

@MainActor
final class AppRuntimeObservationCoordinatorTests: XCTestCase {
    func testCommonBasisObservationDoesNotChangeRefreshConfiguration() async {
        let suite = "CommonBasisObservation.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let coordinator = AppRuntimeObservationCoordinator()
        var changes = 0
        var refreshChanges = 0
        let changed = expectation(description: "basis changed")
        coordinator.bind(
            settings: settings,
            onRefreshConfigurationChanged: { _ in refreshChanges += 1 },
            onUpdateConfigurationChanged: {}, onMenuBarDisplayChanged: {},
            onProviderSelectionChanged: { _ in }, onClaudeCredentialContextChanged: {},
            onUsageDisplayModeChanged: {
                changes += 1; changed.fulfill()
            })
        settings.usageDisplayMode = .used
        await fulfillment(of: [changed], timeout: 1)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(refreshChanges, 0)
        coordinator.cancelAll()
    }

    func testPinPreferenceChangesApplyBehaviorWithoutRefreshingAndStopAfterCancel() async throws {
        let suite = "PopoverPinObservation.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let coordinator = AppRuntimeObservationCoordinator()
        defer { coordinator.cancelAll() }
        var states: [Bool] = []
        var refreshChanges = 0
        var credentialChanges = 0
        let pinned = expectation(description: "pinned")
        let unpinned = expectation(description: "unpinned")
        let afterCancel = expectation(description: "no behavior callback after cancel")
        afterCancel.isInverted = true
        coordinator.bind(
            settings: settings,
            onRefreshConfigurationChanged: { _ in refreshChanges += 1 },
            onUpdateConfigurationChanged: {}, onMenuBarDisplayChanged: {},
            onProviderSelectionChanged: { _ in },
            onClaudeCredentialContextChanged: { credentialChanges += 1 },
            onPopoverBehaviorChanged: {
                states.append(settings.popoverPinned)
                switch states.count {
                case 1: pinned.fulfill()
                case 2: unpinned.fulfill()
                default: afterCancel.fulfill()
                }
            })
        settings.popoverPinned = true
        await fulfillment(of: [pinned], timeout: 1)
        settings.popoverPinned = false
        await fulfillment(of: [unpinned], timeout: 1)
        XCTAssertEqual(states, [true, false])
        XCTAssertEqual(refreshChanges, 0)
        XCTAssertEqual(credentialChanges, 0)
        coordinator.cancelAll()
        settings.popoverPinned = true
        await fulfillment(of: [afterCancel], timeout: 0.05)
        XCTAssertEqual(states, [true, false])
    }

    func testAccountAndSessionNotificationsCoalesceIntoOneCredentialTransaction() async {
        let coordinator = AppRuntimeObservationCoordinator()
        var transactionCount = 0
        let transaction = expectation(description: "one credential transaction")
        transaction.expectedFulfillmentCount = 1
        coordinator.bind(
            onRefreshConfigurationChanged: { _ in },
            onUpdateConfigurationChanged: {},
            onMenuBarDisplayChanged: {},
            onProviderSelectionChanged: { _ in },
            onClaudeCredentialContextChanged: {
                transactionCount += 1
                transaction.fulfill()
            }
        )

        NotificationCenter.default.post(name: .claudeAccountDidChange, object: nil)
        NotificationCenter.default.post(name: .claudeSessionKeyDidChange, object: nil)
        NotificationCenter.default.post(name: .claudeCredentialRefreshRequested, object: nil)

        await fulfillment(of: [transaction], timeout: 1.0)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(transactionCount, 1)
    }

    func testExplicitCredentialRefreshRequestStartsOneTransaction() async {
        let coordinator = AppRuntimeObservationCoordinator()
        var transactionCount = 0
        let transaction = expectation(description: "explicit credential refresh")
        coordinator.bind(
            onRefreshConfigurationChanged: { _ in },
            onUpdateConfigurationChanged: {},
            onMenuBarDisplayChanged: {},
            onProviderSelectionChanged: { _ in },
            onClaudeCredentialContextChanged: {
                transactionCount += 1
                transaction.fulfill()
            }
        )

        NotificationCenter.default.post(name: .claudeCredentialRefreshRequested, object: nil)

        await fulfillment(of: [transaction], timeout: 1.0)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(transactionCount, 1)
    }

    func testAccountMetadataNotificationDoesNotStartCredentialTransaction() async {
        let coordinator = AppRuntimeObservationCoordinator()
        let unwanted = expectation(description: "metadata-only change")
        unwanted.isInverted = true
        coordinator.bind(
            onRefreshConfigurationChanged: { _ in },
            onUpdateConfigurationChanged: {},
            onMenuBarDisplayChanged: {},
            onProviderSelectionChanged: { _ in },
            onClaudeCredentialContextChanged: { unwanted.fulfill() }
        )

        NotificationCenter.default.post(name: .claudeAccountsDidChange, object: nil)

        await fulfillment(of: [unwanted], timeout: 0.15)
    }

    func testInactiveAccountCredentialNotificationDoesNotStartTransaction() async {
        let coordinator = AppRuntimeObservationCoordinator()
        let unwanted = expectation(description: "inactive credential change")
        unwanted.isInverted = true
        coordinator.bind(
            onRefreshConfigurationChanged: { _ in },
            onUpdateConfigurationChanged: {},
            onMenuBarDisplayChanged: {},
            onProviderSelectionChanged: { _ in },
            onClaudeCredentialContextChanged: { unwanted.fulfill() }
        )

        NotificationCenter.default.post(
            name: .claudeSessionKeyDidChange,
            object: "test-inactive-account"
        )

        await fulfillment(of: [unwanted], timeout: 0.15)
    }
}
