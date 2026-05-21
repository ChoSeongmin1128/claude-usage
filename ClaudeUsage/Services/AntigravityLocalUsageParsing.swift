import Foundation

nonisolated enum AntigravityLocalUsageParsing {
    static func userStatusResponse(from data: Data) throws -> AntigravityUsageResponse {
        let envelope = try JSONDecoder().decode(AntigravityLocalUserStatusEnvelope.self, from: data)
        try validateResponseCode(envelope.code)

        guard let userStatus = envelope.userStatus else {
            throw APIError.parseError
        }

        let quotas = (userStatus.cascadeModelConfigData?.clientModelConfigs ?? []).compactMap(modelQuota(from:))
        return AntigravityUsageMapper.buildResponse(
            quotas: quotas,
            accountEmail: userStatus.email.trimmedNonEmpty,
            accountPlan: userStatus.userTier?.preferredName ?? userStatus.planStatus?.planInfo?.preferredName,
            source: .localIDE
        )
    }

    static func commandModelResponse(from data: Data) throws -> AntigravityUsageResponse {
        let envelope = try JSONDecoder().decode(AntigravityLocalCommandModelConfigEnvelope.self, from: data)
        try validateResponseCode(envelope.code)

        let quotas = (envelope.clientModelConfigs ?? []).compactMap(modelQuota(from:))
        return AntigravityUsageMapper.buildResponse(
            quotas: quotas,
            accountEmail: nil,
            accountPlan: nil,
            source: .localIDE
        )
    }

    private static func validateResponseCode(_ code: AntigravityLocalResponseCode?) throws {
        if let code, !code.isOK {
            throw APIError.unknownError("Antigravity 응답 코드 \(code.rawValue)")
        }
    }

    private static func modelQuota(from config: AntigravityLocalModelConfigPayload) -> AntigravityModelQuota? {
        guard let quotaInfo = config.quotaInfo,
              let modelID = (config.modelOrAlias?.model).trimmedNonEmpty
        else { return nil }

        return AntigravityModelQuota(
            label: config.label.trimmedNonEmpty ?? modelID,
            modelID: modelID,
            remainingFraction: quotaInfo.remainingFraction,
            resetAtISO: AntigravityUsageMapper.normalizedResetTime(quotaInfo.resetTime)
        )
    }
}

nonisolated struct AntigravityLocalUserStatusEnvelope: Decodable {
    let code: AntigravityLocalResponseCode?
    let userStatus: AntigravityLocalUserStatusPayload?
}

nonisolated struct AntigravityLocalCommandModelConfigEnvelope: Decodable {
    let code: AntigravityLocalResponseCode?
    let clientModelConfigs: [AntigravityLocalModelConfigPayload]?
}

nonisolated struct AntigravityLocalUserStatusPayload: Decodable {
    let email: String?
    let userTier: AntigravityLocalUserTierPayload?
    let planStatus: AntigravityLocalPlanStatusPayload?
    let cascadeModelConfigData: AntigravityLocalCascadeModelConfigDataPayload?
}

nonisolated struct AntigravityLocalUserTierPayload: Decodable {
    let name: String?
    let displayName: String?
    let planName: String?
    let planDisplayName: String?
    let productName: String?

    var preferredName: String? {
        [
            displayName,
            name,
            planDisplayName,
            productName,
            planName,
        ]
        .compactMap { $0.trimmedNonEmpty }
        .first
    }
}

nonisolated struct AntigravityLocalPlanStatusPayload: Decodable {
    let planInfo: AntigravityLocalPlanInfoPayload?
}

nonisolated struct AntigravityLocalPlanInfoPayload: Decodable {
    let planName: String?
    let planDisplayName: String?
    let displayName: String?
    let productName: String?
    let planShortName: String?

    var preferredName: String? {
        [
            planDisplayName,
            displayName,
            productName,
            planName,
            planShortName,
        ]
        .compactMap { $0.trimmedNonEmpty }
        .first
    }
}

nonisolated struct AntigravityLocalCascadeModelConfigDataPayload: Decodable {
    let clientModelConfigs: [AntigravityLocalModelConfigPayload]?
}

nonisolated struct AntigravityLocalModelConfigPayload: Decodable {
    let label: String?
    let modelOrAlias: AntigravityLocalModelAliasPayload?
    let quotaInfo: AntigravityLocalQuotaInfoPayload?
}

nonisolated struct AntigravityLocalModelAliasPayload: Decodable {
    let model: String?
}

nonisolated struct AntigravityLocalQuotaInfoPayload: Decodable {
    let remainingFraction: Double?
    let resetTime: String?
}

nonisolated enum AntigravityLocalResponseCode: Decodable {
    case int(Int)
    case string(String)

    var isOK: Bool {
        switch self {
        case .int(let value):
            return value == 0
        case .string(let value):
            let lower = value.lowercased()
            return lower == "ok" || lower == "success" || value == "0"
        }
    }

    var rawValue: String {
        switch self {
        case .int(let value):
            return "\(value)"
        case .string(let value):
            return value
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .int(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported response code")
    }
}

private extension Optional where Wrapped == String {
    nonisolated var trimmedNonEmpty: String? {
        switch self {
        case .some(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .none:
            return nil
        }
    }
}
