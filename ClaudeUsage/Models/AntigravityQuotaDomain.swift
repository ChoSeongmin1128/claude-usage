import Foundation

nonisolated struct ProviderAccountIdentity: Sendable, Equatable {
    let stableAccountID: String?
    let email: String?

    init(stableAccountID: String? = nil, email: String? = nil) {
        self.stableAccountID = stableAccountID
        self.email = email
    }
}

nonisolated struct ProcessIdentity: Sendable, Equatable {
    let processID: Int32
    let startedAt: Date?
    let executablePath: String?

    init(processID: Int32, startedAt: Date? = nil, executablePath: String? = nil) {
        self.processID = processID
        self.startedAt = startedAt
        self.executablePath = executablePath
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
        case localAppRPC
        case borrowedAGYRPC
        case managedAGYRPC
        case googleOAuth
    }

    enum EndpointOwner: String, Sendable, Equatable {
        case external
        case borrowed
        case managed
    }

    enum Capability: String, Sendable, Equatable {
        case groupedQuotaSummary
        case limitedQuota
    }

    let transport: Transport
    let endpointOwner: EndpointOwner
    let accountIdentity: ProviderAccountIdentity?
    let capability: Capability
    let processIdentity: ProcessIdentity?
}
