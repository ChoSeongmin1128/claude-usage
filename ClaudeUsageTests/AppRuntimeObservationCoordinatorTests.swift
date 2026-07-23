import XCTest
@testable import ClaudeUsage

@MainActor
final class AppRuntimeObservationCoordinatorTests: XCTestCase {
    func testAccountAndSessionNotificationsCoalesceIntoOneCredentialTransaction() async {
        let coordinator = AppRuntimeObservationCoordinator()
        var transactionCount = 0
        let transaction = expectation(description: "one credential transaction")
        transaction.expectedFulfillmentCount = 1
        coordinator.bind(
            onRefreshConfigurationChanged: {},
            onUpdateConfigurationChanged: {},
            onMenuBarDisplayChanged: {},
            onProviderSelectionChanged: { _ in },
            onPowerStateChanged: {},
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
            onRefreshConfigurationChanged: {},
            onUpdateConfigurationChanged: {},
            onMenuBarDisplayChanged: {},
            onProviderSelectionChanged: { _ in },
            onPowerStateChanged: {},
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
            onRefreshConfigurationChanged: {},
            onUpdateConfigurationChanged: {},
            onMenuBarDisplayChanged: {},
            onProviderSelectionChanged: { _ in },
            onPowerStateChanged: {},
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
            onRefreshConfigurationChanged: {},
            onUpdateConfigurationChanged: {},
            onMenuBarDisplayChanged: {},
            onProviderSelectionChanged: { _ in },
            onPowerStateChanged: {},
            onClaudeCredentialContextChanged: { unwanted.fulfill() }
        )

        NotificationCenter.default.post(
            name: .claudeSessionKeyDidChange,
            object: "test-inactive-account"
        )

        await fulfillment(of: [unwanted], timeout: 0.15)
    }
}
