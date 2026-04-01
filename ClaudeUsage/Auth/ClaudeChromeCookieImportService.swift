import Foundation

protocol ClaudeBrowserCookieImporting {
    nonisolated func discoverCandidates() -> [ClaudeBrowserSessionCandidate]
    nonisolated func attemptImport() throws -> ClaudeBrowserImportOutcome
}

final class ClaudeChromeCookieImportService: ClaudeBrowserCookieImporting, @unchecked Sendable {
    nonisolated func discoverCandidates() -> [ClaudeBrowserSessionCandidate] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let chromeRoot = home.appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
        guard fileManager.fileExists(atPath: chromeRoot.path) else {
            return []
        }

        let localState = chromeRoot.appendingPathComponent("Local State", isDirectory: false)
        let localStatePath = fileManager.fileExists(atPath: localState.path) ? localState : nil

        return self.discoverChromeProfileNames(in: chromeRoot).compactMap { profileName in
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
        let candidates = self.discoverCandidates()
        guard !candidates.isEmpty else {
            return .unavailable(message: self.manualGuidanceMessage(
                discoveredProfiles: [],
                failureDetails: ["Chrome 프로필(Default/Profile N)을 찾지 못했습니다."]))
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

    private nonisolated func discoverChromeProfileNames(in chromeRoot: URL) -> [String] {
        let fileManager = FileManager.default
        let contents = (try? fileManager.contentsOfDirectory(
            at: chromeRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []

        let profileNames = contents.compactMap { url -> (name: String, rank: Int)? in
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

        return profileNames
            .sorted { lhs, rhs in
                if lhs.rank == rhs.rank {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                return lhs.rank < rhs.rank
            }
            .map(\.name)
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
        let profileLine: String
        if discoveredProfiles.isEmpty {
            profileLine = "Chrome 프로필(Default/Profile N)을 찾지 못했습니다."
        } else {
            profileLine = "탐지된 Chrome 프로필: \(discoveredProfiles.joined(separator: ", "))"
        }

        let manualPathLines: [String]
        if discoveredProfiles.isEmpty {
            manualPathLines = [
                "~/Library/Application Support/Google/Chrome/Default/Network/Cookies",
                "~/Library/Application Support/Google/Chrome/Profile N/Network/Cookies",
            ]
        } else {
            manualPathLines = discoveredProfiles.map { profile in
                "~/Library/Application Support/Google/Chrome/\(profile)/Network/Cookies"
            }
        }

        var sections: [String] = [
            "Chrome 자동 import는 Cookies DB를 임시 복사한 뒤 claude.ai의 sessionKey 쿠키를 추출합니다.",
            profileLine,
            "자동 import가 실패하면 아래를 확인하세요:",
            "1. Chrome에서 claude.ai에 로그인되어 있는지 확인",
            "2. 실제 사용 중인 프로필이 Default 또는 Profile N인지 확인",
            "3. 위 Cookies DB 파일이 존재하는지 확인",
            "4. Chrome DevTools > Application > Cookies > https://claude.ai에서 sessionKey 값을 수동 복사",
        ]

        sections.append(contentsOf: manualPathLines.map { "   - \($0)" })

        if !failureDetails.isEmpty {
            sections.append("실패 상세:")
            sections.append(contentsOf: failureDetails.map { "   - \($0)" })
        }

        sections.append("sessionKey 값은 공백 없는 긴 토큰 형태입니다.")
        return sections.joined(separator: "\n")
    }
}
