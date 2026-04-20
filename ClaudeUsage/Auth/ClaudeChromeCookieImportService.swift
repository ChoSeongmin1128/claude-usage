import Foundation

protocol ClaudeBrowserCookieImporting {
    nonisolated func discoverCandidates() -> [ClaudeBrowserSessionCandidate]
    nonisolated func attemptImport() throws -> ClaudeBrowserImportOutcome
}

final class ClaudeChromeCookieImportService: ClaudeBrowserCookieImporting, @unchecked Sendable {
    nonisolated func discoverCandidates() -> [ClaudeBrowserSessionCandidate] {
        let fileManager = FileManager.default
        let home = fileManager.realHomeDirectory
        let chromeRoot = home.appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
        guard fileManager.fileExists(atPath: chromeRoot.path) else {
            return []
        }

        let localState = chromeRoot.appendingPathComponent("Local State", isDirectory: false)
        let localStatePath = fileManager.fileExists(atPath: localState.path) ? localState : nil

        return self.discoverChromeProfileNames(in: chromeRoot, localStateURL: localStatePath).compactMap { profileName in
            let profileDirectory = chromeRoot.appendingPathComponent(profileName, isDirectory: true)
            guard let cookiesPath = self.resolveCookieDatabasePath(for: profileDirectory) else { return nil }
            return ClaudeBrowserSessionCandidate(
                family: .chrome,
                profileName: profileName,
                cookiesPath: cookiesPath,
                localStatePath: localStatePath,
                supportsAutomaticImport: true)
        }
    }

    nonisolated func attemptImport() throws -> ClaudeBrowserImportOutcome {
        guard BrowserCookieAccessGate.shouldAttemptChromeAccess() else {
            return .unavailable(message: "Chrome 쿠키 접근이 일시적으로 차단되어 있습니다.\nKeychain 프롬프트 방지를 위해 6시간 동안 자동 import를 건너뜁니다.\n고급 설정에서 수동 sessionKey를 입력해 주세요.")
        }

        let candidates = self.discoverCandidates()
        guard !candidates.isEmpty else {
            return .unavailable(message: self.manualGuidanceMessage(
                discoveredProfiles: [],
                failureDetails: ["Chrome 프로필이나 Cookies DB를 찾지 못했습니다."]))
        }

        var failureDetails: [String] = []
        for candidate in candidates {
            do {
                let records = try ClaudeChromiumCookieReader.readCookies(
                    cookiesURL: candidate.cookiesPath,
                    profileName: candidate.profileName,
                    localStateURL: candidate.localStatePath)

                if let sessionKey = Self.findSessionKey(in: records) {
                    return .importedSessionKey(sessionKey)
                }

                failureDetails.append("\(candidate.profileName): claude.ai sessionKey 쿠키를 찾지 못했습니다.")
            } catch {
                failureDetails.append("\(candidate.profileName): \(error.localizedDescription)")
            }
        }

        return .manualSessionKeyRequired(message: self.manualGuidanceMessage(
            discoveredProfiles: candidates.map(\.profileName),
            failureDetails: failureDetails))
    }

    private nonisolated func discoverChromeProfileNames(in chromeRoot: URL, localStateURL: URL?) -> [String] {
        let fileManager = FileManager.default
        let localStateProfiles = self.profileNames(fromLocalState: localStateURL)
        let contents = (try? fileManager.contentsOfDirectory(
            at: chromeRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []

        let scannedProfiles = contents.compactMap { url -> (name: String, rank: Int)? in
            let name = url.lastPathComponent
            guard self.isChromeProfileDirectory(name, at: url) else { return nil }
            if name == "Default" {
                return (name, 0)
            }

            let prefix = "Profile "
            guard name.hasPrefix(prefix),
                  let number = Int(name.dropFirst(prefix.count)),
                  number >= 1 else {
                return nil
            }

            return (name, number)
        }

        let orderedScannedProfiles = scannedProfiles
            .sorted { lhs, rhs in
                if lhs.rank == rhs.rank {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                return lhs.rank < rhs.rank
            }
            .map(\.name)

        var orderedProfiles: [String] = []
        for profile in localStateProfiles + orderedScannedProfiles where !orderedProfiles.contains(profile) {
            let profileDirectory = chromeRoot.appendingPathComponent(profile, isDirectory: true)
            guard self.resolveCookieDatabasePath(for: profileDirectory) != nil else { continue }
            orderedProfiles.append(profile)
        }
        return orderedProfiles
    }

    private nonisolated func profileNames(fromLocalState localStateURL: URL?) -> [String] {
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
        }
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
            ? "Chrome 프로필이나 Cookies DB를 찾지 못했습니다."
            : "탐지된 프로필: \(discoveredProfiles.joined(separator: ", "))"

        var sections: [String] = [
            "Chrome 자동 import에서 claude.ai sessionKey를 찾지 못했습니다.",
            profileLine,
            "확인 순서:",
            "1. Chrome에서 claude.ai에 로그인되어 있는지 확인",
            "2. 실제 사용 중인 프로필이 위 목록에 포함되는지 확인",
            "3. 계속 실패하면 고급 설정에서 수동 sessionKey를 입력"
        ]

        if !failureDetails.isEmpty {
            sections.append("실패 요약:")
            sections.append(contentsOf: failureDetails.prefix(3).map { "   - \($0)" })
        }

        sections.append("sessionKey는 공백 없는 긴 토큰 형태입니다.")
        return sections.joined(separator: "\n")
    }
}
