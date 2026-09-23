import Foundation

enum WelcomeServiceStatus: Equatable {
    case notVerified, checking, verified

    static func resolve(snapshot: RuntimeProviderSnapshot, antigravity: AntigravityRuntimeSnapshot) -> Self {
        if snapshot.isLoading { return .checking }
        guard snapshot.error == nil, !snapshot.hasAuthError else { return .notVerified }
        if snapshot.service == .antigravity {
            guard case .ready(let quota) = antigravity.presentationState,
                let identity = quota.identity,
                identity.stableAccountID?.isEmpty == false || identity.email?.isEmpty == false,
                quota.lanes.contains(where: { $0.remainingFraction?.isFinite == true })
            else { return .notVerified }
            return .verified
        }
        guard snapshot.hasCredential, snapshot.lastUpdated != nil else { return .notVerified }
        let values: [Double?]
        switch snapshot.displayPayload {
        case .claude(let usage): values = [usage.fiveHour.utilization, usage.sevenDay?.utilization]
        case .codex(let usage): values = [usage.sessionWindow?.utilization, usage.weeklyWindow?.utilization]
        default: return .notVerified
        }
        return values.contains { $0?.isFinite == true } ? .verified : .notVerified
    }

    static func allVerified(_ selected: [AppProviderKind], statuses: [AppProviderKind: Self]) -> Bool {
        !selected.isEmpty && selected.allSatisfy { statuses[$0] == .verified }
    }
}
