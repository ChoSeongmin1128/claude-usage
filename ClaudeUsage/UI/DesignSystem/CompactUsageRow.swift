import SwiftUI

struct CompactUsageRow: View {
    let label: String
    let percentage: Double
    var resetAt: String? = nil
    var isWeekly: Bool = false
    var timeFormatStyle: TimeFormatStyle = .h24
    var showsResetDetail = true
    var resetDetailText: String? = nil
    var stacksResetDetail = false
    var color: Color? = nil
    var percentageText: String? = nil
    var tooltip: String? = nil
    var accessibilityLabel: String? = nil
    var accessibilityValue: String? = nil
    var basis: UsageValueBasis = .used

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

            HStack(spacing: AppDesign.Space.compact) {
                ProgressBarView(
                    percentage: percentage,
                    height:
                        PopoverLayoutMetrics
                            .compactProgressBarHeight,
                    color: color,
                    basis: basis
                )
                .frame(maxWidth: .infinity)

                UsagePercentageLabel(
                    percentage: percentage, basis: basis, compact: true,
                    percentageText: percentageText, color: color
                )
                .frame(width: PopoverLayoutMetrics.compactPercentageLabelWidth, alignment: .trailing)
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
                PopoverLayoutMetrics.compactUsageRowHeight(stackedReset: stacksResetDetail && resetDetailText != nil),
            maxHeight:
                PopoverLayoutMetrics.compactUsageRowHeight(stackedReset: stacksResetDetail && resetDetailText != nil),
            alignment: .center
        )
        .help(
            tooltip
                ?? [label, defaultAccessibilityValue].joined(separator: ", ")
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            accessibilityLabel ?? label
        )
        .accessibilityValue(
            accessibilityValue
                ?? defaultAccessibilityValue
        )
    }

    private var defaultAccessibilityValue: String {
        var values = [basis.spokenValue(fromUsed: percentage)]
        if let resetAt {
            values.append(TimeFormatter.formatRelativeTimeWithClock(from: resetAt, style: timeFormatStyle))
        }
        return values.joined(separator: ", ")
    }

    @ViewBuilder
    private var compactLabelLine: some View {
        if stacksResetDetail, let resetDetailText {
            VStack(alignment: .leading, spacing: AppDesign.Space.tight) {
                Text(label).font(AppDesign.Typography.caption.weight(.semibold)).lineLimit(1)
                Text(resetDetailText).font(AppDesign.Typography.metadata).foregroundStyle(.secondary).lineLimit(1)
            }
        } else if showsResetDetail {
            (
                Text(label)
                    .font(
                        .caption.weight(
                            .semibold
                        )
                    )
                    .foregroundStyle(.primary)
                + Text(" · ")
                .font(AppDesign.Typography.caption2)
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
                .minimumScaleFactor(0.85)
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
                .minimumScaleFactor(0.85)
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
