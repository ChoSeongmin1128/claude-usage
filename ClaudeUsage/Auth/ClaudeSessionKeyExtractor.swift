import Foundation
import WebKit

final class ClaudeSessionKeyExtractor: @unchecked Sendable {
    func extractSessionKey(from cookies: [HTTPCookie]) -> (value: String, matchedCookieName: String, matchedDomain: String)? {
        let authCookies = cookies.filter {
            let domain = $0.domain.lowercased()
            return domain.contains("claude.ai") || domain.contains("anthropic.com")
        }

        for cookie in authCookies {
            if cookie.name.caseInsensitiveCompare("sessionKey") == .orderedSame {
                let normalized = self.normalizeTokenCandidate(cookie.value)
                if self.looksReasonableSessionCookieValue(normalized) {
                    return (normalized, cookie.name, cookie.domain)
                }
            }
        }

        for cookie in authCookies {
            let normalized = self.normalizeTokenCandidate(cookie.value)
            if self.isLikelySessionKey(normalized) {
                return (normalized, cookie.name, cookie.domain)
            }
        }

        return nil
    }

    func extractSessionKey(fromCookieHeader header: String) -> String? {
        let parts = header.split(separator: ";")
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("sessionkey=") {
                let value = String(trimmed.dropFirst("sessionKey=".count))
                let normalized = self.normalizeTokenCandidate(value)
                if self.looksReasonableSessionCookieValue(normalized) {
                    return normalized
                }
            }
        }
        return self.extractLikelySessionKey(from: header)
    }

    func extractLikelySessionKey(from text: String) -> String? {
        if let range = text.range(of: #"sk-ant-[A-Za-z0-9\-_]+"#, options: .regularExpression) {
            return String(text[range])
        }
        if let range = text.range(of: #"sk-[A-Za-z0-9\-_]{20,}"#, options: .regularExpression) {
            return String(text[range])
        }
        return nil
    }

    func normalizeTokenCandidate(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \n\r\t"))
        if let decoded = trimmed.removingPercentEncoding, !decoded.isEmpty {
            return decoded
        }
        return trimmed
    }

    func looksReasonableSessionCookieValue(_ value: String) -> Bool {
        let trimmed = self.normalizeTokenCandidate(value)
        guard trimmed.count >= 16, trimmed.count <= 1024 else { return false }
        guard !trimmed.contains(where: \.isWhitespace) else { return false }
        let hasControl = trimmed.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        return !hasControl
    }

    private func isLikelySessionKey(_ value: String) -> Bool {
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
}
