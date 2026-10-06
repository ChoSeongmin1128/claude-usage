import SwiftUI

/// Provider-neutral usage row for the standard popover surface.
///
/// Providers supply already-formatted labels and accessibility text while this
/// view owns the shared typography, spacing, progress rail, and percentage
/// treatment.
struct StandardUsageRow: View {
    let title: String
    let percentage: Double?
    let detailText: String?
    var percentageText: String? = nil
    var unavailableText: String? = nil
    var color: Color? = nil
    var tooltip: String? = nil
    var accessibilityLabel: String? = nil
    var accessibilityValue: String? = nil
    var basis: UsageValueBasis = .used

    var body: some View {
        PopoverMetricRow(density: .standard, valueSpansMiddle: percentage == nil) {
            Text(title)
                .font(AppDesign.Typography.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .truncationMode(.tail)
        } middle: {
            if let percentage {
                ProgressBarView(percentage: percentage, height: 8, color: color, basis: basis)
            }
        } value: {
            if let percentage {
                UsagePercentageLabel(
                    percentage: percentage, basis: basis, compact: false,
                    percentageText: percentageText, color: color)
            } else {
                Text(unavailableText ?? "사용량 알 수 없음")
                    .font(AppDesign.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        } detail: {
            if let detailText {
                Text(detailText)
                    .font(AppDesign.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .help(tooltip ?? defaultTooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel ?? title)
        .accessibilityValue(accessibilityValue ?? defaultAccessibilityValue)
    }

    private var defaultTooltip: String {
        [title, defaultAccessibilityValue].joined(separator: ", ")
    }

    private var defaultAccessibilityValue: String {
        if let percentage {
            return [basis.spokenValue(fromUsed: percentage), detailText].compactMap { $0 }.joined(separator: ", ")
        }
        return unavailableText ?? "사용량 알 수 없음"
    }
}
