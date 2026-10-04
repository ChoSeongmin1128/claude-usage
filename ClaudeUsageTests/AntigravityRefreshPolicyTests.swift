import XCTest
@testable import ClaudeUsage

final class AntigravityRefreshPolicyTests: XCTestCase {
    func testIdentityMatcherPrefersStableSubjectOverMatchingEmail() {
        let result = AntigravityAccountIdentityMatcher.match(
            expected: ProviderAccountIdentity(
                stableAccountID: "subject-a",
                email: "same@example.com"
            ),
            received: ProviderAccountIdentity(
                stableAccountID: "subject-b",
                email: "same@example.com"
            )
        )

        XCTAssertEqual(result, .mismatch)
    }

    func testIdentityMatcherAllowsEmailChangeForMatchingStableSubject() {
        let result = AntigravityAccountIdentityMatcher.match(
            expected: ProviderAccountIdentity(
                stableAccountID: "subject-a",
                email: "old@example.com"
            ),
            received: ProviderAccountIdentity(
                stableAccountID: "subject-a",
                email: "new@example.com"
            )
        )

        XCTAssertEqual(result, .matchedStableAccountID)
    }

    func testIdentityMatcherUsesTrimmedLowercasedEmailOnlyAsFallback() {
        XCTAssertEqual(
            AntigravityAccountIdentityMatcher.match(
                expected: ProviderAccountIdentity(
                    stableAccountID: nil,
                    email: "  User@Example.COM "
                ),
                received: ProviderAccountIdentity(
                    stableAccountID: nil,
                    email: "user@example.com"
                )
            ),
            .matchedNormalizedEmail
        )
    }

    func testIdentityMatcherDoesNotGuessFromMissingIdentity() {
        XCTAssertEqual(
            AntigravityAccountIdentityMatcher.match(
                expected: ProviderAccountIdentity(
                    stableAccountID: nil,
                    email: "user@example.com"
                ),
                received: nil
            ),
            .unverifiable
        )
        XCTAssertEqual(
            AntigravityAccountIdentityMatcher.match(
                expected: ProviderAccountIdentity(),
                received: ProviderAccountIdentity()
            ),
            .unverifiable
        )
    }

    func testCLITargetPlansOnlyTheUsageReport() {
        XCTAssertEqual(AntigravitySourcePlanner.plannedSources(target: .cli), [.cliReport])
    }

    func testEveryStoredTargetPlansOnlyTheCLIReport() {
        for target in AntigravityUsageTarget.allCases {
            XCTAssertEqual(AntigravitySourcePlanner.plannedSources(target: target), [.cliReport])
            let request = AntigravityRefreshRequest(
                trigger: .manual,
                connection: AntigravityConnectionSettings(
                    schemaVersion: AntigravityConnectionSettings.currentSchemaVersion, usageTarget: target))
            XCTAssertEqual(request.target, .cli)
        }
    }
}
