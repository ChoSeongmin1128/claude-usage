import Foundation

struct AntigravityUsageWindow: Sendable, Equatable {
    let label: String
    let modelID: String
    let usedPercent: Double
    let resetAtISO: String?
}

struct AntigravityUsageResponse: Sendable, Equatable {
    let accountEmail: String?
    let accountPlan: String?
    let primaryWindow: AntigravityUsageWindow?
    let secondaryWindow: AntigravityUsageWindow?
    let tertiaryWindow: AntigravityUsageWindow?

    nonisolated var primaryPercentage: Double {
        primaryWindow?.usedPercent ?? 0
    }

    nonisolated var secondaryPercentage: Double {
        secondaryWindow?.usedPercent ?? 0
    }

    nonisolated var tertiaryPercentage: Double {
        tertiaryWindow?.usedPercent ?? 0
    }
}
