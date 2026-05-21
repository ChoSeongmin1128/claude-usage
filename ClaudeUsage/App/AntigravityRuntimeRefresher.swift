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

enum AntigravityRuntimeRefresher {
    static func refresh(
        apiService: any AntigravityUsageFetching,
        remoteService: any AntigravityUsageFetching,
        dataSource: AntigravityUsageDataSource
    ) async throws -> AntigravityUsageResponse {
        switch dataSource {
        case .localIDE:
            return try await apiService.fetchUsageForRuntime()
        case .googleOAuth:
            do {
                return try await remoteService.fetchUsageForRuntime()
            } catch let remoteError {
                return try await localUsageOrThrowRemoteError(
                    remoteError,
                    apiService: apiService
                )
            }
        case .auto:
            do {
                let localUsage = try await apiService.fetchUsageForRuntime()
                guard !localUsage.hasUsageWindows else {
                    return localUsage
                }

                Logger.info("[Antigravity] local IDE 조회에 quota 정보가 없어 OAuth 원격 조회 시도")
                return try await remoteUsageOrFallback(to: localUsage, remoteService: remoteService)
            } catch let localError {
                Logger.info("[Antigravity] local IDE 조회 실패 후 OAuth 원격 조회 시도: \(localError.localizedDescription)")
                do {
                    return try await remoteService.fetchUsageForRuntime()
                } catch let remoteError as APIError {
                    if remoteError.isDefinitiveAuthFailure {
                        throw localError
                    }
                    throw remoteError
                } catch {
                    throw error
                }
            }
        }
    }

    private static func localUsageOrThrowRemoteError(
        _ remoteError: Error,
        apiService: any AntigravityUsageFetching
    ) async throws -> AntigravityUsageResponse {
        do {
            let localUsage = try await apiService.fetchUsageForRuntime()
            Logger.info("[Antigravity] OAuth 원격 조회 실패 후 local IDE 결과 사용: \(remoteError.localizedDescription)")
            return localUsage
        } catch {
            throw remoteError
        }
    }

    private static func remoteUsageOrFallback(
        to localUsage: AntigravityUsageResponse,
        remoteService: any AntigravityUsageFetching
    ) async throws -> AntigravityUsageResponse {
        do {
            return try await remoteService.fetchUsageForRuntime()
        } catch {
            Logger.info("[Antigravity] OAuth 원격 보완 조회 실패, local IDE 결과 유지: \(error.localizedDescription)")
            return localUsage
        }
    }
}
