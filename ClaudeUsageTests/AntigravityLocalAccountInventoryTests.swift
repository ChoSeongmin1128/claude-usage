import XCTest
@testable import ClaudeUsage

final class AntigravityLocalAccountInventoryTests: XCTestCase {
    func testSameAccountCombinesSourcesWithoutCreatingOAuthCredentials() {
        var inventory = AntigravityLocalAccountInventory()
        inventory.observe(.init(stableAccountID: "a", email: "A@example.com"), source: .localApp)
        inventory.observe(.init(email: "a@example.com"), source: .borrowedCLI)
        XCTAssertEqual(inventory.accounts.count, 1)
        XCTAssertEqual(inventory.uniqueVerifiedAccount?.sources, [.localApp, .borrowedCLI])
        XCTAssertEqual(inventory.uniqueVerifiedAccount?.identity.stableAccountID, "a")
    }

    func testConflictingStableIDsNeverMergeThroughSameEmail() {
        for reversed in [false, true] {
            var identities = [
                ProviderAccountIdentity(stableAccountID: "a", email: "same@example.com"),
                ProviderAccountIdentity(stableAccountID: "b", email: "same@example.com"),
                ProviderAccountIdentity(email: "same@example.com"),
            ]
            if reversed { identities.reverse() }
            var inventory = AntigravityLocalAccountInventory()
            for identity in identities { inventory.observe(identity, source: .localApp) }
            XCTAssertEqual(inventory.accounts.count, 2)
            XCTAssertNil(inventory.uniqueVerifiedAccount)
        }
    }

    func testUnknownCandidatePreventsAutomaticSelectionOfOnlyKnownAccount() {
        var inventory = AntigravityLocalAccountInventory()
        inventory.observe(.init(email: "a@example.com"), source: .localApp)
        inventory.markUnverified(.borrowedCLI)
        XCTAssertEqual(inventory.accounts.count, 1)
        XCTAssertNil(inventory.uniqueVerifiedAccount)
    }

    func testInvalidIdentityCannotBecomeSelectable() {
        var inventory = AntigravityLocalAccountInventory()
        inventory.observe(.init(stableAccountID: " ", email: ""), source: .managedCLI)
        XCTAssertTrue(inventory.accounts.isEmpty)
        XCTAssertEqual(inventory.unverifiedSources, [.managedCLI])
    }
}
