import SwiftUI

/// Provider-neutral usage row for the standard popover surface.
///
/// Providers supply already-formatted labels and accessibility text while this
/// view owns the shared typography, spacing, progress rail, and percentage
/// treatment.
///
/// 세로 스택(제목+값 / 진행바 / 갱신 상세)이며 높이는
/// `PopoverLayoutMetrics.standardUsageRowHeight`에 고정된다. 팝오버 크기는 측정이
/// 아니라 이 상수로 계산되므로 스택 구성이 바뀌면 상수도 함께 바꿔야 한다.
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
                    // 값은 줄어들지 않고 제목이 잘리도록 고정 폭을 쓴다.
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
                // 값이 없어도 행 높이는 같아야 한다.
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

    /// "3시간 42분 후 · 19:39" → 상대 시간은 primary, 구분자부터 시각은 faint.
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
