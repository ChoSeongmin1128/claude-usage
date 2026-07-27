import SwiftUI

struct AntigravityQuotaGroupView: View {
    let group: AntigravityQuotaGroupPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
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

            VStack(alignment: .leading, spacing: 6) {
                ForEach(group.lanes) { lane in
                    AntigravityQuotaLaneRow(presentation: lane)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(group.title) 사용량 한도")
    }
}

private struct AntigravityQuotaLaneRow: View {
    let presentation: AntigravityQuotaLanePresentation

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(presentation.cadenceTitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(
                    presentation.isUnknownCadence
                        ? .secondary
                        : .primary
                )
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 48, alignment: .leading)

            valueView
                .frame(maxWidth: .infinity)

            Text(presentation.resetText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .truncationMode(.tail)
                .frame(width: 104, alignment: .trailing)
        }
        .frame(minHeight: 20)
        .help(presentation.tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(presentation.accessibilityValue)
    }

    @ViewBuilder
    private var valueView: some View {
        switch presentation.value {
        case .available(let usedPercentage, _):
            HStack(spacing: 7) {
                AntigravityQuotaRailView(
                    percentage: usedPercentage,
                    tone: presentation.tone,
                    height: 7
                )
                Text(presentation.percentageText ?? "")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(presentation.tone.color)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 36, alignment: .trailing)
            }
        case .unavailable(let reason):
            Text(reason.displayText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct AntigravityQuotaRailView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let percentage: Double
    let tone: AntigravityQuotaRiskTone
    var height: CGFloat = 7

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .separatorColor).opacity(0.24))

                Capsule()
                    .fill(tone.color)
                    .frame(
                        width: geometry.size.width
                            * CGFloat(clampedPercentage / 100)
                    )
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: 0.22),
                        value: clampedPercentage
                    )
            }
        }
        .frame(height: height)
    }

    private var clampedPercentage: Double {
        max(0, min(percentage, 100))
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
