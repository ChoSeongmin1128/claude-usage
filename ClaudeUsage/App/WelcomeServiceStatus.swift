import Foundation

enum WelcomeServiceStatus: Equatable {
    case notVerified, checking, verified

    static func resolve(snapshot: RuntimeProviderSnapshot, antigravity: AntigravityRuntimeSnapshot) -> Self {
        if snapshot.isLoading || (snapshot.service == .antigravity && antigravity.isLoading) {
            return .checking
        }
        guard snapshot.error == nil, !snapshot.hasAuthError else { return .notVerified }
        if snapshot.service == .antigravity {
            guard antigravity.readiness == .ready,
                antigravity.settings != nil,
                antigravity.lastSuccessfulAt != nil
            else { return .notVerified }
            let quota: AntigravityQuotaSnapshot
            switch antigravity.presentationState {
            case .ready(let current), .partial(let current, _):
                quota = current
            default:
                return .notVerified
            }
            // The validated CLI report has no account identity. A connection
            // is proven by current usable quota, as on the other providers.
            guard
                quota.lanes.contains(where: { lane in
                    guard lane.availability == .available, let remaining = lane.remainingFraction else { return false }
                    return remaining.isFinite && (0...1).contains(remaining)
                })
            else { return .notVerified }
            return .verified
        }
        guard snapshot.hasCredential, snapshot.lastUpdated != nil else { return .notVerified }
        let values: [Double?]
        switch snapshot.displayPayload {
        case .claude(let usage): values = [usage.fiveHour?.utilization, usage.sevenDay?.utilization]
        case .codex(let usage): values = [usage.sessionWindow?.utilization, usage.weeklyWindow?.utilization]
        default: return .notVerified
        }
        return values.contains { $0?.isFinite == true } ? .verified : .notVerified
    }

    static func allVerified(_ selected: [AppProviderKind], statuses: [AppProviderKind: Self]) -> Bool {
        !selected.isEmpty && selected.allSatisfy { statuses[$0] == .verified }
    }
}
