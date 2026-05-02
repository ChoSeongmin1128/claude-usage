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
    let cookiesPath: URL
    let localStatePath: URL?
    let supportsAutomaticImport: Bool

    nonisolated init(
        family: ClaudeBrowserFamily,
        profileName: String,
        cookiesPath: URL,
        localStatePath: URL? = nil,
        supportsAutomaticImport: Bool)
    {
        self.family = family
        self.profileName = profileName
        self.cookiesPath = cookiesPath
        self.localStatePath = localStatePath
        self.supportsAutomaticImport = supportsAutomaticImport
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
    let sessionKey: String

    nonisolated init(profileName: String, sessionKey: String) {
        self.profileName = profileName
        self.sessionKey = sessionKey
        self.id = "\(profileName)-\(ClaudeAccountStore.fingerprint(for: sessionKey).prefix(12))"
    }
}
