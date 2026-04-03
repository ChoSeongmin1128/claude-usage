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
        let shouldRespectBackoff = !force && (respectBackoffWithoutPayload || state.payload != nil)
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
        return .start
    }

    static func applySuccess(
        state: inout RuntimeProviderState,
        payload: RuntimeProviderPayload,
        updatedAt: Date = Date()
    ) {
        state.payload = payload
        state.error = nil
        state.isLoading = false
        state.loadingStartedAt = nil
        state.nextRefreshAllowedAt = nil
        state.lastUpdated = updatedAt
        state.hasAuthError = false
        state.consecutiveErrorCount = 0
    }

    static func applyFailure(
        state: inout RuntimeProviderState,
        error: APIError,
        minimumInterval: TimeInterval,
        clearPayloadAfterTemporaryFailures: Int? = nil,
        hideTemporaryErrorWhilePayloadAvailable: Bool = false
    ) -> RuntimeRefreshFailureResolution {
        state.isLoading = false
        state.loadingStartedAt = nil
        state.consecutiveErrorCount += 1

        let backoff = RefreshExecutionPolicy.nextBackoffDate(
            for: error,
            minimumInterval: minimumInterval,
            existingAllowedAt: state.nextRefreshAllowedAt
        )
        state.nextRefreshAllowedAt = backoff.candidate

        if error.isTemporaryFailure {
            if let clearPayloadAfterTemporaryFailures,
               state.consecutiveErrorCount >= clearPayloadAfterTemporaryFailures
            {
                state.payload = nil
            }

            state.hasAuthError = false
            if hideTemporaryErrorWhilePayloadAvailable, state.payload != nil {
                state.error = nil
            } else {
                state.error = error
            }
        } else {
            state.error = error
            state.hasAuthError = error.isDefinitiveAuthFailure
        }

        return RuntimeRefreshFailureResolution(
            nextAllowedAt: backoff.candidate,
            backoffSeconds: backoff.seconds
        )
    }

    static func clearedState(
        service: PopoverService,
        isCodexAuthenticated: Bool,
        requiresInteractiveSetup: Bool
    ) -> RuntimeProviderState {
        var clearedState = RuntimeProviderState()
        switch service {
        case .claude:
            return clearedState
        case .codex:
            if !isCodexAuthenticated {
                clearedState.error = .invalidSessionKey
                clearedState.hasAuthError = true
            }
        case .gemini, .antigravity:
            if requiresInteractiveSetup {
                clearedState.error = .invalidSessionKey
                clearedState.hasAuthError = true
            }
        }
        return clearedState
    }
}
