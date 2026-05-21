import Foundation

nonisolated enum AntigravityRemoteUsageParsing {
    struct TokenClaims: Sendable, Equatable {
        let email: String?
        let hostedDomain: String?
    }

    static func projectBody(_ projectID: String?) -> [String: Any] {
        guard let projectID = projectID?.trimmedNonEmpty else { return [:] }
        return ["project": projectID]
    }

    static func modelQuotas(from response: AntigravityFetchAvailableModelsResponse) -> [AntigravityModelQuota] {
        let models = response.models ?? [:]
        return models.compactMap { modelID, model in
            guard let quotaInfo = model.quotaInfo else { return nil }
            let label = model.displayName?.trimmedNonEmpty
                ?? model.label?.trimmedNonEmpty
                ?? modelID
            return AntigravityModelQuota(
                label: label,
                modelID: modelID,
                remainingFraction: quotaInfo.remainingFraction,
                resetAtISO: AntigravityUsageMapper.normalizedResetTime(quotaInfo.resetTime)
            )
        }
    }

    static func quotaBuckets(from response: AntigravityRetrieveUserQuotaResponse) throws -> [AntigravityModelQuota] {
        guard let buckets = response.buckets, !buckets.isEmpty else {
            throw APIError.parseError
        }

        var modelQuotaMap: [String: (remainingFraction: Double?, resetTime: String?)] = [:]
        for bucket in buckets {
            guard let modelID = bucket.modelId?.trimmedNonEmpty else { continue }
            let next = (bucket.remainingFraction, bucket.resetTime)
            if let existing = modelQuotaMap[modelID] {
                let existingValue = existing.remainingFraction ?? Double.greatestFiniteMagnitude
                let nextValue = next.0 ?? Double.greatestFiniteMagnitude
                if nextValue < existingValue {
                    modelQuotaMap[modelID] = next
                }
            } else {
                modelQuotaMap[modelID] = next
            }
        }

        let quotas: [AntigravityModelQuota] = modelQuotaMap.keys.sorted().compactMap { modelID in
            guard let quota = modelQuotaMap[modelID] else { return nil }
            return AntigravityModelQuota(
                label: modelID,
                modelID: modelID,
                remainingFraction: quota.remainingFraction,
                resetAtISO: AntigravityUsageMapper.normalizedResetTime(quota.resetTime)
            )
        }
        guard !quotas.isEmpty else {
            throw APIError.parseError
        }
        return quotas
    }

    static func plan(
        from response: AntigravityCodeAssistResponse,
        claims: TokenClaims
    ) -> String? {
        if let planType = response.planInfo?.planType?.trimmedNonEmpty {
            return planType
        }

        switch (response.currentTier?.id?.trimmedNonEmpty, claims.hostedDomain) {
        case ("standard-tier", _):
            return "Paid"
        case ("free-tier", .some):
            return "Workspace"
        case ("free-tier", .none):
            return "Free"
        case ("legacy-tier", _):
            return "Legacy"
        default:
            return response.currentTier?.name?.trimmedNonEmpty
        }
    }

    static func onboardTier(from response: AntigravityCodeAssistResponse) -> String? {
        if let defaultTier = response.allowedTiers?
            .first(where: { $0.isDefault == true && $0.id?.trimmedNonEmpty != nil })?.id?.trimmedNonEmpty
        {
            return defaultTier
        }
        if let firstTier = response.allowedTiers?
            .first(where: { $0.id?.trimmedNonEmpty != nil })?.id?.trimmedNonEmpty
        {
            return firstTier
        }
        if let paidTier = response.paidTier?.id?.trimmedNonEmpty {
            return paidTier
        }
        return response.currentTier?.id?.trimmedNonEmpty
    }

    static func claims(from credentials: AntigravityOAuthCredentials) -> TokenClaims {
        let tokenClaims = claimsFromToken(credentials.idToken)
        return TokenClaims(
            email: tokenClaims.email ?? credentials.email?.trimmedNonEmpty,
            hostedDomain: tokenClaims.hostedDomain
        )
    }

    private static func claimsFromToken(_ idToken: String?) -> TokenClaims {
        guard let idToken else {
            return TokenClaims(email: nil, hostedDomain: nil)
        }
        let parts = idToken.components(separatedBy: ".")
        guard parts.count >= 2 else {
            return TokenClaims(email: nil, hostedDomain: nil)
        }
        var payload = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return TokenClaims(email: nil, hostedDomain: nil)
        }
        return TokenClaims(
            email: (json["email"] as? String)?.trimmedNonEmpty,
            hostedDomain: (json["hd"] as? String)?.trimmedNonEmpty
        )
    }
}

nonisolated struct AntigravityProjectReference: Decodable {
    let value: String?

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let stringValue = try? single.decode(String.self) {
            value = stringValue
            return
        }

        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        value = try keyed.decodeIfPresent(String.self, forKey: .id)
            ?? keyed.decodeIfPresent(String.self, forKey: .projectID)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case projectID = "projectId"
    }
}

nonisolated struct AntigravityCodeAssistResponse: Decodable {
    let planInfo: AntigravityCodeAssistPlanInfo?
    let currentTier: AntigravityTierInfo?
    let paidTier: AntigravityTierInfo?
    let allowedTiers: [AntigravityAllowedTier]?
    let cloudaicompanionProject: AntigravityProjectReference?

    var projectID: String? {
        cloudaicompanionProject?.value?.trimmedNonEmpty
    }
}

nonisolated struct AntigravityCodeAssistPlanInfo: Decodable {
    let planType: String?
}

nonisolated struct AntigravityTierInfo: Decodable {
    let id: String?
    let name: String?
}

nonisolated struct AntigravityAllowedTier: Decodable {
    let id: String?
    let isDefault: Bool?
}

nonisolated struct AntigravityOnboardResponse: Decodable {
    let response: AntigravityOnboardInnerResponse?

    var projectID: String? {
        response?.cloudaicompanionProject?.value?.trimmedNonEmpty
    }
}

nonisolated struct AntigravityOnboardInnerResponse: Decodable {
    let cloudaicompanionProject: AntigravityProjectReference?
}

nonisolated struct AntigravityFetchAvailableModelsResponse: Decodable {
    let models: [String: AntigravityRemoteModel]?
}

nonisolated struct AntigravityRemoteModel: Decodable {
    let displayName: String?
    let label: String?
    let quotaInfo: AntigravityRemoteQuotaInfo?
}

nonisolated struct AntigravityRemoteQuotaInfo: Decodable {
    let remainingFraction: Double?
    let resetTime: String?
}

nonisolated struct AntigravityRetrieveUserQuotaResponse: Decodable {
    let buckets: [AntigravityRetrieveUserQuotaBucket]?
}

nonisolated struct AntigravityRetrieveUserQuotaBucket: Decodable {
    let modelId: String?
    let remainingFraction: Double?
    let resetTime: String?
}

private extension String {
    nonisolated var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
