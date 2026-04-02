import Foundation

struct GeminiUsageWindow: Sendable, Equatable {
    let label: String
    let modelID: String
    let usedPercent: Double
    let resetAtISO: String?
}

struct GeminiUsageResponse: Sendable, Equatable {
    let accountEmail: String?
    let accountPlan: String?
    let primaryWindow: GeminiUsageWindow?
    let secondaryWindow: GeminiUsageWindow?
    let tertiaryWindow: GeminiUsageWindow?

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
