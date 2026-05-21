import Foundation

nonisolated enum AntigravityUsageDataSource: String, Codable, CaseIterable, Sendable, Equatable, Identifiable {
    case auto
    case localIDE = "local_ide"
    case googleOAuth = "google_oauth"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto:
            return "자동"
        case .localIDE:
            return "앱 연결"
        case .googleOAuth:
            return "Google OAuth"
        }
    }

    var detail: String {
        switch self {
        case .auto:
            return "앱이 열려 있으면 로컬 API를 먼저 쓰고, 실패하거나 quota 정보가 없으면 Google OAuth로 Antigravity 원격 quota를 조회합니다."
        case .localIDE:
            return "Antigravity 앱의 로컬 language server에서 사용량을 읽습니다."
        case .googleOAuth:
            return "앱을 닫아도 Google OAuth 토큰으로 Antigravity 원격 quota를 조회합니다."
        }
    }
}

nonisolated struct AntigravityUsageWindow: Sendable, Equatable {
    let label: String
    let modelID: String
    let usedPercent: Double
    let resetAtISO: String?
}

nonisolated struct AntigravityUsageResponse: Sendable, Equatable {
    let source: AntigravityUsageDataSource
    let accountEmail: String?
    let accountPlan: String?
    let primaryWindow: AntigravityUsageWindow?
    let secondaryWindow: AntigravityUsageWindow?
    let tertiaryWindow: AntigravityUsageWindow?

    init(
        source: AntigravityUsageDataSource = .localIDE,
        accountEmail: String?,
        accountPlan: String?,
        primaryWindow: AntigravityUsageWindow?,
        secondaryWindow: AntigravityUsageWindow?,
        tertiaryWindow: AntigravityUsageWindow?
    ) {
        self.source = source
        self.accountEmail = accountEmail
        self.accountPlan = accountPlan
        self.primaryWindow = primaryWindow
        self.secondaryWindow = secondaryWindow
        self.tertiaryWindow = tertiaryWindow
    }

    nonisolated var primaryPercentage: Double {
        primaryWindow?.usedPercent ?? 0
    }

    nonisolated var secondaryPercentage: Double {
        secondaryWindow?.usedPercent ?? 0
    }

    nonisolated var tertiaryPercentage: Double {
        tertiaryWindow?.usedPercent ?? 0
    }

    nonisolated var hasUsageWindows: Bool {
        primaryWindow != nil || secondaryWindow != nil || tertiaryWindow != nil
    }
}

nonisolated struct AntigravityModelQuota: Sendable, Equatable {
    let label: String
    let modelID: String
    let remainingFraction: Double?
    let resetAtISO: String?
}

nonisolated enum AntigravityUsageMapper {
    private enum ModelFamily {
        case claude
        case geminiPro
        case geminiFlash
        case unknown
    }

    private struct NormalizedModel {
        let quota: AntigravityModelQuota
        let family: ModelFamily
        let selectionPriority: Int?
    }

    static func buildResponse(
        quotas: [AntigravityModelQuota],
        accountEmail: String?,
        accountPlan: String?,
        source: AntigravityUsageDataSource
    ) -> AntigravityUsageResponse {
        let normalized = quotas.map(normalizeModel(_:))
        let primary = representativeQuota(for: .claude, in: normalized)
            ?? fallbackQuota(in: normalized)
        let secondary = representativeQuota(for: .geminiPro, in: normalized)
        let tertiary = representativeQuota(for: .geminiFlash, in: normalized)

        return AntigravityUsageResponse(
            source: source,
            accountEmail: accountEmail,
            accountPlan: accountPlan,
            primaryWindow: primary.flatMap(window(from:)),
            secondaryWindow: secondary.flatMap(window(from:)),
            tertiaryWindow: tertiary.flatMap(window(from:))
        )
    }

    static func normalizedResetTime(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if formatter.date(from: value) != nil {
            return value
        }
        formatter.formatOptions = [.withInternetDateTime]
        if formatter.date(from: value) != nil {
            return value
        }
        guard let seconds = Double(value) else { return nil }
        return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
    }

    private static func window(from quota: AntigravityModelQuota) -> AntigravityUsageWindow? {
        guard let remainingFraction = quota.remainingFraction else { return nil }
        let remaining = max(0, min(1, remainingFraction))
        return AntigravityUsageWindow(
            label: label(for: quota),
            modelID: quota.modelID,
            usedPercent: (1 - remaining) * 100,
            resetAtISO: quota.resetAtISO
        )
    }

    private static func label(for quota: AntigravityModelQuota) -> String {
        switch family(forModelID: quota.modelID.lowercased(), label: quota.label.lowercased()) {
        case .claude:
            return "Claude"
        case .geminiPro:
            return "Gemini Pro"
        case .geminiFlash:
            return "Gemini Flash"
        case .unknown:
            return quota.label
        }
    }

    private static func normalizeModel(_ quota: AntigravityModelQuota) -> NormalizedModel {
        let modelID = quota.modelID.lowercased()
        let label = quota.label.lowercased()
        let family = family(forModelID: modelID, label: label)
        let isLite = modelID.contains("lite") || label.contains("lite")
        let isAutocomplete = modelID.contains("autocomplete")
            || label.contains("autocomplete")
            || modelID.hasPrefix("tab_")
        let isLowPriorityGeminiPro = modelID.contains("pro-low")
            || (label.contains("pro") && label.contains("low"))

        let selectionPriority: Int?
        switch family {
        case .claude:
            selectionPriority = 0
        case .geminiPro:
            if isLowPriorityGeminiPro {
                selectionPriority = 0
            } else if !isLite && !isAutocomplete {
                selectionPriority = 1
            } else {
                selectionPriority = nil
            }
        case .geminiFlash:
            selectionPriority = (!isLite && !isAutocomplete) ? 0 : nil
        case .unknown:
            selectionPriority = nil
        }

        return NormalizedModel(
            quota: quota,
            family: family,
            selectionPriority: selectionPriority
        )
    }

    private static func representativeQuota(
        for family: ModelFamily,
        in models: [NormalizedModel]
    ) -> AntigravityModelQuota? {
        let candidates = models.filter {
            $0.family == family
                && $0.selectionPriority != nil
                && $0.quota.remainingFraction != nil
        }
        guard !candidates.isEmpty else { return nil }
        return candidates.min { lhs, rhs in
            let lhsPriority = lhs.selectionPriority ?? Int.max
            let rhsPriority = rhs.selectionPriority ?? Int.max
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            let lhsRemaining = lhs.quota.remainingFraction ?? 1
            let rhsRemaining = rhs.quota.remainingFraction ?? 1
            if lhsRemaining != rhsRemaining {
                return lhsRemaining < rhsRemaining
            }
            switch (resetDate(lhs.quota.resetAtISO), resetDate(rhs.quota.resetAtISO)) {
            case let (.some(left), .some(right)) where left != right:
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return lhs.quota.label.localizedCaseInsensitiveCompare(rhs.quota.label) == .orderedAscending
            }
        }?.quota
    }

    private static func fallbackQuota(in models: [NormalizedModel]) -> AntigravityModelQuota? {
        models
            .filter { $0.quota.remainingFraction != nil }
            .min { lhs, rhs in
                let lhsRemaining = lhs.quota.remainingFraction ?? 1
                let rhsRemaining = rhs.quota.remainingFraction ?? 1
                if lhsRemaining != rhsRemaining {
                    return lhsRemaining < rhsRemaining
                }
                return lhs.quota.label.localizedCaseInsensitiveCompare(rhs.quota.label) == .orderedAscending
            }?.quota
    }

    private static func family(forModelID modelID: String, label: String) -> ModelFamily {
        let modelFamily = family(from: modelID)
        if modelFamily != .unknown {
            return modelFamily
        }
        return family(from: label)
    }

    private static func family(from text: String) -> ModelFamily {
        if text.contains("claude") {
            return .claude
        }
        if text.contains("gemini"), text.contains("pro") {
            return .geminiPro
        }
        if text.contains("gemini"), text.contains("flash") {
            return .geminiFlash
        }
        return .unknown
    }

    private static func resetDate(_ isoString: String?) -> Date? {
        guard let isoString else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: isoString) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: isoString)
    }
}
