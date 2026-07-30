import SwiftUI

struct AntigravityQuotaGroupView: View {
    let group: AntigravityQuotaGroupPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(group.title)
                .font(.subheadline.weight(
                    group.isUnknownScope ? .medium : .semibold
                ))
                .foregroundStyle(
                    group.isUnknownScope ? .secondary : .primary
                )
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(group.lanes) { lane in
                    AntigravityQuotaLaneRow(
                        presentation: lane
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(group.title) 사용량 한도")
    }
}

struct AntigravityQuotaGroupsView: View {
    let groups: [AntigravityQuotaGroupPresentation]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(
                Array(groups.enumerated()),
                id: \.element.id
            ) { index, group in
                if index > 0 {
                    Divider()
                        .padding(.vertical, 8)
                }
                AntigravityQuotaGroupView(group: group)
            }
        }
    }
}

private struct AntigravityQuotaLaneRow: View {
    let presentation: AntigravityQuotaLanePresentation

    var body: some View {
        switch presentation.value {
        case .available(let usedPercentage, _):
            StandardUsageRow(
                title: presentation.standardRowTitle,
                percentage: usedPercentage,
                detailText: presentation.resetText,
                percentageText:
                    presentation.percentageText,
                color: presentation.tone.color,
                tooltip: presentation.tooltip,
                accessibilityLabel:
                    presentation.accessibilityLabel,
                accessibilityValue:
                    presentation.accessibilityValue
            )
        case .unavailable(let reason):
            StandardUsageRow(
                title: presentation.standardRowTitle,
                percentage: nil,
                detailText: presentation.resetText,
                unavailableText: reason.displayText,
                tooltip: presentation.tooltip,
                accessibilityLabel:
                    presentation.accessibilityLabel,
                accessibilityValue:
                    presentation.accessibilityValue
            )
        }
    }

}

extension AntigravityQuotaRiskTone {
    var color: Color {
        switch self {
        case .neutral:
            Color(nsColor: .secondaryLabelColor)
        case .healthy:
            Color(nsColor: .systemGreen)
        case .attention:
            Color(nsColor: .systemYellow)
        case .warning:
            Color(nsColor: .systemOrange)
        case .critical:
            Color(nsColor: .systemRed)
        }
    }
}
