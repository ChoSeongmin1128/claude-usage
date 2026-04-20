import Foundation
import WebKit

final class ClaudeSessionKeyExtractor: @unchecked Sendable {
    nonisolated init() {}

    nonisolated func extractSessionKey(from cookies: [HTTPCookie]) -> (value: String, matchedCookieName: String, matchedDomain: String)? {
        let authCookies = cookies.filter {
            let domain = $0.domain.lowercased()
            return domain.contains("claude.ai") || domain.contains("anthropic.com")
        }

        return self.extractSessionKey(from: authCookies.isEmpty ? cookies : authCookies, fallbackCookies: authCookies.isEmpty ? [] : cookies)
    }

    nonisolated func extractSessionKey(fromCookieHeader header: String) -> String? {
        let separators = CharacterSet(charactersIn: ";,\n")
        for rawPart in header.components(separatedBy: separators) {
            let trimmed = rawPart.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let equalsIndex = trimmed.firstIndex(of: "=") else { continue }

            let rawName = String(trimmed[..<equalsIndex])
            let rawValue = String(trimmed[trimmed.index(after: equalsIndex)...])
            let normalizedValue = self.normalizeTokenCandidate(rawValue)

            if self.isSessionLikeCookieName(rawName),
               self.looksReasonableSessionCookieValue(normalizedValue) {
                return normalizedValue
            }

            if let extracted = self.extractLikelySessionKey(from: normalizedValue) {
                return extracted
            }
        }
        return self.extractLikelySessionKey(from: header)
    }

    nonisolated func extractLikelySessionKey(from text: String) -> String? {
        if let range = text.range(of: #"sk-ant-[A-Za-z0-9\-_]+"#, options: .regularExpression) {
            return String(text[range])
        }
        if let range = text.range(of: #"sk-[A-Za-z0-9\-_]{20,}"#, options: .regularExpression) {
            return String(text[range])
        }
        return nil
    }

    nonisolated func normalizeTokenCandidate(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \n\r\t"))
        if let decoded = trimmed.removingPercentEncoding, !decoded.isEmpty {
            return decoded
        }
        return trimmed
    }

    nonisolated func looksReasonableSessionCookieValue(_ value: String) -> Bool {
        let trimmed = self.normalizeTokenCandidate(value)
        guard trimmed.count >= 16, trimmed.count <= 1024 else { return false }
        guard !trimmed.contains(where: \.isWhitespace) else { return false }
        let hasControl = trimmed.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        return !hasControl
    }

    private nonisolated func isLikelySessionKey(_ value: String) -> Bool {
        let trimmed = self.normalizeTokenCandidate(value)
        guard trimmed.count >= 20 else { return false }
        if trimmed.range(of: #"^sk-ant-[A-Za-z0-9\-_]+$"#, options: .regularExpression) != nil {
            return true
        }
        if trimmed.range(of: #"^sk-[A-Za-z0-9\-_]{20,}$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private nonisolated func extractSessionKey(from primaryCookies: [HTTPCookie], fallbackCookies: [HTTPCookie]) -> (value: String, matchedCookieName: String, matchedDomain: String)? {
        for cookie in primaryCookies {
            if self.isSessionLikeCookieName(cookie.name) {
                let normalized = self.normalizeTokenCandidate(cookie.value)
                if self.looksReasonableSessionCookieValue(normalized) {
                    return (normalized, cookie.name, cookie.domain)
                }
            }
        }

        for cookie in primaryCookies {
            let normalized = self.normalizeTokenCandidate(cookie.value)
            if self.isLikelySessionKey(normalized) {
                return (normalized, cookie.name, cookie.domain)
            }
        }

        guard !fallbackCookies.isEmpty else { return nil }

        let secondaryCookies = fallbackCookies.filter { cookie in
            !primaryCookies.contains { $0.name == cookie.name && $0.domain == cookie.domain && $0.value == cookie.value }
        }

        for cookie in secondaryCookies {
            if self.isSessionLikeCookieName(cookie.name) {
                let normalized = self.normalizeTokenCandidate(cookie.value)
                if self.looksReasonableSessionCookieValue(normalized) {
                    return (normalized, cookie.name, cookie.domain)
                }
            }
        }

        for cookie in secondaryCookies {
            let normalized = self.normalizeTokenCandidate(cookie.value)
            if self.isLikelySessionKey(normalized) {
                return (normalized, cookie.name, cookie.domain)
            }
        }

        return nil
    }

    private nonisolated func isSessionLikeCookieName(_ name: String) -> Bool {
        let normalized = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")

        return normalized == "sessionkey" || normalized.contains("session")
    }
}
