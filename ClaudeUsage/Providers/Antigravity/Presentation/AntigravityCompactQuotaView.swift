// Antigravity compact surface built from shared usage row primitives.
import SwiftUI

struct AntigravityCompactQuotaView: View {
    let presentation: AntigravityCompactQuotaPresentation

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: PopoverLayoutMetrics.compactSectionSpacing
        ) {
            if presentation.metrics.isEmpty {
                Text(
                    presentation.unavailableText
                        ?? "확인 가능한 사용량 한도 없음"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Antigravity 사용량 한도")
                .accessibilityValue(
                    presentation.unavailableText
                        ?? "확인 가능한 사용량 한도 없음"
                )
                .frame(
                    minHeight:
                        PopoverLayoutMetrics
                            .compactUsageRowHeight
                )
            } else {
                ForEach(
                    presentation.metrics,
                    id: \.laneID
                ) { metric in
                    CompactUsageRow(
                        label: metric.label,
                        percentage:
                            metric.usedPercentage,
                        showsResetDetail: false,
                        color: metric.tone.color,
                        percentageText:
                            metric.percentageText,
                        tooltip: metric.tooltip,
                        accessibilityLabel:
                            metric.accessibilityLabel,
                        accessibilityValue:
                            metric.accessibilityValue
                    )
                }
            }
        }
    }
}
