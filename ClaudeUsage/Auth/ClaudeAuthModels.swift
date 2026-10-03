import Foundation

nonisolated enum ClaudeAuthSourceKind: String, Codable, CaseIterable, Sendable {
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

nonisolated struct ClaudeAuthSourceDescriptor: Codable, Sendable, Equatable {
    let kind: ClaudeAuthSourceKind
    let isPrimary: Bool
    let isVisible: Bool

    nonisolated init(kind: ClaudeAuthSourceKind, isPrimary: Bool, isVisible: Bool = true) {
        self.kind = kind
        self.isPrimary = isPrimary
        self.isVisible = isVisible
    }
}

/// Claude 로그인을 가져올 수 있는 브라우저와 앱. Chromium 계열의 폴더와 Keychain 이름은
/// yt-dlp `cookies.py`의 macOS 표와 이 기기의 Keychain 항목(Chrome, Claude)으로 확인했다.
/// Arc는 Safe Storage 키를 로그인 Keychain에 두지 않아 넣지 않는다.
nonisolated enum ClaudeBrowserFamily: String, Codable, CaseIterable, Sendable {
    case chrome, brave, edge, whale, vivaldi, chromium, claudeApp, firefox, safari

    enum Storage: Sendable, Equatable {
        /// 프로필 폴더가 여러 개인 Chromium 브라우저
        case chromiumProfiles(root: String)
        /// 프로필 없이 루트에 Cookies가 있는 Electron 앱
        case chromiumSingle(root: String)
        case firefox
        case safari
    }

    var displayName: String {
        switch self {
        case .chrome: return "Chrome"
        case .brave: return "Brave"
        case .edge: return "Edge"
        case .whale: return "Whale"
        case .vivaldi: return "Vivaldi"
        case .chromium: return "Chromium"
        case .claudeApp: return "Claude 앱"
        case .firefox: return "Firefox"
        case .safari: return "Safari"
        }
    }

    var bundleIdentifiers: [String] {
        switch self {
        case .chrome: return ["com.google.Chrome"]
        case .brave: return ["com.brave.Browser"]
        case .edge: return ["com.microsoft.edgemac"]
        case .whale: return ["com.naver.Whale"]
        case .vivaldi: return ["com.vivaldi.Vivaldi"]
        case .chromium: return ["org.chromium.Chromium"]
        case .claudeApp: return ["com.anthropic.claudefordesktop"]
        case .firefox: return ["org.mozilla.firefox"]
        case .safari: return ["com.apple.Safari"]
        }
    }

    var storage: Storage {
        switch self {
        case .chrome: return .chromiumProfiles(root: "Google/Chrome")
        case .brave: return .chromiumProfiles(root: "BraveSoftware/Brave-Browser")
        case .edge: return .chromiumProfiles(root: "Microsoft Edge")
        case .whale: return .chromiumProfiles(root: "Naver/Whale")
        case .vivaldi: return .chromiumProfiles(root: "Vivaldi")
        case .chromium: return .chromiumProfiles(root: "Chromium")
        case .claudeApp: return .chromiumSingle(root: "Claude")
        case .firefox: return .firefox
        case .safari: return .safari
        }
    }

    var safeStorageLabels: [ClaudeChromeSafeStorageLabel] {
        switch self {
        case .chrome:
            return [
                .init(service: "Chrome Safe Storage", account: "Chrome"),
                .init(service: "Google Chrome Safe Storage", account: "Chrome"),
            ]
        case .brave: return [.init(service: "Brave Safe Storage", account: "Brave")]
        case .edge: return [.init(service: "Microsoft Edge Safe Storage", account: "Microsoft Edge")]
        case .whale: return [.init(service: "Whale Safe Storage", account: "Whale")]
        case .vivaldi: return [.init(service: "Vivaldi Safe Storage", account: "Vivaldi")]
        case .chromium: return [.init(service: "Chromium Safe Storage", account: "Chromium")]
        case .claudeApp: return [.init(service: "Claude Safe Storage", account: "Claude Key")]
        case .firefox, .safari: return []
        }
    }

    static func family(forBundleIdentifier identifier: String) -> ClaudeBrowserFamily? {
        allCases.first { $0.bundleIdentifiers.contains(identifier) }
    }
}

nonisolated struct ClaudeBrowserSessionCandidate: Codable, Sendable, Equatable {
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
            family: family,
            profileName: profileName,
            profileDisplayName: profileDisplayName,
            accountEmail: accountEmail
        )
    }
}

nonisolated enum ClaudeBrowserImportOutcome: Sendable, Equatable {
    case importedSession(ClaudeBrowserImportedSession)
    case importedSessionCandidates([ClaudeBrowserImportedSession])
    case manualSessionKeyRequired(message: String)
    case unavailable(message: String)
    /// Safari 쿠키는 전체 디스크 접근 권한이 있어야 읽을 수 있다.
    case needsFullDiskAccess
}

nonisolated struct ClaudeBrowserImportedSession: Sendable, Equatable, Identifiable {
    let id: String
    let family: ClaudeBrowserFamily
    let profileName: String
    let profileDisplayName: String?
    let accountEmail: String?
    let sessionKey: String

    nonisolated init(
        family: ClaudeBrowserFamily = .chrome,
        profileName: String,
        profileDisplayName: String? = nil,
        accountEmail: String? = nil,
        sessionKey: String
    ) {
        self.family = family
        self.profileName = profileName
        self.profileDisplayName = profileDisplayName?.trimmedNilIfEmpty
        self.accountEmail = accountEmail?.trimmedNilIfEmpty
        self.sessionKey = sessionKey
        self.id = "\(family.rawValue)-\(profileName)-\(ClaudeAccountStore.fingerprint(for: sessionKey).prefix(12))"
    }

    nonisolated var readableProfileName: String {
        ClaudeChromeProfileLabelFormatter.readableProfileName(
            profileName: profileName,
            profileDisplayName: profileDisplayName
        )
    }

    nonisolated var displayName: String {
        family == .claudeApp ? family.displayName : "\(family.displayName) \(readableProfileName)"
    }

    nonisolated var sourceDetail: String {
        ClaudeChromeProfileLabelFormatter.sourceDetail(
            family: family,
            profileName: profileName,
            profileDisplayName: profileDisplayName,
            accountEmail: accountEmail
        )
    }
}

extension ClaudeBrowserFamily {
    /// 가져온 계정의 출처 설명에서 브라우저를 되찾는다. 2.7.x까지의 Chrome 설명에는 이름이 없다.
    nonisolated static func family(fromSourceDetail detail: String?) -> ClaudeBrowserFamily {
        guard let detail else { return .chrome }
        return allCases.first { $0 != .chrome && detail.hasPrefix($0.displayName) } ?? .chrome
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
        family: ClaudeBrowserFamily,
        profileName: String,
        profileDisplayName: String?,
        accountEmail: String?
    ) -> String {
        // Chrome은 계정 정리 규칙이 기존 설명 형식에 묶여 있어 그대로 둔다.
        let prefix = family == .chrome ? "" : "\(family.displayName) "
        var detail =
            family == .claudeApp
            ? family.displayName
            : "\(prefix)\(readableProfileName(profileName: profileName, profileDisplayName: profileDisplayName)) (\(profileName))"
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
