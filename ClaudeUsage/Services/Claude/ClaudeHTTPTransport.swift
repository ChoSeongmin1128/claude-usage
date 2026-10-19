import Foundation

/// claude.ai와 Anthropic API 요청 한 번. 시간 제한, 취소, 상태 코드 분류를 여기서만 정한다.
nonisolated struct ClaudeHTTPTransport: Sendable {
    let runner: ClaudeAPIService.HTTPRunner
    let timeout: TimeInterval

    func send(_ originalRequest: URLRequest) async throws -> (Data, URLResponse) {
        var request = originalRequest
        request.timeoutInterval = timeout
        do {
            try Task.checkCancellation()
            let result = try await runner(request)
            try Task.checkCancellation()
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError {
            if urlError.code == .cancelled { throw CancellationError() }
            if urlError.code == .timedOut { throw APIError.networkError("요청 시간 초과 (\(Int(timeout))초)") }
            throw APIError.networkError(urlError.localizedDescription)
        } catch {
            throw APIError.networkError(error.localizedDescription)
        }
    }

    static func classify(statusCode: Int, data: Data?, response: HTTPURLResponse?) -> APIError {
        let retryAfter = HTTPResponseClassification.retryAfterSeconds(response)
        switch statusCode {
        case 429: return .rateLimited(retryAfter: retryAfter)
        case 401: return .invalidSessionKey
        case 403:
            if HTTPResponseClassification.isCloudflareChallenge(data) {
                return .cloudflareBlocked(retryAfter: retryAfter)
            }
            if let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let error = root["error"] as? [String: Any],
                (error["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() == "invalid authorization"
            {
                return .invalidSessionKey
            }
            return .permissionDenied("")
        default: return .serverError(statusCode)
        }
    }

    /// 같은 조회 안에서 다시 시도하기 전 기다릴 시간. 제한과 확인 페이지는 서버가 알려 준 시간을 따르되 5분을 넘기지 않는다.
    static func retryDelayNanoseconds(for error: Error, attempt: Int) -> UInt64 {
        let attempt = max(1, attempt)
        let seconds: Double
        switch error as? APIError {
        case .rateLimited(let retryAfter)?:
            seconds = retryAfter.map { Double(max(5, min($0, 300))) } ?? min(60, 6 * pow(1.8, Double(attempt - 1)))
        case .cloudflareBlocked(let retryAfter)?:
            seconds = retryAfter.map { Double(max(5, min($0, 300))) } ?? min(75, 8 * pow(1.8, Double(attempt - 1)))
        default:
            seconds = pow(2.0, Double(attempt - 1))
        }
        return UInt64(seconds * 1_000_000_000)
    }
}
