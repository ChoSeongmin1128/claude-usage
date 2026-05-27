import Foundation

protocol AntigravityUsageFetching: Sendable {
    func fetchUsageForRuntime() async throws -> AntigravityUsageResponse
}

extension AntigravityAPIService: AntigravityUsageFetching {
    func fetchUsageForRuntime() async throws -> AntigravityUsageResponse {
        try await fetchUsageWithRetry()
    }
}

extension AntigravityRemoteUsageService: AntigravityUsageFetching {
    func fetchUsageForRuntime() async throws -> AntigravityUsageResponse {
        try await fetchUsageWithRetry()
    }
}

nonisolated enum AntigravityUsageResultQuality: Int, Sendable, Equatable, Comparable {
    case unavailable
    case identityOnly
    case numericQuota

    static func < (lhs: AntigravityUsageResultQuality, rhs: AntigravityUsageResultQuality) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    static func evaluate(_ usage: AntigravityUsageResponse) -> AntigravityUsageResultQuality {
        usage.hasUsageWindows ? .numericQuota : .identityOnly
    }
}

nonisolated struct AntigravityUsageSourceAttempt: Sendable {
    enum Outcome: Sendable {
        case success(AntigravityUsageResultQuality)
        case failure(APIError)
    }

    let source: AntigravityUsageDataSource
    let outcome: Outcome
}

nonisolated enum AntigravityUsagePlanner {
    static func plannedSources(
        configuredSource: AntigravityUsageDataSource,
        lastSuccessfulUsage: AntigravityUsageResponse?
    ) -> [AntigravityUsageDataSource] {
        switch configuredSource {
        case .localIDE, .agyCLI, .googleOAuth:
            return [configuredSource]
        case .auto:
            var sources: [AntigravityUsageDataSource] = []
            if let lastSuccessfulUsage,
               lastSuccessfulUsage.hasUsageWindows,
               lastSuccessfulUsage.source != .auto {
                append(lastSuccessfulUsage.source, to: &sources)
            }
            append(.localIDE, to: &sources)
            append(.agyCLI, to: &sources)
            append(.googleOAuth, to: &sources)
            return sources
        }
    }

    private static func append(
        _ source: AntigravityUsageDataSource,
        to sources: inout [AntigravityUsageDataSource]
    ) {
        guard !sources.contains(source) else { return }
        sources.append(source)
    }
}

enum AntigravityRuntimeRefresher {
    static func refresh(
        apiService: any AntigravityUsageFetching,
        remoteService: any AntigravityUsageFetching,
        cliService: (any AntigravityUsageFetching)? = nil,
        dataSource: AntigravityUsageDataSource,
        lastSuccessfulUsage: AntigravityUsageResponse? = nil
    ) async throws -> AntigravityUsageResponse {
        let sources = AntigravityUsagePlanner.plannedSources(
            configuredSource: dataSource,
            lastSuccessfulUsage: lastSuccessfulUsage
        )
        var identityOnlyUsage: AntigravityUsageResponse?
        var attempts: [AntigravityUsageSourceAttempt] = []

        for source in sources {
            do {
                let usage = try await fetchUsage(
                    source: source,
                    apiService: apiService,
                    remoteService: remoteService,
                    cliService: cliService
                )
                let quality = AntigravityUsageResultQuality.evaluate(usage)
                attempts.append(.init(source: source, outcome: .success(quality)))
                if quality == .numericQuota {
                    return usage
                }
                if identityOnlyUsage == nil {
                    identityOnlyUsage = usage
                }
            } catch let error as APIError {
                attempts.append(.init(source: source, outcome: .failure(error)))
            } catch {
                attempts.append(.init(source: source, outcome: .failure(.unknownError(error.localizedDescription))))
            }
        }

        if let identityOnlyUsage {
            Logger.info("[Antigravity] quota 수치 없이 계정 상태만 확인됨: \(attemptSummary(attempts))")
            return identityOnlyUsage
        }

        throw preferredFailure(from: attempts)
    }

    private static func fetchUsage(
        source: AntigravityUsageDataSource,
        apiService: any AntigravityUsageFetching,
        remoteService: any AntigravityUsageFetching,
        cliService: (any AntigravityUsageFetching)?
    ) async throws -> AntigravityUsageResponse {
        switch source {
        case .auto:
            throw APIError.invalidSessionKey
        case .localIDE:
            return try await apiService.fetchUsageForRuntime()
        case .agyCLI:
            guard let cliService else {
                throw APIError.invalidSessionKey
            }
            return try await cliService.fetchUsageForRuntime()
        case .googleOAuth:
            return try await remoteService.fetchUsageForRuntime()
        }
    }

    private static func preferredFailure(from attempts: [AntigravityUsageSourceAttempt]) -> APIError {
        let failures = attempts.compactMap { attempt -> APIError? in
            guard case .failure(let error) = attempt.outcome else { return nil }
            return error
        }
        if let nonAuthFailure = failures.last(where: { !$0.isDefinitiveAuthFailure }) {
            return nonAuthFailure
        }
        return failures.first ?? APIError.invalidSessionKey
    }

    private static func attemptSummary(_ attempts: [AntigravityUsageSourceAttempt]) -> String {
        attempts.map { attempt in
            switch attempt.outcome {
            case .success(let quality):
                return "\(attempt.source.rawValue)=\(quality)"
            case .failure(let error):
                return "\(attempt.source.rawValue)=\(error.localizedDescription)"
            }
        }
        .joined(separator: ", ")
    }
}
