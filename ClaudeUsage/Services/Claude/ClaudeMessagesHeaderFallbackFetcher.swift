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

extension ClaudeMessagesHeaderFallbackFetcherError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .disabled:
            return "보조 사용량 복구가 꺼져 있거나 자동 호출 조건을 만족하지 않았습니다"
        case .invalidEndpoint:
            return "Messages API 엔드포인트를 만들지 못했습니다"
        case .invalidResponse:
            return "Messages API 응답을 해석하지 못했습니다"
        case .noUsageHeaders:
            return "Messages 응답에 사용량 헤더가 없어 복구할 수 없습니다"
        case .httpError(let statusCode):
            if statusCode == 401 || statusCode == 403 {
                return "Claude Code OAuth 토큰이 없거나 만료되어 복구를 실행할 수 없습니다"
            }
            return "Messages API 호출이 실패했습니다 (HTTP \(statusCode))"
        }
    }
}

struct ClaudeMessagesHeaderFallbackFetcher {
    private let baseURL = URL(string: "https://api.anthropic.com")!
    private let modelName: String
    private let anthropicVersion = "2023-06-01"
    private let userAgent = "claude-code/2.1.5"
    private let oauthBetaHeader = "oauth-2025-04-20"

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
        request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(self.oauthBetaHeader, forHTTPHeaderField: "anthropic-beta")
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
