import Foundation

nonisolated struct AntigravityUsageSourceRequest: Sendable {
    let generation: UInt64
    let deadline: AntigravityRPCDeadline
}

nonisolated struct AntigravityUsageSourceResponse: Sendable, Equatable {
    let snapshot: AntigravityQuotaSnapshot
}

nonisolated enum AntigravityUsageSourceError:
    Error,
    Sendable,
    Equatable
{
    case deadlineExceeded
    case cancelled
    case malformedResponse
    case transportFailure
    case runtimeUnavailable(AntigravityRuntimeFailure)
    case reportFailed
}

nonisolated protocol AntigravityUsageSource: Sendable {
    var id: AntigravityUsageSourceID { get }

    func fetch(
        _ request: AntigravityUsageSourceRequest
    ) async throws -> AntigravityUsageSourceResponse
}
