import Foundation

protocol ClaudeBrowserCookieImporting {
    nonisolated func discoverCandidates() -> [ClaudeBrowserSessionCandidate]
    nonisolated func attemptImport() throws -> ClaudeBrowserImportOutcome
}

final class ClaudeChromeCookieImportService: ClaudeBrowserCookieImporting, @unchecked Sendable {
    typealias CandidateProvider = @Sendable () -> [ClaudeBrowserSessionCandidate]
    typealias DecryptionKeyProvider = @Sendable () throws -> [Data]
    typealias CookieReader = @Sendable (
        _ cookiesURL: URL,
        _ profileName: String,
        _ decryptionKeys: [Data]
    ) throws -> [ClaudeChromiumCookieRecord]

    private struct ChromeProfileDescriptor: Sendable, Equatable {
        let profileName: String
        let displayName: String?
        let accountEmail: String?
    }

    private let candidateProvider: CandidateProvider?
    private let decryptionKeyProvider: DecryptionKeyProvider
    private let cookieReader: CookieReader

    nonisolated init(
        candidateProvider: CandidateProvider? = nil,
        decryptionKeyProvider: @escaping DecryptionKeyProvider = {
            try ClaudeChromeSafeStorageKeyProvider().loadDerivedKeysForUserInitiatedImport()
        },
        cookieReader: @escaping CookieReader = { cookiesURL, profileName, decryptionKeys in
            try ClaudeChromiumCookieReader.readCookies(
                cookiesURL: cookiesURL,
                profileName: profileName,
                decryptionKeys: decryptionKeys
            )
        }
    ) {
        self.candidateProvider = candidateProvider
        self.decryptionKeyProvider = decryptionKeyProvider
        self.cookieReader = cookieReader
    }

    nonisolated func discoverCandidates() -> [ClaudeBrowserSessionCandidate] {
        if let candidateProvider {
            return candidateProvider()
        }
        let fileManager = FileManager.default
        let home = fileManager.realHomeDirectory
        let chromeRoot = home.appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
        guard fileManager.fileExists(atPath: chromeRoot.path) else {
            return []
        }

        let localState = chromeRoot.appendingPathComponent("Local State", isDirectory: false)
        let localStatePath = fileManager.fileExists(atPath: localState.path) ? localState : nil

        return self.discoverChromeProfiles(in: chromeRoot, localStateURL: localStatePath).compactMap { profile in
            let profileDirectory = chromeRoot.appendingPathComponent(profile.profileName, isDirectory: true)
            guard let cookiesPath = self.resolveCookieDatabasePath(for: profileDirectory) else { return nil }
            return ClaudeBrowserSessionCandidate(
                family: .chrome,
                profileName: profile.profileName,
                profileDisplayName: profile.displayName,
                accountEmail: profile.accountEmail,
                cookiesPath: cookiesPath,
                localStatePath: localStatePath,
                supportsAutomaticImport: true)
        }
    }

    nonisolated func attemptImport() throws -> ClaudeBrowserImportOutcome {
        let candidates = self.discoverCandidates()
        guard !candidates.isEmpty else {
            return .unavailable(message: self.manualGuidanceMessage(
                discoveredProfiles: [],
                failureDetails: ["Chrome 프로필을 찾지 못했습니다."]))
        }
        let decryptionKeys = try decryptionKeyProvider()

        var failureDetails: [String] = []
        var importedSessions: [ClaudeBrowserImportedSession] = []
        var seenFingerprints = Set<String>()
        for candidate in candidates {
            do {
                let records = try cookieReader(
                    candidate.cookiesPath,
                    candidate.profileName,
                    decryptionKeys
                )

                if let sessionKey = Self.findSessionKey(in: records) {
                    let fingerprint = ClaudeAccountStore.fingerprint(for: sessionKey)
                    if seenFingerprints.insert(fingerprint).inserted {
                        importedSessions.append(
                            ClaudeBrowserImportedSession(
                                profileName: candidate.profileName,
                                profileDisplayName: candidate.profileDisplayName,
                                accountEmail: candidate.accountEmail,
                                sessionKey: sessionKey
                            )
                        )
                    }
                    continue
                }

                failureDetails.append("\(candidate.sourceDetail): Claude 로그인 정보를 찾지 못했습니다.")
            } catch {
                failureDetails.append("\(candidate.sourceDetail): \(error.localizedDescription)")
            }
        }

        if importedSessions.count == 1, let first = importedSessions.first {
            return .importedSession(first)
        }

        if importedSessions.count > 1 {
            return .importedSessionCandidates(importedSessions)
        }

        return .manualSessionKeyRequired(message: self.manualGuidanceMessage(
            discoveredProfiles: candidates.map(\.sourceDetail),
            failureDetails: failureDetails))
    }

    private nonisolated func discoverChromeProfiles(in chromeRoot: URL, localStateURL: URL?) -> [ChromeProfileDescriptor] {
        let fileManager = FileManager.default
        let localStateProfiles = self.profileDescriptors(fromLocalState: localStateURL)
        let contents = (try? fileManager.contentsOfDirectory(
            at: chromeRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []

        let scannedProfiles = contents.compactMap { url -> (descriptor: ChromeProfileDescriptor, rank: Int)? in
            let name = url.lastPathComponent
            guard self.isChromeProfileDirectory(name, at: url) else { return nil }
            let descriptor = ChromeProfileDescriptor(
                profileName: name,
                displayName: nil,
                accountEmail: nil
            )
            if name == "Default" {
                return (descriptor, 0)
            }

            let prefix = "Profile "
            guard name.hasPrefix(prefix),
                  let number = Int(name.dropFirst(prefix.count)),
                  number >= 1 else {
                return nil
            }

            return (descriptor, number)
        }

        let orderedScannedProfiles = scannedProfiles
            .sorted { lhs, rhs in
                if lhs.rank == rhs.rank {
                    return lhs.descriptor.profileName.localizedStandardCompare(rhs.descriptor.profileName) == .orderedAscending
                }
                return lhs.rank < rhs.rank
            }
            .map(\.descriptor)

        var orderedProfiles: [ChromeProfileDescriptor] = []
        for profile in localStateProfiles + orderedScannedProfiles where !orderedProfiles.contains(where: { $0.profileName == profile.profileName }) {
            let profileDirectory = chromeRoot.appendingPathComponent(profile.profileName, isDirectory: true)
            guard self.resolveCookieDatabasePath(for: profileDirectory) != nil else { continue }
            orderedProfiles.append(profile)
        }
        return orderedProfiles
    }

    private nonisolated func profileDescriptors(fromLocalState localStateURL: URL?) -> [ChromeProfileDescriptor] {
        guard let localStateURL,
              let data = try? Data(contentsOf: localStateURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let infoCache = profile["info_cache"] as? [String: Any] else {
            return []
        }

        return infoCache.keys.sorted { lhs, rhs in
            if lhs == "Default" { return true }
            if rhs == "Default" { return false }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }.map { profileName in
            let info = infoCache[profileName] as? [String: Any]
            return ChromeProfileDescriptor(
                profileName: profileName,
                displayName: self.firstNonEmptyString(in: info, keys: ["name", "shortcut_name", "gaia_name"]),
                accountEmail: self.firstNonEmptyString(in: info, keys: ["user_name", "email", "gaia_email"])
            )
        }
    }

    private nonisolated func firstNonEmptyString(in dictionary: [String: Any]?, keys: [String]) -> String? {
        guard let dictionary else { return nil }
        for key in keys {
            guard let value = dictionary[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private nonisolated func isChromeProfileDirectory(_ name: String, at url: URL) -> Bool {
        guard name == "Default" || name.hasPrefix("Profile ") else { return false }

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }

        return self.resolveCookieDatabasePath(for: url) != nil
    }

    private nonisolated func resolveCookieDatabasePath(for profileDirectory: URL) -> URL? {
        let fileManager = FileManager.default
        let networkPath = profileDirectory.appendingPathComponent("Network/Cookies", isDirectory: false)
        if fileManager.fileExists(atPath: networkPath.path) {
            return networkPath
        }

        let legacyPath = profileDirectory.appendingPathComponent("Cookies", isDirectory: false)
        if fileManager.fileExists(atPath: legacyPath.path) {
            return legacyPath
        }

        return nil
    }

    private static nonisolated func findSessionKey(in records: [ClaudeChromiumCookieRecord]) -> String? {
        let extractor = ClaudeSessionKeyExtractor()
        let relevantRecords = records.filter { Self.isClaudeHost($0.domain) }

        if let exact = relevantRecords.first(where: { Self.isSessionCookieName($0.name) }) {
            let normalized = extractor.normalizeTokenCandidate(exact.value)
            if extractor.looksReasonableSessionCookieValue(normalized) {
                return normalized
            }
        }

        if let explicitToken = relevantRecords.first(where: { extractor.extractLikelySessionKey(from: $0.value) != nil }),
           let extracted = extractor.extractLikelySessionKey(from: explicitToken.value) {
            return extracted
        }

        if let fallback = relevantRecords.first(where: { Self.isSessionCookieLikeName($0.name) }) {
            let normalized = extractor.normalizeTokenCandidate(fallback.value)
            if extractor.looksReasonableSessionCookieValue(normalized) {
                return normalized
            }
        }

        return nil
    }

    private static nonisolated func isClaudeHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("claude.ai") || normalized.contains("anthropic.com")
    }

    private static nonisolated func isSessionCookieName(_ name: String) -> Bool {
        Self.normalizedCookieName(name) == "sessionkey"
    }

    private static nonisolated func isSessionCookieLikeName(_ name: String) -> Bool {
        Self.normalizedCookieName(name).contains("session")
    }

    private static nonisolated func normalizedCookieName(_ name: String) -> String {
        let lowered = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowered.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
    }

    private nonisolated func manualGuidanceMessage(discoveredProfiles: [String], failureDetails: [String]) -> String {
        let profileLine = discoveredProfiles.isEmpty
            ? "Chrome 프로필을 찾지 못했습니다."
            : "확인한 프로필: \(discoveredProfiles.joined(separator: ", "))"

        var sections: [String] = [
            "Chrome에서 Claude 로그인 정보를 찾지 못했습니다.",
            profileLine,
            "확인 순서:",
            "1. Chrome에서 claude.ai에 로그인되어 있는지 확인",
            "2. 실제 사용 중인 프로필이 위 목록에 포함되는지 확인",
            "3. 계속 실패하면 고급 설정에서 브라우저 로그인 값을 직접 입력"
        ]

        if !failureDetails.isEmpty {
            Logger.debug("Chrome 가져오기 실패 요약: \(failureDetails.prefix(3).joined(separator: " / "))")
            sections.append("가져오기에 실패한 프로필: \(failureDetails.count)개")
        }

        return sections.joined(separator: "\n")
    }
}
