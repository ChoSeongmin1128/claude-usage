// Surface presentation models derived from Antigravity quota domain.
import Foundation

nonisolated enum AntigravityQuotaRiskTone:
    String,
    Sendable,
    Equatable
{
    case neutral
    case healthy
    case attention
    case warning
    case critical
}

nonisolated enum AntigravityQuotaUnavailableReason:
    String,
    Sendable,
    Equatable
{
    case disabled
    case notReported

    var displayText: String {
        switch self {
        case .disabled:
            "사용 중지됨"
        case .notReported:
            "사용량 알 수 없음"
        }
    }
}

nonisolated enum AntigravityQuotaValuePresentation:
    Sendable,
    Equatable
{
    case available(
        usedPercentage: Double,
        remainingPercentage: Double
    )
    case unavailable(AntigravityQuotaUnavailableReason)

    var usedPercentage: Double? {
        guard case let .available(usedPercentage, _) = self else {
            return nil
        }
        return usedPercentage
    }

    var remainingPercentage: Double? {
        guard case let .available(_, remainingPercentage) = self else {
            return nil
        }
        return remainingPercentage
    }
}

nonisolated struct AntigravityQuotaLanePresentation:
    Identifiable,
    Sendable,
    Equatable
{
    let id: AntigravityQuotaLaneID
    let scopeTitle: String
    let cadenceTitle: String
    let compactLabel: String
    let menuLabel: String
    let cadence: AntigravityQuotaCadence
    let value: AntigravityQuotaValuePresentation
    let percentageText: String?
    let resetAt: Date?
    let resetText: String
    let tone: AntigravityQuotaRiskTone
    let isUnknownScope: Bool
    let isUnknownCadence: Bool
    let tooltip: String
    let accessibilityLabel: String
    let accessibilityValue: String

    /// 일반 팝오버에서는 다른 provider와 같은 "한도" 명명 규칙을 씁니다.
    /// compact/menu/editor 표면은 공간과 식별 맥락이 달라 짧은 cadenceTitle을
    /// 그대로 유지합니다.
    var standardRowTitle: String {
        switch cadence {
        case .fiveHour:
            "5시간 한도"
        case .weekly:
            "주간 한도"
        case .unknown:
            cadenceTitle
        }
    }
}

nonisolated struct AntigravityQuotaGroupPresentation:
    Identifiable,
    Sendable,
    Equatable
{
    let id: AntigravityQuotaGroupPresentationID
    let title: String
    let isUnknownScope: Bool
    let lanes: [AntigravityQuotaLanePresentation]
}

nonisolated enum AntigravityQuotaGroupPresentationID:
    Sendable,
    Equatable,
    Hashable
{
    case gemini
    case thirdPartyModels
    case unknown(upstreamID: String, label: String?)
}

nonisolated enum ProviderIdentityRailTone:
    String,
    Sendable,
    Equatable
{
    case standard
    case attention
    case critical
}

/// Provider-neutral evidence shown beside a provider's usage data.
///
/// The view consuming this value does not look up account or runtime state.
/// That keeps provenance presentation reusable across providers and prevents
/// an Antigravity account from being resolved through Claude-specific models.
nonisolated struct ProviderIdentityRailProjection:
    Sendable,
    Equatable
{
    let providerName: String
    let accountLabel: String
    let sourceLabel: String
    let freshnessLabel: String
    let statusLabels: [String]
    let tone: ProviderIdentityRailTone
    let tooltip: String
    let accessibilityLabel: String
    let accessibilityValue: String

    var visibleSegments: [String] {
        [accountLabel, sourceLabel, freshnessLabel] + statusLabels
    }
}

nonisolated struct AntigravityCompactQuotaMetricPresentation:
    Sendable,
    Equatable
{
    let laneID: AntigravityQuotaLaneID
    let label: String
    let usedPercentage: Double
    let percentageText: String
    let tone: AntigravityQuotaRiskTone
    let tooltip: String
    let accessibilityLabel: String
    let accessibilityValue: String
}

nonisolated struct AntigravityCompactQuotaPresentation:
    Sendable,
    Equatable
{
    let metrics: [AntigravityCompactQuotaMetricPresentation]
    let unavailableText: String?

    var metric: AntigravityCompactQuotaMetricPresentation? {
        metrics.first
    }

    static let unavailable = AntigravityCompactQuotaPresentation(
        metrics: [],
        unavailableText: "확인 가능한 사용량 한도 없음"
    )
}

nonisolated struct AntigravityMenuBarQuotaPresentation:
    Sendable,
    Equatable
{
    let isVisible: Bool
    let showsProviderIcon: Bool
    let style:
        AntigravityDisplaySettings.MenuBarPresentationIntent.Style
    let selectedLaneID: AntigravityQuotaLaneID?
    let regularText: String?
    let condensedText: String?
    let gaugePercentage: Double?
    let showsGaugePercentage: Bool
    let tooltip: String
    let tone: AntigravityQuotaRiskTone
    let accessibilityLabel: String
    let accessibilityValue: String
}

nonisolated enum AntigravityQuotaPresentationSurface:
    String,
    Sendable,
    Equatable
{
    case compact
    case menuBar
}

nonisolated struct AntigravityQuotaPresentationNotice:
    Identifiable,
    Sendable,
    Equatable
{
    enum Kind: Sendable, Equatable {
        case fixedLaneUnavailable(
            requestedLaneID: AntigravityQuotaLaneID,
            fallbackLaneID: AntigravityQuotaLaneID?
        )
    }

    let surface: AntigravityQuotaPresentationSurface
    let kind: Kind
    let title: String
    let message: String

    var id: String {
        switch kind {
        case let .fixedLaneUnavailable(requestedLaneID, _):
            "\(surface.rawValue).fixed-lane-unavailable.\(requestedLaneID.rawValue)"
        }
    }
}

nonisolated struct AntigravityQuotaPresentation:
    Sendable,
    Equatable
{
    let context: AntigravityQuotaPresentationContext
    /// All lanes returned by the current provider payload, before the user's
    /// standard-popover visibility policy is applied.
    let allGroups: [AntigravityQuotaGroupPresentation]
    /// Lanes selected for the standard popover, in persisted presentation
    /// order.
    let groups: [AntigravityQuotaGroupPresentation]
    let compact: AntigravityCompactQuotaPresentation
    let menuBar: AntigravityMenuBarQuotaPresentation
    let identityRail: ProviderIdentityRailProjection
    let notices: [AntigravityQuotaPresentationNotice]

    var observedLaneCount: Int {
        allGroups.reduce(into: 0) { count, group in
            count += group.lanes.count
        }
    }
}

nonisolated struct AntigravityQuotaPresentationContext:
    Sendable,
    Equatable
{
    enum Phase: Sendable, Equatable {
        case current
        case refreshing
        case stale(AntigravityFailure)
    }

    let phase: Phase
    let decodeIssueCount: Int

    init(
        phase: Phase = .current,
        decodeIssueCount: Int = 0
    ) {
        self.phase = phase
        self.decodeIssueCount = max(0, decodeIssueCount)
    }
}

nonisolated enum AntigravityQuotaPresentationMappingResult:
    Sendable,
    Equatable
{
    case content(AntigravityQuotaPresentation)
    case unavailable(AntigravityPresentationState)
}
