import Foundation

enum RuntimeRefreshSkipReason: Equatable {
    case backoff(remainingSeconds: Int, nextAllowedAt: Date)
    case alreadyInFlight
}

enum RuntimeRefreshPreparation: Equatable {
    case start
    case skip(RuntimeRefreshSkipReason)
}

struct RuntimeRefreshFailureResolution: Equatable {
    let nextAllowedAt: Date?
    let backoffSeconds: Int?
}

enum RuntimeProviderRefreshCoordinator {
    static func prepareForRefresh(
        state: inout RuntimeProviderState,
        force: Bool,
        respectBackoffWithoutPayload: Bool = true
    ) -> RuntimeRefreshPreparation {
        let shouldRespectBackoff = !force && (respectBackoffWithoutPayload || state.lastSuccessfulPayload != nil)
        if shouldRespectBackoff,
           let nextAllowedAt = state.nextRefreshAllowedAt,
           let remainingSeconds = RefreshExecutionPolicy.remainingBackoffSeconds(until: nextAllowedAt)
        {
            return .skip(.backoff(remainingSeconds: remainingSeconds, nextAllowedAt: nextAllowedAt))
        }

        switch RefreshExecutionPolicy.inFlightDecision(
            isLoading: state.isLoading,
            startedAt: state.loadingStartedAt
        ) {
        case .start:
            break
        case .recoverStale:
            state.isLoading = false
            state.loadingStartedAt = nil
        case .skip:
            return .skip(.alreadyInFlight)
        }

        state.isLoading = true
        state.loadingStartedAt = Date()
        state.lastAttemptState = .loading
        state.lastAttemptError = nil
        state.lastAttemptMetadata = nil
        return .start
    }

    static func applySuccess(
        state: inout RuntimeProviderState,
        payload: RuntimeProviderPayload,
        metadata: RuntimeProviderFetchMetadata? = nil,
        updatedAt: Date = Date()
    ) {
        state.lastSuccessfulPayload = payload
        state.lastSuccessfulAt = updatedAt
        state.lastAttemptState = .idle
        state.lastAttemptError = nil
        state.lastSuccessfulMetadata = metadata
        state.lastAttemptMetadata = metadata
        state.isLoading = false
        state.loadingStartedAt = nil
        state.nextRefreshAllowedAt = nil
        state.hasAuthError = false
    }

    static func applyFailure(
        state: inout RuntimeProviderState,
        error: APIError,
        metadata: RuntimeProviderFetchMetadata? = nil,
        minimumInterval: TimeInterval
    ) -> RuntimeRefreshFailureResolution {
        state.isLoading = false
        state.loadingStartedAt = nil
        state.lastAttemptMetadata = metadata

        if error.isTemporaryFailure {
            let backoff = RefreshExecutionPolicy.nextBackoffDate(
                for: error,
                minimumInterval: minimumInterval,
                existingAllowedAt: state.nextRefreshAllowedAt
            )
            state.lastAttemptState = .temporaryFailure
            state.lastAttemptError = error
            state.nextRefreshAllowedAt = backoff.candidate
            state.hasAuthError = false
            return RuntimeRefreshFailureResolution(
                nextAllowedAt: backoff.candidate,
                backoffSeconds: backoff.seconds
            )
        }

        state.lastAttemptError = error
        state.nextRefreshAllowedAt = nil
        if error.isDefinitiveAuthFailure {
            // 인증 실패는 재로그인 안내가 우선 — 오래된 수치를 계속 보여주면 오해를 부른다.
            state.lastSuccessfulPayload = nil
            state.lastSuccessfulAt = nil
            state.lastAttemptState = .authFailure
            state.hasAuthError = true
        } else {
            // 비인증 definitive 실패(4xx, 스키마 변경 등)는 마지막 성공 데이터를 유지한다.
            // 메뉴바/팝오버가 갑자기 빈 화면·에러 카드로 뒤집히는 것보다 stale 표시가 낫다.
            state.lastAttemptState = .definitiveFailure
            state.hasAuthError = false
        }

        return RuntimeRefreshFailureResolution(
            nextAllowedAt: nil,
            backoffSeconds: nil
        )
    }

    static func clearedState(
        service: PopoverService,
        isCodexAuthenticated: Bool,
        requiresInteractiveSetup: Bool
    ) -> RuntimeProviderState {
        let clearedState = RuntimeProviderState()
        switch service {
        case .claude:
            return clearedState
        case .codex:
            if !isCodexAuthenticated {
                return RuntimeProviderState(
                    error: .invalidSessionKey,
                    hasAuthError: true,
                    lastAttemptState: .authFailure
                )
            }
        case .antigravity:
            if requiresInteractiveSetup {
                return RuntimeProviderState(
                    error: .invalidSessionKey,
                    hasAuthError: true,
                    lastAttemptState: .authFailure
                )
            }
        }
        return clearedState
    }
}
