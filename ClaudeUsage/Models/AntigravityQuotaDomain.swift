import Foundation

nonisolated struct ProviderAccountIdentity: Sendable, Equatable, Hashable, Codable {
    let stableAccountID: String?
    let email: String?

    init(stableAccountID: String? = nil, email: String? = nil) {
        self.stableAccountID = stableAccountID
        self.email = email
    }
}

nonisolated struct AntigravityQuotaLaneID:
    RawRepresentable,
    Hashable,
    Codable,
    Sendable,
    CustomStringConvertible
{
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String {
        rawValue
    }

    static let geminiFiveHour = Self(rawValue: "gemini.fiveHour")
    static let geminiWeekly = Self(rawValue: "gemini.weekly")
    static let thirdPartyFiveHour = Self(rawValue: "thirdParty.fiveHour")
    static let thirdPartyWeekly = Self(rawValue: "thirdParty.weekly")
}

nonisolated enum AntigravityQuotaScope: Sendable, Equatable, Hashable {
    case gemini
    case thirdPartyModels
    case unknown(id: String, label: String?)
}

nonisolated enum AntigravityQuotaCadence: Sendable, Equatable, Hashable {
    case fiveHour
    case weekly
    case unknown(rawValue: String)
}

nonisolated enum AntigravityQuotaAvailability: Sendable, Equatable {
    case available
    case disabled
    case unknown
}

nonisolated struct AntigravityQuotaLane: Sendable, Equatable, Identifiable {
    let id: AntigravityQuotaLaneID
    let upstreamGroupID: String?
    let upstreamBucketID: String
    let scope: AntigravityQuotaScope
    let cadence: AntigravityQuotaCadence
    let remainingFraction: Double?
    let resetAt: Date?
    let resetDescription: String?
    let availability: AntigravityQuotaAvailability
}

nonisolated struct AntigravityQuotaDecodeIssue: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case invalidGroupShape
        case missingBuckets
        case invalidBucketsShape
        case invalidBucketShape
        case missingBucketID
        case missingRemainingFraction
        case invalidRemainingFraction
        case unsupportedRemainingShape
        case invalidWindow
        case invalidDisabledValue
        case invalidResetTime
        case duplicateUpstreamIdentity
        case stableIDCollision(canonicalID: AntigravityQuotaLaneID)
    }

    let kind: Kind
    let upstreamGroupID: String?
    let groupLabel: String?
    let upstreamBucketID: String?
}

nonisolated struct AntigravityDecodedQuotaSummary: Sendable, Equatable {
    let description: String?
    let lanes: [AntigravityQuotaLane]
    let decodeIssues: [AntigravityQuotaDecodeIssue]

    var isPartial: Bool {
        !decodeIssues.isEmpty
    }
}

nonisolated struct AntigravityQuotaSnapshot: Sendable, Equatable {
    let identity: ProviderAccountIdentity?
    let plan: String?
    let lanes: [AntigravityQuotaLane]
    let decodeIssues: [AntigravityQuotaDecodeIssue]
    let provenance: AntigravityQuotaProvenance
    let fetchedAt: Date
}

nonisolated struct AntigravityQuotaProvenance: Sendable, Equatable {
    enum Transport: String, Sendable, Equatable {
        case cliUsageReport
    }

    let transport: Transport
    /// CLI 보고에는 계정 정보가 없어 지금은 항상 nil이다.
    let accountIdentity: ProviderAccountIdentity?
}
