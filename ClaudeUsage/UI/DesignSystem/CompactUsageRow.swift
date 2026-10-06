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
    var basis: UsageValueBasis = .used

    var body: some View {
        PopoverMetricRow(density: .compact) {
            compactLabelLine
        } middle: {
            ProgressBarView(
                percentage: percentage, height: PopoverLayoutMetrics.compactProgressBarHeight,
                color: color, basis: basis)
        } value: {
            UsagePercentageLabel(
                percentage: percentage, basis: basis, compact: true,
                percentageText: percentageText, color: color)
        } detail: {
            EmptyView()
        }
        .help(tooltip ?? [label, defaultAccessibilityValue].joined(separator: ", "))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel ?? label)
        .accessibilityValue(accessibilityValue ?? defaultAccessibilityValue)
    }

    private var defaultAccessibilityValue: String {
        var values = [basis.spokenValue(fromUsed: percentage)]
        if let resetAt {
            values.append(
                TimeFormatter.formatRelativeTimeWithClock(
                    from: resetAt, style: timeFormatStyle))
        }
        return values.joined(separator: ", ")
    }

    @ViewBuilder
    private var compactLabelLine: some View {
        if showsResetDetail, let compactResetText {
            HStack(alignment: .firstTextBaseline, spacing: AppDesign.Space.tight) {
                Text(label)
                    .font(AppDesign.Typography.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1).minimumScaleFactor(0.85).truncationMode(.tail)
                Text("· " + compactResetText)
                    .font(AppDesign.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
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
            return nil
        }
        return TimeFormatter.formatCompactUsageReset(
            from: resetAt, isWeekly: isWeekly, style: timeFormatStyle)
    }
}
