import CryptoKit
import Foundation

nonisolated enum AntigravityQuotaSummaryDecoderError: Error, Equatable {
    case invalidJSON
    case missingQuotaGroups
    case noIdentifiableQuotaLanes
}

nonisolated enum AntigravityQuotaSummaryDecoder {
    private typealias JSONObject = [String: Any]

    static func decode(_ data: Data) throws -> AntigravityDecodedQuotaSummary {
        let rootValue: Any
        do {
            rootValue = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AntigravityQuotaSummaryDecoderError.invalidJSON
        }

        guard let root = rootValue as? JSONObject,
              let payload = quotaPayload(in: root),
              let rawGroups = payload["groups"] as? [Any]
        else {
            throw AntigravityQuotaSummaryDecoderError.missingQuotaGroups
        }
        guard !rawGroups.isEmpty else {
            throw AntigravityQuotaSummaryDecoderError.noIdentifiableQuotaLanes
        }

        var candidates: [LaneCandidate] = []
        var issues: [AntigravityQuotaDecodeIssue] = []
        var ordinal = 0

        for rawGroup in rawGroups {
            guard let group = rawGroup as? JSONObject else {
                issues.append(issue(.invalidGroupShape))
                continue
            }

            let groupID = firstNonEmptyString(in: group, keys: ["groupId", "groupID", "id"])
            let groupLabel = firstNonEmptyString(in: group, keys: ["displayName", "name", "label"])
            guard let bucketsValue = group["buckets"], !(bucketsValue is NSNull) else {
                issues.append(issue(
                    .missingBuckets,
                    groupID: groupID,
                    groupLabel: groupLabel
                ))
                continue
            }
            guard let rawBuckets = bucketsValue as? [Any] else {
                issues.append(issue(
                    .invalidBucketsShape,
                    groupID: groupID,
                    groupLabel: groupLabel
                ))
                continue
            }

            for rawBucket in rawBuckets {
                guard let bucket = rawBucket as? JSONObject else {
                    issues.append(issue(
                        .invalidBucketShape,
                        groupID: groupID,
                        groupLabel: groupLabel
                    ))
                    continue
                }

                guard let bucketID = firstNonEmptyString(in: bucket, keys: ["bucketId", "bucketID", "id"]) else {
                    issues.append(issue(
                        .missingBucketID,
                        groupID: groupID,
                        groupLabel: groupLabel
                    ))
                    continue
                }

                let bucketLabel = firstNonEmptyString(in: bucket, keys: ["displayName", "name", "label"])
                let scope = quotaScope(
                    groupID: groupID,
                    groupLabel: groupLabel,
                    bucketID: bucketID,
                    bucketLabel: bucketLabel
                )
                let cadenceResult = quotaCadence(
                    windowValue: bucket["window"],
                    bucketID: bucketID,
                    bucketLabel: bucketLabel
                )
                if cadenceResult.invalidWindow {
                    issues.append(issue(
                        .invalidWindow,
                        groupID: groupID,
                        groupLabel: groupLabel,
                        bucketID: bucketID
                    ))
                }

                let fractionResult = remainingFraction(in: bucket)
                let fraction: Double?
                switch fractionResult {
                case .value(let value):
                    fraction = value
                case .missing:
                    fraction = nil
                case .invalid:
                    fraction = nil
                    issues.append(issue(
                        .invalidRemainingFraction,
                        groupID: groupID,
                        groupLabel: groupLabel,
                        bucketID: bucketID
                    ))
                case .unsupportedShape:
                    fraction = nil
                    issues.append(issue(
                        .unsupportedRemainingShape,
                        groupID: groupID,
                        groupLabel: groupLabel,
                        bucketID: bucketID
                    ))
                }

                let disabledResult = disabledValue(in: bucket)
                if disabledResult.invalid {
                    issues.append(issue(
                        .invalidDisabledValue,
                        groupID: groupID,
                        groupLabel: groupLabel,
                        bucketID: bucketID
                    ))
                }
                let availability: AntigravityQuotaAvailability
                if disabledResult.invalid {
                    availability = .unknown
                } else {
                    switch disabledResult.value {
                    case true:
                        availability = .disabled
                    case false:
                        availability = .available
                    case nil:
                        availability = fraction == nil ? .unknown : .available
                    }
                }
                if fractionResult == .missing, availability != .disabled {
                    issues.append(issue(
                        .missingRemainingFraction,
                        groupID: groupID,
                        groupLabel: groupLabel,
                        bucketID: bucketID
                    ))
                }

                let resetResult = resetTime(in: bucket)
                if resetResult.invalid {
                    issues.append(issue(
                        .invalidResetTime,
                        groupID: groupID,
                        groupLabel: groupLabel,
                        bucketID: bucketID
                    ))
                }

                let proposedID = canonicalLaneID(scope: scope, cadence: cadenceResult.cadence)
                    ?? unknownLaneID(groupID: groupID, groupLabel: groupLabel, bucketID: bucketID)
                let lane = AntigravityQuotaLane(
                    id: proposedID,
                    upstreamGroupID: groupID,
                    upstreamBucketID: bucketID,
                    scope: scope,
                    cadence: cadenceResult.cadence,
                    remainingFraction: fraction,
                    resetAt: resetResult.date,
                    resetDescription: firstNonEmptyString(
                        in: bucket,
                        keys: ["resetDescription", "description"]
                    ),
                    availability: availability
                )
                candidates.append(LaneCandidate(
                    lane: lane,
                    proposedID: proposedID,
                    sourceIdentity: sourceIdentity(
                        groupID: groupID,
                        groupLabel: groupLabel,
                        bucketID: bucketID
                    ),
                    ordinal: ordinal
                ))
                ordinal += 1
            }
        }

        guard !candidates.isEmpty else {
            throw AntigravityQuotaSummaryDecoderError.noIdentifiableQuotaLanes
        }

        let resolved = resolveStableIDCollisions(candidates, issues: &issues)
        guard !resolved.isEmpty else {
            throw AntigravityQuotaSummaryDecoderError.noIdentifiableQuotaLanes
        }
        return AntigravityDecodedQuotaSummary(
            description: nonEmptyString(payload["description"]),
            lanes: resolved.sorted { $0.ordinal < $1.ordinal }.map(\.lane),
            decodeIssues: issues
        )
    }

    private static func quotaPayload(in object: JSONObject, depth: Int = 0) -> JSONObject? {
        guard depth <= 3 else { return nil }
        if object["groups"] != nil {
            return object
        }
        for key in ["response", "summary"] {
            guard let nested = object[key] as? JSONObject else { continue }
            if let payload = quotaPayload(in: nested, depth: depth + 1) {
                return payload
            }
        }
        return nil
    }

    private static func quotaScope(
        groupID: String?,
        groupLabel: String?,
        bucketID: String,
        bucketLabel: String?
    ) -> AntigravityQuotaScope {
        if groupID != nil || groupLabel != nil {
            if matchesGemini([groupID, groupLabel]) {
                return .gemini
            }
            if matchesThirdParty([groupID, groupLabel]) {
                return .thirdPartyModels
            }
            return .unknown(
                id: groupID ?? "group-\(digest(groupLabel ?? "unknown"))",
                label: groupLabel
            )
        }

        if matchesGemini([bucketID, bucketLabel]) {
            return .gemini
        }
        if matchesThirdParty([bucketID, bucketLabel]) {
            return .thirdPartyModels
        }
        return .unknown(id: "ungrouped", label: nil)
    }

    private static func matchesGemini(_ values: [String?]) -> Bool {
        normalizedTokens(in: values).contains("gemini")
    }

    private static func matchesThirdParty(_ values: [String?]) -> Bool {
        let tokens = normalizedTokens(in: values)
        return tokens.contains("3p")
            || tokens.contains("claude")
            || tokens.contains("gpt")
            || containsSequence(["third", "party"], in: tokens)
    }

    private static func quotaCadence(
        windowValue: Any?,
        bucketID: String,
        bucketLabel: String?
    ) -> CadenceResult {
        if let windowValue, !(windowValue is NSNull) {
            guard let window = nonEmptyString(windowValue) else {
                return CadenceResult(cadence: .unknown(rawValue: "invalid"), invalidWindow: true)
            }
            return CadenceResult(
                cadence: recognizedCadence(in: window) ?? .unknown(rawValue: window),
                invalidWindow: false
            )
        }

        if let cadence = recognizedCadence(in: bucketID) {
            return CadenceResult(cadence: cadence, invalidWindow: false)
        }
        if let bucketLabel, let cadence = recognizedCadence(in: bucketLabel) {
            return CadenceResult(cadence: cadence, invalidWindow: false)
        }
        return CadenceResult(
            cadence: .unknown(rawValue: bucketLabel ?? bucketID),
            invalidWindow: false
        )
    }

    private static func recognizedCadence(in value: String) -> AntigravityQuotaCadence? {
        let tokens = normalizedTokens(in: [value])
        if tokens.contains("weekly") || tokens.contains("week") || tokens.contains("7d") {
            return .weekly
        }
        if tokens.contains("5h")
            || containsSequence(["5", "hour"], in: tokens)
            || containsSequence(["five", "hour"], in: tokens)
        {
            return .fiveHour
        }
        if let sessionIndex = tokens.firstIndex(of: "session") {
            let suffix = tokens.suffix(from: tokens.index(after: sessionIndex))
            if suffix.allSatisfy({ $0 == "limit" || $0 == "quota" }) {
                return .fiveHour
            }
        }
        return nil
    }

    private static func canonicalLaneID(
        scope: AntigravityQuotaScope,
        cadence: AntigravityQuotaCadence
    ) -> AntigravityQuotaLaneID? {
        switch (scope, cadence) {
        case (.gemini, .fiveHour):
            return .geminiFiveHour
        case (.gemini, .weekly):
            return .geminiWeekly
        case (.thirdPartyModels, .fiveHour):
            return .thirdPartyFiveHour
        case (.thirdPartyModels, .weekly):
            return .thirdPartyWeekly
        default:
            return nil
        }
    }

    private static func unknownLaneID(
        groupID: String?,
        groupLabel: String?,
        bucketID: String
    ) -> AntigravityQuotaLaneID {
        let identity = sourceIdentity(
            groupID: groupID,
            groupLabel: groupLabel,
            bucketID: bucketID
        )
        return AntigravityQuotaLaneID(
            rawValue: "unknown.\(digest(identity))"
        )
    }

    private static func resolveStableIDCollisions(
        _ candidates: [LaneCandidate],
        issues: inout [AntigravityQuotaDecodeIssue]
    ) -> [LaneCandidate] {
        var deduplicated: [LaneCandidate] = []
        let candidatesBySourceIdentity = Dictionary(grouping: candidates, by: \.sourceIdentity)
        for sourceIdentity in candidatesBySourceIdentity.keys.sorted() {
            guard let identityGroup = candidatesBySourceIdentity[sourceIdentity] else { continue }
            let ordered = identityGroup.sorted(by: deterministicCandidateOrder)
            guard let winner = ordered.first else { continue }
            deduplicated.append(winner)
            for duplicate in ordered.dropFirst() {
                issues.append(issue(
                    .duplicateUpstreamIdentity,
                    groupID: duplicate.lane.upstreamGroupID,
                    bucketID: duplicate.lane.upstreamBucketID
                ))
            }
        }

        var result: [LaneCandidate] = []
        let candidatesByProposedID = Dictionary(grouping: deduplicated, by: \.proposedID)
        let proposedIDs = candidatesByProposedID.keys.sorted {
            $0.rawValue < $1.rawValue
        }
        for proposedID in proposedIDs {
            guard let idGroup = candidatesByProposedID[proposedID] else { continue }
            guard idGroup.count > 1 else {
                result.append(contentsOf: idGroup)
                continue
            }

            let ordered = idGroup.sorted { lhs, rhs in
                let lhsCanonical = canonicalBucketID(for: lhs.proposedID) == normalizedIdentifier(lhs.lane.upstreamBucketID)
                let rhsCanonical = canonicalBucketID(for: rhs.proposedID) == normalizedIdentifier(rhs.lane.upstreamBucketID)
                if lhsCanonical != rhsCanonical {
                    return lhsCanonical
                }
                return deterministicCandidateOrder(lhs, rhs)
            }
            guard let winner = ordered.first else { continue }
            result.append(winner)
            for collision in ordered.dropFirst() {
                var resolved = collision
                resolved.lane = AntigravityQuotaLane(
                    id: AntigravityQuotaLaneID(
                        rawValue: "\(collision.proposedID.rawValue).collision.\(digest(collision.sourceIdentity))"
                    ),
                    upstreamGroupID: collision.lane.upstreamGroupID,
                    upstreamBucketID: collision.lane.upstreamBucketID,
                    scope: collision.lane.scope,
                    cadence: collision.lane.cadence,
                    remainingFraction: collision.lane.remainingFraction,
                    resetAt: collision.lane.resetAt,
                    resetDescription: collision.lane.resetDescription,
                    availability: collision.lane.availability
                )
                result.append(resolved)
                issues.append(issue(
                    .stableIDCollision(canonicalID: collision.proposedID),
                    groupID: collision.lane.upstreamGroupID,
                    bucketID: collision.lane.upstreamBucketID
                ))
            }
        }
        return result
    }

    private static func deterministicCandidateOrder(_ lhs: LaneCandidate, _ rhs: LaneCandidate) -> Bool {
        if lhs.sourceIdentity != rhs.sourceIdentity {
            return lhs.sourceIdentity < rhs.sourceIdentity
        }
        return deterministicLaneSignature(lhs.lane) < deterministicLaneSignature(rhs.lane)
    }

    private static func deterministicLaneSignature(_ lane: AntigravityQuotaLane) -> String {
        let fraction = lane.remainingFraction.map { String($0) } ?? ""
        let reset = lane.resetAt.map { String($0.timeIntervalSince1970) } ?? ""
        return [
            fraction,
            reset,
            String(describing: lane.availability),
            lane.resetDescription ?? "",
        ].joined(separator: "\u{1f}")
    }

    private static func canonicalBucketID(for laneID: AntigravityQuotaLaneID) -> String? {
        switch laneID {
        case .geminiFiveHour:
            return "gemini-5h"
        case .geminiWeekly:
            return "gemini-weekly"
        case .thirdPartyFiveHour:
            return "3p-5h"
        case .thirdPartyWeekly:
            return "3p-weekly"
        default:
            return nil
        }
    }

    private static func remainingFraction(in bucket: JSONObject) -> FractionResult {
        if let direct = bucket["remainingFraction"], !(direct is NSNull) {
            return validFraction(from: direct).map(FractionResult.value) ?? .invalid
        }
        guard let remainingValue = bucket["remaining"], !(remainingValue is NSNull) else {
            return .missing
        }
        guard let remaining = remainingValue as? JSONObject else {
            return .unsupportedShape
        }
        if let nested = remaining["remainingFraction"], !(nested is NSNull) {
            return validFraction(from: nested).map(FractionResult.value) ?? .invalid
        }
        if let oneofCase = nonEmptyString(remaining["case"]) {
            guard oneofCase == "remainingFraction" else {
                return .unsupportedShape
            }
            guard let value = remaining["value"], !(value is NSNull) else {
                return .invalid
            }
            return validFraction(from: value).map(FractionResult.value) ?? .invalid
        }
        return .unsupportedShape
    }

    private static func validFraction(from value: Any) -> Double? {
        guard let number = number(from: value),
              number.isFinite,
              (0 ... 1).contains(number)
        else {
            return nil
        }
        return number
    }

    private static func disabledValue(in bucket: JSONObject) -> DisabledResult {
        guard let raw = bucket["disabled"], !(raw is NSNull) else {
            return DisabledResult(value: nil, invalid: false)
        }
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else {
            return DisabledResult(value: nil, invalid: true)
        }
        return DisabledResult(value: number.boolValue, invalid: false)
    }

    private static func resetTime(in bucket: JSONObject) -> ResetResult {
        guard let raw = bucket["resetTime"], !(raw is NSNull) else {
            return ResetResult(date: nil, invalid: false)
        }
        if let string = raw as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return ResetResult(date: nil, invalid: false)
            }
            if let date = iso8601Date(from: trimmed) ?? epochDate(from: trimmed) {
                return ResetResult(date: date, invalid: false)
            }
            return ResetResult(date: nil, invalid: true)
        }
        if let seconds = number(from: raw) {
            return ResetResult(date: dateFromEpoch(seconds), invalid: false)
        }
        return ResetResult(date: nil, invalid: true)
    }

    private static func iso8601Date(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func epochDate(from value: String) -> Date? {
        guard let number = Double(value), number.isFinite else { return nil }
        return dateFromEpoch(number)
    }

    private static func dateFromEpoch(_ value: Double) -> Date {
        let seconds = value > 10_000_000_000 ? value / 1000 : value
        return Date(timeIntervalSince1970: seconds)
    }

    private static func number(from value: Any) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        return number.doubleValue
    }

    private static func sourceIdentity(
        groupID: String?,
        groupLabel: String?,
        bucketID: String
    ) -> String {
        let groupIdentity: String
        if let groupID {
            groupIdentity = "id:\(groupID)"
        } else if let groupLabel {
            groupIdentity = "label:\(groupLabel)"
        } else {
            groupIdentity = "ungrouped"
        }
        return [groupIdentity, bucketID].joined(separator: "\u{1f}")
    }

    private static func normalizedTokens(in values: [String?]) -> [String] {
        let locale = Locale(identifier: "en_US_POSIX")
        return values
            .compactMap { $0 }
            .flatMap { value in
                value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
                    .lowercased(with: locale)
                    .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                    .map(String.init)
            }
    }

    private static func containsSequence(_ sequence: [String], in values: [String]) -> Bool {
        guard !sequence.isEmpty, sequence.count <= values.count else { return false }
        for start in 0 ... values.count - sequence.count
            where Array(values[start ..< start + sequence.count]) == sequence
        {
            return true
        }
        return false
    }

    private static func firstNonEmptyString(in object: JSONObject, keys: [String]) -> String? {
        for key in keys {
            if let value = nonEmptyString(object[key]) {
                return value
            }
        }
        return nil
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedIdentifier(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func issue(
        _ kind: AntigravityQuotaDecodeIssue.Kind,
        groupID: String? = nil,
        groupLabel: String? = nil,
        bucketID: String? = nil
    ) -> AntigravityQuotaDecodeIssue {
        AntigravityQuotaDecodeIssue(
            kind: kind,
            upstreamGroupID: groupID,
            groupLabel: groupLabel,
            upstreamBucketID: bucketID
        )
    }
}

private extension AntigravityQuotaSummaryDecoder {
    nonisolated struct LaneCandidate {
        var lane: AntigravityQuotaLane
        let proposedID: AntigravityQuotaLaneID
        let sourceIdentity: String
        let ordinal: Int
    }

    nonisolated enum FractionResult: Equatable {
        case value(Double)
        case missing
        case invalid
        case unsupportedShape
    }

    nonisolated struct DisabledResult {
        let value: Bool?
        let invalid: Bool
    }

    nonisolated struct ResetResult {
        let date: Date?
        let invalid: Bool
    }

    nonisolated struct CadenceResult {
        let cadence: AntigravityQuotaCadence
        let invalidWindow: Bool
    }
}
