import SwiftUI

enum AntigravityQuotaViewMetrics {
    static let compactLabelWidth: CGFloat = 112
    static let compactMeterWidth: CGFloat = 150
    static let compactSpacing: CGFloat = 6
    static let compactRowHeight: CGFloat = 18
    static let compactRailHeight: CGFloat = 8
}

struct AntigravityCompactQuotaView: View {
    let presentation: AntigravityCompactQuotaPresentation

    var body: some View {
        Group {
            if let metric = presentation.metric {
                metricRow(metric)
            } else {
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
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: AntigravityQuotaViewMetrics.compactRowHeight,
            maxHeight: AntigravityQuotaViewMetrics.compactRowHeight,
            alignment: .center
        )
    }

    private func metricRow(
        _ metric: AntigravityCompactQuotaMetricPresentation
    ) -> some View {
        HStack(
            alignment: .center,
            spacing: AntigravityQuotaViewMetrics.compactSpacing
        ) {
            Text(metric.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .truncationMode(.tail)
                .frame(
                    width: AntigravityQuotaViewMetrics.compactLabelWidth,
                    alignment: .leading
                )

            HStack(spacing: 4) {
                AntigravityQuotaRailView(
                    percentage: metric.usedPercentage,
                    tone: metric.tone,
                    height: AntigravityQuotaViewMetrics.compactRailHeight
                )
                .frame(maxWidth: .infinity)

                Text(metric.percentageText)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.semibold)
                    .foregroundStyle(metric.tone.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: 36, alignment: .trailing)
            }
            .frame(
                width: AntigravityQuotaViewMetrics.compactMeterWidth,
                alignment: .trailing
            )
        }
        .help(metric.tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric.accessibilityLabel)
        .accessibilityValue(metric.accessibilityValue)
    }
}
