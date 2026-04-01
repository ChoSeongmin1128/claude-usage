import Foundation

struct ClaudeMessagesHeaderFallbackSnapshot: Equatable, Sendable {
    let sessionUsagePercent: Double
    let sessionResetAt: Date
    let weeklyUsagePercent: Double
    let weeklyResetAt: Date
}

enum ClaudeMessagesHeaderFallbackFetcherError: Error, Equatable {
    case disabled
    case invalidEndpoint
    case invalidResponse
    case noUsageHeaders
    case httpError(statusCode: Int)
}

struct ClaudeMessagesHeaderFallbackFetcher {
    private let baseURL = URL(string: "https://api.anthropic.com")!
    private let modelName: String
    private let anthropicVersion = "2023-06-01"

    nonisolated init(modelName: String = "claude-haiku-4-5-20251001") {
        self.modelName = modelName
    }

    nonisolated func shouldAttemptAutomaticFallback(
        policy: ClaudeMessagesHeaderFallbackPolicy,
        currentUsagePercent: Double?) -> Bool
    {
        policy.allowsAutomaticFallback(currentUsagePercent: currentUsagePercent)
    }

    nonisolated func makeProbeRequest(accessToken: String) throws -> URLRequest {
        guard let url = URL(string: "/v1/messages", relativeTo: self.baseURL) else {
            throw ClaudeMessagesHeaderFallbackFetcherError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "model": self.modelName,
                "max_tokens": 1,
                "messages": [
                    [
                        "role": "user",
                        "content": "hi"
                    ]
                ]
            ])
        return request
    }

    nonisolated func parseSnapshot(from response: HTTPURLResponse) throws -> ClaudeMessagesHeaderFallbackSnapshot {
        guard response.statusCode == 200 else {
            throw ClaudeMessagesHeaderFallbackFetcherError.httpError(statusCode: response.statusCode)
        }

        guard let sessionUsagePercent = Self.parseHeaderPercent(
            response,
            name: "anthropic-ratelimit-unified-5h-utilization"),
              let sessionResetAt = Self.parseHeaderDate(
                response,
                name: "anthropic-ratelimit-unified-5h-reset"),
              let weeklyUsagePercent = Self.parseHeaderPercent(
                response,
                name: "anthropic-ratelimit-unified-7d-utilization"),
              let weeklyResetAt = Self.parseHeaderDate(
                response,
                name: "anthropic-ratelimit-unified-7d-reset")
        else {
            throw ClaudeMessagesHeaderFallbackFetcherError.noUsageHeaders
        }

        return ClaudeMessagesHeaderFallbackSnapshot(
            sessionUsagePercent: sessionUsagePercent,
            sessionResetAt: sessionResetAt,
            weeklyUsagePercent: weeklyUsagePercent,
            weeklyResetAt: weeklyResetAt)
    }

    func fetchSnapshot(
        accessToken: String,
        policy: ClaudeMessagesHeaderFallbackPolicy,
        currentUsagePercent: Double?) async throws -> ClaudeMessagesHeaderFallbackSnapshot
    {
        guard policy.isEnabled else {
            throw ClaudeMessagesHeaderFallbackFetcherError.disabled
        }
        guard self.shouldAttemptAutomaticFallback(
            policy: policy,
            currentUsagePercent: currentUsagePercent) else {
            throw ClaudeMessagesHeaderFallbackFetcherError.disabled
        }

        let request = try self.makeProbeRequest(accessToken: accessToken)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeMessagesHeaderFallbackFetcherError.invalidResponse
        }
        return try self.parseSnapshot(from: httpResponse)
    }

    private nonisolated static func parseHeaderPercent(_ response: HTTPURLResponse, name: String) -> Double? {
        guard let value = response.value(forHTTPHeaderField: name) else { return nil }
        return Double(value).map { $0 * 100.0 } ?? Double(value)
    }

    private nonisolated static func parseHeaderDate(_ response: HTTPURLResponse, name: String) -> Date? {
        guard let value = response.value(forHTTPHeaderField: name) else { return nil }
        guard let timestamp = Double(value) else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }
}
