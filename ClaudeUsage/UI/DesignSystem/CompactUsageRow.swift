import SwiftUI

struct CompactUsageRow: View {
    let label: String
    let percentage: Double
    var resetAt: String? = nil
    var isWeekly: Bool = false
    var timeFormatStyle: TimeFormatStyle = .h24
    var showsResetDetail = true
    var color: Color? = nil
    var percentageText: String? = nil
    var tooltip: String? = nil
    var accessibilityLabel: String? = nil
    var accessibilityValue: String? = nil

    var body: some View {
        HStack(
            alignment: .center,
            spacing:
                PopoverLayoutMetrics
                    .compactRowSpacing
        ) {
            compactLabelLine
                .frame(
                    width:
                        PopoverLayoutMetrics
                            .compactRowLabelWidth,
                    alignment: .leading
                )

            HStack(spacing: 4) {
                ProgressBarView(
                    percentage: percentage,
                    height:
                        PopoverLayoutMetrics
                            .compactProgressBarHeight,
                    color: color
                )
                .frame(maxWidth: .infinity)

                Text(
                    percentageText
                        ?? String(
                            format: "%.0f%%",
                            percentage
                        )
                )
                .font(
                    .system(
                        .caption,
                        design: .monospaced
                    )
                )
                .fontWeight(.medium)
                .foregroundStyle(
                    color
                        ?? ColorProvider.statusColor(
                            for: percentage
                        )
                )
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(
                    width: 32,
                    alignment: .trailing
                )
            }
            .frame(
                width:
                    PopoverLayoutMetrics
                        .compactRowMeterWidth,
                alignment: .trailing
            )
        }
        .frame(
            maxWidth: .infinity,
            minHeight:
                PopoverLayoutMetrics
                    .compactUsageRowHeight,
            maxHeight:
                PopoverLayoutMetrics
                    .compactUsageRowHeight,
            alignment: .center
        )
        .help(
            tooltip
                ?? "\(label), \(Int(percentage.rounded()))퍼센트 사용"
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            accessibilityLabel ?? label
        )
        .accessibilityValue(
            accessibilityValue
                ?? "\(Int(percentage.rounded()))퍼센트 사용"
        )
    }

    @ViewBuilder
    private var compactLabelLine: some View {
        if showsResetDetail {
            (
                Text(label)
                    .font(
                        .caption.weight(
                            .semibold
                        )
                    )
                    .foregroundStyle(.primary)
                + Text(" · ")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                + Text(compactResetText ?? "--")
                    .font(
                        .system(
                            size: 10,
                            weight: .medium
                        )
                    )
                    .foregroundStyle(.secondary)
            )
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .truncationMode(.tail)
        } else {
            Text(label)
                .font(
                    .caption.weight(
                        .semibold
                    )
                )
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .truncationMode(.tail)
        }
    }

    private var compactResetText: String? {
        guard let resetAt else {
            return "--"
        }
        if isWeekly {
            return TimeFormatter
                .formatResetTimeWeekly(
                    from: resetAt,
                    style: timeFormatStyle
                ) ?? "--"
        }
        return TimeFormatter.formatResetTime(
            from: resetAt,
            style: timeFormatStyle,
            includeDateIfNotToday: false
        ) ?? "--"
    }
}
