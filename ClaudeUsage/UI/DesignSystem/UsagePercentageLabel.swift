import SwiftUI

/// Keep the basis next to the value it qualifies, rather than in provider navigation.
struct UsagePercentageLabel: View {
    let percentage: Double
    let basis: UsageValueBasis
    let compact: Bool
    var percentageText: String?
    var color: Color?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppDesign.Space.micro) {
            Text(percentageText ?? basis.text(fromUsed: percentage))
                .font(compact ? AppDesign.Typography.compactValue : AppDesign.Typography.headline)
                .foregroundStyle(color ?? ColorProvider.statusColor(for: percentage))
            if basis.percentage(fromUsed: percentage) != nil {
                Text(basis.label)
                    .font(AppDesign.Typography.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(basis.spokenValue(fromUsed: percentage))
    }
}
