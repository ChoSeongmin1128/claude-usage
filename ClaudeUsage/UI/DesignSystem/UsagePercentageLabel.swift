import SwiftUI

/// Keep the basis next to the value it qualifies, rather than in provider navigation.
struct UsagePercentageLabel: View {
    @Environment(\.colorScheme) private var scheme
    let percentage: Double
    let basis: UsageValueBasis
    let compact: Bool
    var percentageText: String?
    var color: Color?
    var font: Font? = nil

    var body: some View {
        PopoverMetricValue(
            text: percentageText ?? basis.text(fromUsed: percentage),
            caption: basis.percentage(fromUsed: percentage) == nil ? nil : basis.label,
            compact: compact,
            color: AppDesign.Text.status(color ?? ColorProvider.statusColor(for: percentage), scheme: scheme),
            font: font
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(basis.spokenValue(fromUsed: percentage))
    }
}
