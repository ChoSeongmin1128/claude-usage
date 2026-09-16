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
        HStack(alignment: .center, spacing: AppDesign.Space.label) {
            VStack(alignment: .leading, spacing: AppDesign.Space.tight) {
                Text(title)
                    .font(AppDesign.Typography.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .truncationMode(.tail)

                if let detailText {
                    Text(detailText)
                        .font(AppDesign.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailingValue
                .frame(width: 148, alignment: .trailing)
        }
        .frame(
            minHeight:
                PopoverLayoutMetrics
                    .standardUsageRowHeight,
            maxHeight:
                PopoverLayoutMetrics
                    .standardUsageRowHeight
        )
        .help(tooltip ?? defaultTooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel ?? title)
        .accessibilityValue(accessibilityValue ?? defaultAccessibilityValue)
    }

    @ViewBuilder
    private var trailingValue: some View {
        if let percentage {
            HStack(spacing: AppDesign.Space.row) {
                ProgressBarView(
                    percentage: percentage,
                    height: 8,
                    color: color,
                    basis: basis
                )
                .frame(maxWidth: .infinity)

                Text(
                    percentageText
                        ?? basis.text(fromUsed: percentage)
                )
                .font(AppDesign.Typography.headline)
                .fontWeight(.bold)
                .foregroundStyle(
                    color
                        ?? ColorProvider.statusColor(
                            for: percentage
                        )
                )
                .fixedSize(horizontal: true, vertical: false)
            }
        } else {
            Text(unavailableText ?? "사용량 알 수 없음")
                .font(AppDesign.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var defaultTooltip: String {
        [title, defaultAccessibilityValue, detailText]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private var defaultAccessibilityValue: String {
        if let percentage {
            return [basis.spokenValue(fromUsed: percentage), detailText].compactMap { $0 }.joined(separator: ", ")
        }
        return unavailableText ?? "사용량 알 수 없음"
    }
}
