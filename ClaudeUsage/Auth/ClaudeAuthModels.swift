import Foundation

enum ClaudeAuthSourceKind: String, Codable, CaseIterable, Sendable {
    case oauth
    case sessionKey
    case browserCookie

    nonisolated var displayName: String {
        switch self {
        case .oauth:
            return "OAuth"
        case .sessionKey:
            return "Session Key"
        case .browserCookie:
            return "Browser Cookie"
        }
    }
}

struct ClaudeAuthSourceDescriptor: Codable, Sendable, Equatable {
    let kind: ClaudeAuthSourceKind
    let isPrimary: Bool
    let isVisible: Bool

    nonisolated init(kind: ClaudeAuthSourceKind, isPrimary: Bool, isVisible: Bool = true) {
        self.kind = kind
        self.isPrimary = isPrimary
        self.isVisible = isVisible
    }
}

enum ClaudeBrowserFamily: String, Codable, CaseIterable, Sendable {
    case chrome
}

struct ClaudeBrowserSessionCandidate: Codable, Sendable, Equatable {
    let family: ClaudeBrowserFamily
    let profileName: String
    let profileDisplayName: String?
    let accountEmail: String?
    let cookiesPath: URL
    let localStatePath: URL?
    let supportsAutomaticImport: Bool

    nonisolated init(
        family: ClaudeBrowserFamily,
        profileName: String,
        profileDisplayName: String? = nil,
        accountEmail: String? = nil,
        cookiesPath: URL,
        localStatePath: URL? = nil,
        supportsAutomaticImport: Bool)
    {
        self.family = family
        self.profileName = profileName
        self.profileDisplayName = profileDisplayName?.trimmedNilIfEmpty
        self.accountEmail = accountEmail?.trimmedNilIfEmpty
        self.cookiesPath = cookiesPath
        self.localStatePath = localStatePath
        self.supportsAutomaticImport = supportsAutomaticImport
    }

    nonisolated var readableProfileName: String {
        ClaudeChromeProfileLabelFormatter.readableProfileName(
            profileName: profileName,
            profileDisplayName: profileDisplayName
        )
    }

    nonisolated var sourceDetail: String {
        ClaudeChromeProfileLabelFormatter.sourceDetail(
            profileName: profileName,
            profileDisplayName: profileDisplayName,
            accountEmail: accountEmail
        )
    }
}

enum ClaudeBrowserImportOutcome: Sendable, Equatable {
    case importedSession(ClaudeBrowserImportedSession)
    case importedSessionCandidates([ClaudeBrowserImportedSession])
    case manualSessionKeyRequired(message: String)
    case unavailable(message: String)
}

struct ClaudeBrowserImportedSession: Sendable, Equatable, Identifiable {
    let id: String
    let profileName: String
    let profileDisplayName: String?
    let accountEmail: String?
    let sessionKey: String

    nonisolated init(
        profileName: String,
        profileDisplayName: String? = nil,
        accountEmail: String? = nil,
        sessionKey: String
    ) {
        self.profileName = profileName
        self.profileDisplayName = profileDisplayName?.trimmedNilIfEmpty
        self.accountEmail = accountEmail?.trimmedNilIfEmpty
        self.sessionKey = sessionKey
        self.id = "\(profileName)-\(ClaudeAccountStore.fingerprint(for: sessionKey).prefix(12))"
    }

    nonisolated var readableProfileName: String {
        ClaudeChromeProfileLabelFormatter.readableProfileName(
            profileName: profileName,
            profileDisplayName: profileDisplayName
        )
    }

    nonisolated var displayName: String {
        "Chrome \(readableProfileName)"
    }

    nonisolated var sourceDetail: String {
        ClaudeChromeProfileLabelFormatter.sourceDetail(
            profileName: profileName,
            profileDisplayName: profileDisplayName,
            accountEmail: accountEmail
        )
    }
}

private enum ClaudeChromeProfileLabelFormatter {
    static nonisolated func readableProfileName(profileName: String, profileDisplayName: String?) -> String {
        if let profileDisplayName, !profileDisplayName.isEmpty {
            return profileDisplayName
        }

        if profileName == "Default" {
            return "기본 프로필"
        }

        let prefix = "Profile "
        if profileName.hasPrefix(prefix) {
            let suffix = profileName.dropFirst(prefix.count)
            if !suffix.isEmpty {
                return "프로필 \(suffix)"
            }
        }

        return profileName
    }

    static nonisolated func sourceDetail(
        profileName: String,
        profileDisplayName: String?,
        accountEmail: String?
    ) -> String {
        var detail = "\(readableProfileName(profileName: profileName, profileDisplayName: profileDisplayName)) (\(profileName))"
        if let accountEmail, !accountEmail.isEmpty {
            detail += " · \(accountEmail)"
        }
        return detail
    }
}

private extension String {
    nonisolated var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
