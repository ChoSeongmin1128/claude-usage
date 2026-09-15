import Foundation

/// Observed account metadata only. Runtime endpoints and authentication never enter this value.
nonisolated struct AntigravityLocalAccount: Equatable, Sendable, Identifiable {
    var identity: ProviderAccountIdentity
    var sources: Set<AntigravityUsageSourceID>

    var id: String {
        if let subject = identity.stableAccountID?.trimmingCharacters(in: .whitespacesAndNewlines), !subject.isEmpty {
            return "subject:" + subject
        }
        return "email:" + (AntigravityAccountIdentityMatcher.normalizedEmail(identity.email) ?? "")
    }

    var label: String {
        identity.email ?? "이메일 미제공 계정 (\(identity.stableAccountID?.suffix(6) ?? ""))"
    }

    var sourceLabel: String {
        var labels: [String] = []
        if sources.contains(.localApp) { labels.append("Antigravity 앱") }
        if sources.contains(.borrowedCLI) || sources.contains(.managedCLI) { labels.append("AGY CLI") }
        return labels.joined(separator: " · ")
    }
}

nonisolated struct AntigravityLocalAccountInventory: Equatable, Sendable {
    private(set) var accounts: [AntigravityLocalAccount] = []
    private(set) var unverifiedSources: Set<AntigravityUsageSourceID> = []

    var uniqueVerifiedAccount: AntigravityLocalAccount? {
        guard accounts.count == 1, unverifiedSources.isEmpty else { return nil }
        return accounts[0]
    }

    mutating func markUnverified(_ source: AntigravityUsageSourceID) {
        unverifiedSources.insert(source)
    }

    mutating func observe(_ observed: ProviderAccountIdentity, source: AntigravityUsageSourceID) {
        let subject = observed.stableAccountID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = ProviderAccountIdentity(
            stableAccountID: subject?.isEmpty == false ? subject : nil,
            email: AntigravityAccountIdentityMatcher.normalizedEmail(observed.email))
        guard source != .googleOAuth,
            AntigravityAccountIdentityMatcher.match(expected: identity, received: identity).isMatch
        else {
            markUnverified(source)
            return
        }
        let matches = accounts.indices.filter {
            AntigravityAccountIdentityMatcher.match(expected: accounts[$0].identity, received: identity).isMatch
        }
        // An email-only assertion must not bridge two conflicting stable account IDs.
        guard matches.count <= 1 else {
            markUnverified(source)
            return
        }
        if let index = matches.first {
            let existing = accounts[index].identity
            accounts[index].identity = ProviderAccountIdentity(
                stableAccountID: existing.stableAccountID ?? identity.stableAccountID,
                email: existing.email ?? identity.email)
            accounts[index].sources.insert(source)
        } else {
            accounts.append(AntigravityLocalAccount(identity: identity, sources: [source]))
        }
        accounts.sort { $0.id < $1.id }
    }
}
