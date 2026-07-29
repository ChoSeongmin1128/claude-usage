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

    func testAmbientPlanUsesManagedCLIAfterBorrowedSourcesWhenAvailable() {
        XCTAssertEqual(
            AntigravitySourcePlanner.plannedSources(
                accountTarget: .ambientLocal,
                managedLaunchEnabled: true
            ),
            [.localApp, .borrowedCLI, .managedCLI]
        )
    }

    func testAmbientPlanSkipsManagedCLIWhenExecutableIsUnavailable() {
        XCTAssertEqual(
            AntigravitySourcePlanner.plannedSources(
                accountTarget: .ambientLocal,
                managedLaunchEnabled: false
            ),
            [.localApp, .borrowedCLI]
        )
    }

    func testSelectedAccountFallsBackToOAuthAfterManagedCLI() {
        XCTAssertEqual(
            AntigravitySourcePlanner.plannedSources(
                accountTarget: .selectedOAuth(
                    AntigravityAccountID(rawValue: "selected")
                ),
                managedLaunchEnabled: true
            ),
            [
                .localApp,
                .borrowedCLI,
                .managedCLI,
                .googleOAuth,
            ]
        )
    }

    func testPartialRefreshedCredentialPreservesCanonicalFields() throws {
        let original = AntigravityOAuthCredentials(
            accessToken: "old-access",
            refreshToken: "canonical-refresh",
            expiryDate: Date(timeIntervalSince1970: 100),
            idToken: "canonical-id-token",
            email: "User@Example.com",
            projectID: "canonical-project",
            clientID: "canonical-client",
            clientSecret: "canonical-secret"
        )
        let partial = AntigravityOAuthCredentials(
            accessToken: "new-access",
            refreshToken: "  ",
            expiryDate: Date(timeIntervalSince1970: 200),
            idToken: nil,
            email: "",
            projectID: nil,
            clientID: nil,
            clientSecret: nil
        )

        let merged = try AntigravityRefreshedCredentialMerger.merge(
            original: original,
            refreshed: partial,
            expectedIdentity: ProviderAccountIdentity(
                stableAccountID: "subject",
                email: "user@example.com"
            )
        )

        XCTAssertEqual(merged.accessToken, "new-access")
        XCTAssertEqual(merged.refreshToken, "canonical-refresh")
        XCTAssertEqual(
            merged.expiryDate,
            Date(timeIntervalSince1970: 200)
        )
        XCTAssertEqual(merged.idToken, "canonical-id-token")
        XCTAssertEqual(merged.email, "User@Example.com")
        XCTAssertEqual(merged.projectID, "canonical-project")
        XCTAssertEqual(merged.clientID, "canonical-client")
        XCTAssertEqual(merged.clientSecret, "canonical-secret")
    }

    func testRefreshedCredentialRejectsAccountAndClientBoundaryChanges() {
        let original = AntigravityOAuthCredentials(
            accessToken: "old",
            refreshToken: "refresh",
            expiryDate: nil,
            email: "user@example.com",
            clientID: "client-a",
            clientSecret: "secret-a"
        )

        XCTAssertThrowsError(
            try AntigravityRefreshedCredentialMerger.merge(
                original: original,
                refreshed: AntigravityOAuthCredentials(
                    accessToken: "new",
                    refreshToken: nil,
                    expiryDate: nil,
                    email: "other@example.com"
                ),
                expectedIdentity: ProviderAccountIdentity(
                    email: "user@example.com"
                )
            )
        ) {
            XCTAssertEqual(
                $0 as? AntigravityRefreshedCredentialMergeError,
                .accountBoundaryMismatch
            )
        }

        XCTAssertThrowsError(
            try AntigravityRefreshedCredentialMerger.merge(
                original: original,
                refreshed: AntigravityOAuthCredentials(
                    accessToken: "new",
                    refreshToken: nil,
                    expiryDate: nil,
                    email: "user@example.com",
                    clientID: "client-b"
                ),
                expectedIdentity: ProviderAccountIdentity(
                    email: "user@example.com"
                )
            )
        ) {
            XCTAssertEqual(
                $0 as? AntigravityRefreshedCredentialMergeError,
                .clientBoundaryMismatch
            )
        }

        XCTAssertThrowsError(
            try AntigravityRefreshedCredentialMerger.merge(
                original: original,
                refreshed: AntigravityOAuthCredentials(
                    accessToken: "new",
                    refreshToken: nil,
                    expiryDate: nil,
                    email: "user@example.com",
                    clientID: "client-a",
                    clientSecret: "secret-b"
                ),
                expectedIdentity: ProviderAccountIdentity(
                    email: "user@example.com"
                )
            )
        ) {
            XCTAssertEqual(
                $0 as? AntigravityRefreshedCredentialMergeError,
                .clientBoundaryMismatch
            )
        }

        XCTAssertThrowsError(
            try AntigravityRefreshedCredentialMerger.merge(
                original: original,
                refreshed: AntigravityOAuthCredentials(
                    accessToken: "new",
                    refreshToken: nil,
                    expiryDate: nil,
                    idToken: makeIDToken(
                        subject: "subject-b",
                        email: "user@example.com"
                    ),
                    email: "user@example.com"
                ),
                expectedIdentity: ProviderAccountIdentity(
                    stableAccountID: "subject-a",
                    email: "user@example.com"
                )
            )
        ) {
            XCTAssertEqual(
                $0 as? AntigravityRefreshedCredentialMergeError,
                .accountBoundaryMismatch
            )
        }
    }

    func testRefreshedCredentialAllowsEmailChangeForMatchingStableSubject() throws {
        let original = AntigravityOAuthCredentials(
            accessToken: "old",
            refreshToken: "refresh",
            expiryDate: nil,
            idToken: makeIDToken(
                subject: "subject-a",
                email: "old@example.com",
                audience: "client-a"
            ),
            email: "old@example.com",
            clientID: "client-a"
        )
        let refreshed = AntigravityOAuthCredentials(
            accessToken: "new",
            refreshToken: nil,
            expiryDate: nil,
            idToken: makeIDToken(
                subject: "subject-a",
                email: "new@example.com",
                audience: "client-a"
            ),
            email: "new@example.com"
        )

        let merged = try AntigravityRefreshedCredentialMerger.merge(
            original: original,
            refreshed: refreshed,
            expectedIdentity: ProviderAccountIdentity(
                stableAccountID: "subject-a",
                email: "old@example.com"
            )
        )

        XCTAssertEqual(merged.email, "new@example.com")
        XCTAssertEqual(merged.idToken, refreshed.idToken)
    }

    func testRefreshedCredentialUsesMatchingSubjectClaimEmailOverStaleRefreshMetadata() throws {
        let original = AntigravityOAuthCredentials(
            accessToken: "old",
            refreshToken: "refresh",
            expiryDate: nil,
            idToken: makeIDToken(
                subject: "subject-a",
                email: "old@example.com",
                audience: "client-a"
            ),
            email: "old@example.com",
            clientID: "client-a"
        )
        let refreshed = AntigravityOAuthCredentials(
            accessToken: "new",
            refreshToken: nil,
            expiryDate: nil,
            idToken: makeIDToken(
                subject: "subject-a",
                email: "new@example.com",
                audience: "client-a"
            ),
            email: "old@example.com"
        )

        let merged = try AntigravityRefreshedCredentialMerger.merge(
            original: original,
            refreshed: refreshed,
            expectedIdentity: ProviderAccountIdentity(
                stableAccountID: "subject-a",
                email: "old@example.com"
            )
        )

        XCTAssertEqual(merged.email, "new@example.com")
        XCTAssertEqual(merged.idToken, refreshed.idToken)
    }

    func testRefreshedCredentialKeepsEmailBoundaryWithoutStableSubject() {
        let original = AntigravityOAuthCredentials(
            accessToken: "old",
            refreshToken: "refresh",
            expiryDate: nil,
            email: "old@example.com",
            clientID: "client-a"
        )
        let refreshed = AntigravityOAuthCredentials(
            accessToken: "new",
            refreshToken: nil,
            expiryDate: nil,
            idToken: makeIDToken(
                subject: "subject-a",
                email: "other@example.com",
                audience: "client-a"
            ),
            email: "old@example.com"
        )

        XCTAssertThrowsError(
            try AntigravityRefreshedCredentialMerger.merge(
                original: original,
                refreshed: refreshed,
                expectedIdentity: ProviderAccountIdentity(
                    email: "old@example.com"
                )
            )
        ) {
            XCTAssertEqual(
                $0 as? AntigravityRefreshedCredentialMergeError,
                .accountBoundaryMismatch
            )
        }
    }

    func testRefreshedCredentialAcceptsMultiAudienceOnlyForCanonicalAuthorizedParty() throws {
        let original = AntigravityOAuthCredentials(
            accessToken: "old",
            refreshToken: "refresh",
            expiryDate: nil,
            email: "user@example.com",
            clientID: "client-a"
        )
        let refreshed = AntigravityOAuthCredentials(
            accessToken: "new",
            refreshToken: nil,
            expiryDate: nil,
            idToken: makeIDToken(
                subject: "subject-a",
                email: "user@example.com",
                audience: ["other-client", "client-a"],
                authorizedParty: "client-a"
            )
        )

        let merged = try AntigravityRefreshedCredentialMerger.merge(
            original: original,
            refreshed: refreshed,
            expectedIdentity: ProviderAccountIdentity(
                stableAccountID: "subject-a",
                email: "user@example.com"
            )
        )

        XCTAssertEqual(merged.idToken, refreshed.idToken)
    }

    func testRefreshedCredentialRejectsUnprovenAudienceBoundaries() {
        let canonical = AntigravityOAuthCredentials(
            accessToken: "old",
            refreshToken: "refresh",
            expiryDate: nil,
            email: "user@example.com",
            clientID: "client-a"
        )
        let invalidTokens = [
            makeIDToken(
                subject: "subject-a",
                email: "user@example.com",
                audience: "other-client"
            ),
            makeIDToken(
                subject: "subject-a",
                email: "user@example.com",
                audience: ["client-a", "other-client"]
            ),
            makeIDToken(
                subject: "subject-a",
                email: "user@example.com",
                audience: ["client-a", "other-client"],
                authorizedParty: "other-client"
            ),
            makeIDToken(
                subject: "subject-a",
                email: "user@example.com",
                audience: 42
            ),
        ]

        for token in invalidTokens {
            XCTAssertThrowsError(
                try AntigravityRefreshedCredentialMerger.merge(
                    original: canonical,
                    refreshed: AntigravityOAuthCredentials(
                        accessToken: "new",
                        refreshToken: nil,
                        expiryDate: nil,
                        idToken: token
                    ),
                    expectedIdentity: ProviderAccountIdentity(
                        stableAccountID: "subject-a",
                        email: "user@example.com"
                    )
                )
            ) {
                XCTAssertEqual(
                    $0 as?
                        AntigravityRefreshedCredentialMergeError,
                    .clientBoundaryMismatch
                )
            }
        }
    }

    func testRefreshedCredentialWithoutCanonicalClientCannotCreateClientBoundary() {
        let original = AntigravityOAuthCredentials(
            accessToken: "old",
            refreshToken: "refresh",
            expiryDate: nil,
            email: "user@example.com"
        )
        let refreshResponses = [
            AntigravityOAuthCredentials(
                accessToken: "new",
                refreshToken: nil,
                expiryDate: nil,
                idToken: makeIDToken(
                    subject: "subject-a",
                    email: "user@example.com",
                    audience: "client-a"
                )
            ),
            AntigravityOAuthCredentials(
                accessToken: "new",
                refreshToken: nil,
                expiryDate: nil,
                clientID: "client-a"
            ),
        ]

        for refreshed in refreshResponses {
            XCTAssertThrowsError(
                try AntigravityRefreshedCredentialMerger.merge(
                    original: original,
                    refreshed: refreshed,
                    expectedIdentity: ProviderAccountIdentity(
                        stableAccountID: "subject-a",
                        email: "user@example.com"
                    )
                )
            ) {
                XCTAssertEqual(
                    $0 as?
                        AntigravityRefreshedCredentialMergeError,
                    .clientBoundaryMismatch
                )
            }
        }
    }
}

private func makeIDToken(
    subject: String,
    email: String,
    audience: Any = "client-a",
    authorizedParty: String? = nil
) -> String {
    var payload: [String: Any] = [
        "sub": subject,
        "email": email,
        "aud": audience,
    ]
    if let authorizedParty {
        payload["azp"] = authorizedParty
    }
    let encoded = try! JSONSerialization.data(
        withJSONObject: payload,
        options: [.sortedKeys]
    )
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "e30.\(encoded).signature"
}
