import SwiftUI

/// Keep the basis next to the value it qualifies, rather than in provider navigation.
struct UsagePercentageLabel: View {
    let percentage: Double
    let basis: UsageValueBasis
    let compact: Bool
    var percentageText: String?
    var color: Color?

    var body: some View {
        PopoverMetricValue(
            text: percentageText ?? basis.text(fromUsed: percentage),
            caption: basis.percentage(fromUsed: percentage) == nil ? nil : basis.label,
            compact: compact, color: color ?? ColorProvider.statusColor(for: percentage)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(basis.spokenValue(fromUsed: percentage))
    }
}
