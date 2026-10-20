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
        VStack(alignment: .leading, spacing: PopoverLayoutMetrics.standardUsageRowSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: AppDesign.Space.label) {
                Text(title)
                    .font(AppDesign.Typography.subheadline.weight(.medium))
                    .foregroundStyle(AppDesign.Text.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let percentage {
                    UsagePercentageLabel(
                        percentage: percentage, basis: basis, compact: false,
                        percentageText: percentageText, color: color, font: AppDesign.Typography.usageValue
                    )
                    .fixedSize(horizontal: true, vertical: false)
                } else {
                    Text(unavailableText ?? "사용량 알 수 없음")
                        .font(AppDesign.Typography.caption)
                        .foregroundStyle(AppDesign.Text.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
            if let percentage {
                ProgressBarView(
                    percentage: percentage, height: PopoverLayoutMetrics.standardUsageRowBarHeight, color: color,
                    basis: basis)
            } else {
                Color.clear.frame(height: PopoverLayoutMetrics.standardUsageRowBarHeight)
            }
            if let detailText {
                detailLabel(detailText)
                    .font(AppDesign.Typography.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(height: PopoverLayoutMetrics.standardUsageRowHeight, alignment: .top)
        .help(tooltip ?? defaultTooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel ?? title)
        .accessibilityValue(accessibilityValue ?? defaultAccessibilityValue)
    }

    private func detailLabel(_ text: String) -> Text {
        guard let range = text.range(of: TimeFormatter.usageResetDetailSeparator) else {
            return Text(text).foregroundStyle(Color.primary)
        }
        return Text(String(text[..<range.lowerBound])).foregroundStyle(Color.primary)
            + Text(String(text[range.lowerBound...])).foregroundStyle(AppDesign.Text.faint)
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
