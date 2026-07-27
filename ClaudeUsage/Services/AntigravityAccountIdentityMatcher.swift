import Foundation

nonisolated enum AntigravityAccountIdentityMatch:
    Sendable,
    Equatable
{
    case matchedStableAccountID
    case matchedNormalizedEmail
    case mismatch
    case unverifiable

    var isMatch: Bool {
        switch self {
        case .matchedStableAccountID, .matchedNormalizedEmail:
            true
        case .mismatch, .unverifiable:
            false
        }
    }
}

/// Compares only externally asserted identity. Opaque repository IDs, labels,
/// migration aliases, and source order are never treated as account evidence.
nonisolated enum AntigravityAccountIdentityMatcher {
    static func match(
        expected: ProviderAccountIdentity,
        received: ProviderAccountIdentity?
    ) -> AntigravityAccountIdentityMatch {
        guard let received else {
            return .unverifiable
        }

        let expectedSubject = normalizedSubject(
            expected.stableAccountID
        )
        let receivedSubject = normalizedSubject(
            received.stableAccountID
        )
        if let expectedSubject, let receivedSubject {
            return expectedSubject == receivedSubject
                ? .matchedStableAccountID
                : .mismatch
        }

        let expectedEmail = normalizedEmail(expected.email)
        let receivedEmail = normalizedEmail(received.email)
        if let expectedEmail, let receivedEmail {
            return expectedEmail == receivedEmail
                ? .matchedNormalizedEmail
                : .mismatch
        }
        return .unverifiable
    }

    static func normalizedEmail(_ value: String?) -> String? {
        guard let trimmed = trimmed(value) else {
            return nil
        }
        return trimmed.lowercased()
    }

    private static func normalizedSubject(
        _ value: String?
    ) -> String? {
        trimmed(value)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed.isEmpty ? nil : trimmed
    }
}

nonisolated extension AntigravityExternalAccountIdentity {
    var providerAccountIdentity: ProviderAccountIdentity {
        ProviderAccountIdentity(
            stableAccountID: googleSubject,
            email: email
        )
    }
}
