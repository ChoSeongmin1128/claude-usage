import Foundation

nonisolated enum AntigravityUsageDataSource: String, Codable, CaseIterable, Sendable, Equatable, Identifiable {
    case auto
    case localIDE = "local_ide"
    case agyCLI = "agy_cli"
    case googleOAuth = "google_oauth"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto:
            return "자동"
        case .localIDE:
            return "앱 연결"
        case .agyCLI:
            return "AGY CLI"
        case .googleOAuth:
            return "Google OAuth"
        }
    }

    var detail: String {
        switch self {
        case .auto:
            return "앱이 열려 있으면 로컬 API를 먼저 쓰고, 실패하거나 quota 정보가 없으면 AGY CLI와 Google OAuth 순서로 보완 조회합니다."
        case .localIDE:
            return "Antigravity 앱의 로컬 language server에서 사용량을 읽습니다."
        case .agyCLI:
            return "터미널의 `agy`를 PTY로 실행하고 `/usage` quota 화면을 읽습니다. CLI 로그인과 같은 계정을 사용합니다."
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

    var family: AntigravityModelFamily {
        AntigravityModelClassifier.family(forModelID: modelID, label: label)
    }
}

nonisolated enum AntigravityModelFamily: Sendable, Equatable {
    case geminiFlash
    case geminiPro
    case claude
    case gpt
    case unknown
}

nonisolated enum AntigravityModelClassifier {
    static func family(forModelID modelID: String, label: String) -> AntigravityModelFamily {
        let modelFamily = family(from: modelID.lowercased())
        if modelFamily != .unknown {
            return modelFamily
        }
        return family(from: label.lowercased())
    }

    private static func family(from text: String) -> AntigravityModelFamily {
        if text.contains("gemini"), text.contains("flash") {
            return .geminiFlash
        }
        if text.contains("gemini"), text.contains("pro") {
            return .geminiPro
        }
        if text.contains("claude") {
            return .claude
        }
        if text.contains("gpt") {
            return .gpt
        }
        return .unknown
    }

    static func isRepresentativeCandidate(_ window: AntigravityUsageWindow) -> Bool {
        let text = "\(window.modelID) \(window.label)".lowercased()
        return !text.contains("autocomplete")
            && !text.contains("lite")
            && !text.hasPrefix("tab_")
    }

    static func representativePriority(for window: AntigravityUsageWindow) -> Int {
        let text = "\(window.modelID) \(window.label)".lowercased()
        switch window.family {
        case .geminiPro:
            return text.contains("low") ? 0 : 1
        case .geminiFlash:
            if text.contains("medium") { return 0 }
            if text.contains("high") { return 1 }
            if text.contains("low") { return 2 }
            return 3
        case .claude:
            if text.contains("sonnet") { return 0 }
            if text.contains("opus") { return 1 }
            return 2
        case .gpt, .unknown:
            return 0
        }
    }
}

nonisolated struct AntigravityUsageResponse: Sendable, Equatable {
    let source: AntigravityUsageDataSource
    let accountEmail: String?
    let accountPlan: String?
    let modelWindows: [AntigravityUsageWindow]

    var primaryWindow: AntigravityUsageWindow? {
        representativeWindow(for: .geminiPro) ?? fallbackWindow
    }

    var secondaryWindow: AntigravityUsageWindow? {
        representativeWindow(for: .geminiFlash)
    }

    var tertiaryWindow: AntigravityUsageWindow? {
        representativeWindow(for: .claude)
    }

    init(
        source: AntigravityUsageDataSource = .localIDE,
        accountEmail: String?,
        accountPlan: String?,
        modelWindows: [AntigravityUsageWindow]
    ) {
        self.source = source
        self.accountEmail = accountEmail
        self.accountPlan = accountPlan
        self.modelWindows = modelWindows
    }

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
        self.modelWindows = [primaryWindow, secondaryWindow, tertiaryWindow].compactMap { $0 }
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
        !modelWindows.isEmpty
    }

    nonisolated func modelSummary(separator: String = " · ") -> String {
        modelWindows
            .map { "\($0.label) \(Int($0.usedPercent.rounded()))%" }
            .joined(separator: separator)
    }

    nonisolated func window(matchingModelID modelID: String?) -> AntigravityUsageWindow? {
        let normalizedID = modelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedID, !normalizedID.isEmpty else { return nil }
        return modelWindows.first { $0.modelID == normalizedID }
    }

    nonisolated func menuBarPrimaryWindow(preferredModelID: String?) -> AntigravityUsageWindow? {
        window(matchingModelID: preferredModelID) ?? primaryWindow
    }

    nonisolated func menuBarSecondaryWindow(
        preferredModelID: String?,
        primaryModelID: String?
    ) -> AntigravityUsageWindow? {
        if let preferred = window(matchingModelID: preferredModelID) {
            return preferred
        }
        if let secondaryWindow, secondaryWindow.modelID != primaryModelID {
            return secondaryWindow
        }
        return modelWindows.first { $0.modelID != primaryModelID }
    }

    private var fallbackWindow: AntigravityUsageWindow? {
        guard representativeWindow(for: .geminiPro) == nil,
              representativeWindow(for: .geminiFlash) == nil,
              representativeWindow(for: .claude) == nil
        else {
            return nil
        }
        return modelWindows.first
    }

    private func representativeWindow(for family: AntigravityModelFamily) -> AntigravityUsageWindow? {
        modelWindows
            .enumerated()
            .filter { _, window in
                window.family == family && AntigravityModelClassifier.isRepresentativeCandidate(window)
            }
            .min { lhs, rhs in
                let lhsWindow = lhs.element
                let rhsWindow = rhs.element
                let lhsPriority = AntigravityModelClassifier.representativePriority(for: lhsWindow)
                let rhsPriority = AntigravityModelClassifier.representativePriority(for: rhsWindow)
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }
                if lhsWindow.usedPercent != rhsWindow.usedPercent {
                    return lhsWindow.usedPercent > rhsWindow.usedPercent
                }
                return lhs.offset < rhs.offset
            }?
            .element
    }
}

nonisolated struct AntigravityModelQuota: Sendable, Equatable {
    let label: String
    let modelID: String
    let remainingFraction: Double?
    let resetAtISO: String?
}

nonisolated enum AntigravityUsageMapper {
    private struct NormalizedModel {
        let quota: AntigravityModelQuota
        let family: AntigravityModelFamily
        let sourceIndex: Int
        let isDisplayable: Bool
        let variantPriority: Int
    }

    static func buildResponse(
        quotas: [AntigravityModelQuota],
        accountEmail: String?,
        accountPlan: String?,
        source: AntigravityUsageDataSource
    ) -> AntigravityUsageResponse {
        let normalized = quotas.enumerated().map { index, quota in
            normalizeModel(quota, sourceIndex: index)
        }
        let windows = orderedDisplayModels(normalized, source: source)
            .compactMap { window(from: $0.quota) }

        return AntigravityUsageResponse(
            source: source,
            accountEmail: accountEmail,
            accountPlan: accountPlan,
            modelWindows: windows
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
        let cleanedLabel = quota.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedLabel.isEmpty {
            return cleanedLabel
        }
        return quota.modelID
    }

    private static func normalizeModel(
        _ quota: AntigravityModelQuota,
        sourceIndex: Int
    ) -> NormalizedModel {
        let modelID = quota.modelID.lowercased()
        let label = quota.label.lowercased()
        let family = AntigravityModelClassifier.family(forModelID: modelID, label: label)
        let isAutocomplete = modelID.contains("autocomplete")
            || label.contains("autocomplete")
            || modelID.hasPrefix("tab_")

        return NormalizedModel(
            quota: quota,
            family: family,
            sourceIndex: sourceIndex,
            isDisplayable: quota.remainingFraction != nil && !isAutocomplete,
            variantPriority: variantPriority(for: "\(modelID) \(label)")
        )
    }

    private static func orderedDisplayModels(
        _ models: [NormalizedModel],
        source: AntigravityUsageDataSource
    ) -> [NormalizedModel] {
        let displayable = models.filter(\.isDisplayable)
        switch source {
        case .agyCLI, .localIDE, .auto:
            return displayable.sorted { $0.sourceIndex < $1.sourceIndex }
        case .googleOAuth:
            return displayable.sorted { lhs, rhs in
                let lhsGroup = displayGroupPriority(for: lhs.family)
                let rhsGroup = displayGroupPriority(for: rhs.family)
                if lhsGroup != rhsGroup {
                    return lhsGroup < rhsGroup
                }
                if lhs.variantPriority != rhs.variantPriority {
                    return lhs.variantPriority < rhs.variantPriority
                }
                let labelOrder = lhs.quota.label.localizedStandardCompare(rhs.quota.label)
                if labelOrder != .orderedSame {
                    return labelOrder == .orderedAscending
                }
                return lhs.sourceIndex < rhs.sourceIndex
            }
        }
    }

    private static func displayGroupPriority(for family: AntigravityModelFamily) -> Int {
        switch family {
        case .geminiFlash:
            return 0
        case .geminiPro:
            return 1
        case .claude:
            return 2
        case .gpt:
            return 3
        case .unknown:
            return 4
        }
    }

    private static func variantPriority(for text: String) -> Int {
        if text.contains("medium") { return 0 }
        if text.contains("high") { return 1 }
        if text.contains("low") { return 2 }
        if text.contains("thinking") { return 3 }
        return 4
    }

    static func displayIcon(for window: AntigravityUsageWindow) -> String {
        switch window.family {
        case .geminiFlash:
            return "bolt.horizontal.circle"
        case .geminiPro:
            return "sparkles"
        case .claude:
            return "brain"
        case .gpt:
            return "cpu"
        case .unknown:
            return "square.stack.3d.up"
        }
    }
}
