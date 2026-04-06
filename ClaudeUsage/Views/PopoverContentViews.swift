import SwiftUI

enum StatusPanelActionStyle: Equatable {
    case bordered
    case prominent
}

struct StatusPanelView: View {
    let density: PopoverDensity
    let icon: String?
    let iconColor: Color
    let showsProgress: Bool
    let title: String
    let message: String
    let actionTitle: String?
    let actionStyle: StatusPanelActionStyle
    let action: (() -> Void)?

    private var compactPanelHeight: CGFloat {
        if actionTitle != nil, action != nil {
            return PopoverLayoutMetrics.compactInteractiveStatusPanelHeight
        }
        return PopoverLayoutMetrics.compactStatusPanelHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.isCompact ? 6 : 10) {
            HStack(alignment: .center, spacing: density.isCompact ? 8 : 10) {
                leadingIndicator

                Text(title)
                    .font(density.isCompact ? .caption.weight(.semibold) : .title3.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(density.isCompact ? 0.85 : 1.0)

                Spacer(minLength: density.isCompact ? 8 : 12)

                if let actionTitle, let action {
                    actionButton(title: actionTitle, action: action)
                }
            }

            Text(message)
                .font(density.isCompact ? .system(size: 10, weight: .medium) : .subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(
            minHeight: density.isCompact ? compactPanelHeight : nil,
            maxHeight: density.isCompact ? compactPanelHeight : nil,
            alignment: .topLeading
        )
        .padding(.vertical, density.isCompact ? 0 : 4)
    }

    @ViewBuilder
    private var leadingIndicator: some View {
        if showsProgress {
            ProgressView()
                .controlSize(density.isCompact ? .small : .regular)
                .frame(width: density.isCompact ? 14 : 18, height: density.isCompact ? 14 : 18, alignment: .center)
        } else if let icon {
            Image(systemName: icon)
                .font(.system(size: density.isCompact ? 12 : 15, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: density.isCompact ? 14 : 18, height: density.isCompact ? 14 : 18, alignment: .center)
        }
    }

    @ViewBuilder
    private func actionButton(title: String, action: @escaping () -> Void) -> some View {
        if actionStyle == .prominent {
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(density.isCompact ? .small : .regular)
        } else {
            Button(title, action: action)
                .buttonStyle(.bordered)
                .controlSize(density.isCompact ? .small : .regular)
        }
    }
}

struct PopoverDisplaySectionView: View {
    let section: PopoverDisplaySection
    let density: PopoverDensity

    var body: some View {
        switch section.payload {
        case .usage(let usage):
            if density.isCompact {
                CompactUsageRow(
                    label: usage.compactLabel,
                    percentage: usage.percentage,
                    resetAt: usage.resetAt,
                    isWeekly: usage.isWeekly,
                    timeFormatStyle: usage.timeFormatStyle
                )
            } else {
                UsageSectionView(
                    systemIcon: usage.systemIcon,
                    title: usage.title,
                    percentage: usage.percentage,
                    resetAt: usage.resetAt,
                    isWeekly: usage.isWeekly,
                    timeFormatStyle: usage.timeFormatStyle
                )
            }
        case .credits(let credits):
            if density.isCompact {
                CompactCodexCreditsRow(credits: credits.credits)
            } else {
                CodexCreditsView(credits: credits.credits)
            }
        case .overage(let overage):
            if density.isCompact {
                CompactOverageRow(overage: overage.overage)
            } else {
                OverageUsageView(overage: overage.overage)
            }
        case .account(let account):
            AccountSectionView(account: account, density: density)
        case .status(let status):
            ProviderStatusSectionView(status: status, density: density)
        }
    }
}

struct AccountSectionView: View {
    let account: PopoverAccountSectionData
    let density: PopoverDensity

    var body: some View {
        VStack(alignment: .leading, spacing: density.isCompact ? 4 : 6) {
            Label(account.title, systemImage: account.systemIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let email = account.email {
                Text(email)
                    .font(density.isCompact ? .caption : .subheadline)
                    .lineLimit(1)
            }
            if let plan = account.plan {
                Text("플랜: \(plan)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ProviderStatusSectionView: View {
    let status: PopoverStatusSectionData
    let density: PopoverDensity

    var body: some View {
        if density.isCompact {
            HStack(spacing: 6) {
                Text(status.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }
            .frame(
                maxWidth: .infinity,
                minHeight: PopoverLayoutMetrics.compactStatusRowHeight,
                maxHeight: PopoverLayoutMetrics.compactStatusRowHeight,
                alignment: .center
            )
        } else {
            ProviderStatusRow(title: status.title, error: status.error)
        }
    }

    private var statusText: String {
        if let error = status.error {
            return error.isDefinitiveAuthFailure ? "인증 필요" : "조회 실패"
        }
        return "데이터 없음"
    }

    private var statusColor: Color {
        if let error = status.error {
            return error.isDefinitiveAuthFailure ? .orange : .secondary
        }
        return .secondary
    }
}

struct CompactUsageRow: View {
    let label: String
    let percentage: Double
    var resetAt: String? = nil
    var isWeekly: Bool = false
    var timeFormatStyle: TimeFormatStyle = .h24

    var body: some View {
        HStack(alignment: .center, spacing: PopoverLayoutMetrics.compactRowSpacing) {
            compactLabelLine
                .frame(width: PopoverLayoutMetrics.compactRowLabelWidth, alignment: .leading)

            HStack(spacing: 4) {
                ProgressBarView(
                    percentage: percentage,
                    height: PopoverLayoutMetrics.compactProgressBarHeight
                )
                .frame(maxWidth: .infinity)

                Text(String(format: "%.0f%%", percentage))
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.medium)
                    .foregroundStyle(ColorProvider.statusColor(for: percentage))
                    .lineLimit(1)
                    .frame(width: 32, alignment: .trailing)
            }
            .frame(width: PopoverLayoutMetrics.compactRowMeterWidth, alignment: .trailing)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: PopoverLayoutMetrics.compactUsageRowHeight,
            maxHeight: PopoverLayoutMetrics.compactUsageRowHeight,
            alignment: .center
        )
    }

    private var compactLabelLine: some View {
        (
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            +
            Text(" · ")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            +
            Text(compactResetText ?? "--")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        )
        .lineLimit(1)
        .minimumScaleFactor(0.72)
        .truncationMode(.tail)
    }

    private var compactResetText: String? {
        guard let resetAt = resetAt else { return "--" }
        if isWeekly {
            return TimeFormatter.formatResetTimeWeekly(from: resetAt, style: timeFormatStyle) ?? "--"
        }
        return TimeFormatter.formatResetTime(from: resetAt, style: timeFormatStyle, includeDateIfNotToday: false) ?? "--"
    }
}

struct ProviderStatusRow: View {
    let title: String
    let error: APIError?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline)
            Spacer()
            Text(statusText)
                .font(.caption)
                .foregroundStyle(statusColor)
        }
        .padding(.vertical, 4)
    }

    private var statusText: String {
        if let error {
            return error.isDefinitiveAuthFailure ? "인증 필요" : "조회 실패"
        }
        return "데이터 없음"
    }

    private var statusColor: Color {
        if let error {
            return error.isDefinitiveAuthFailure ? .orange : .secondary
        }
        return .secondary
    }
}

struct CodexCreditsView: View {
    let credits: CodexCredits

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "creditcard")
                    .foregroundStyle(.secondary)
                Text("Codex 크레딧")
                    .font(.headline)
                Spacer()
                Text(credits.formattedBalance)
                    .font(.title3)
                    .fontWeight(.semibold)
            }
            HStack {
                Text(credits.unlimited ? "무제한 플랜" : "사용 가능한 크레딧")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }
}

struct CompactCodexCreditsRow: View {
    let credits: CodexCredits

    var body: some View {
        HStack(spacing: PopoverLayoutMetrics.compactRowSpacing) {
            Text("크레딧")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: PopoverLayoutMetrics.compactRowLabelWidth, alignment: .leading)

            Text(credits.formattedBalance)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: PopoverLayoutMetrics.compactRowMeterWidth, alignment: .trailing)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: PopoverLayoutMetrics.compactCreditsRowHeight,
            maxHeight: PopoverLayoutMetrics.compactCreditsRowHeight,
            alignment: .center
        )
    }
}

struct OverageUsageView: View {
    let overage: OverageSpendLimitResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "creditcard")
                    .foregroundStyle(.secondary)
                Text("추가 사용량")
                    .font(.headline)
                Spacer(minLength: 0)
                Text(String(format: "%.0f%%", overage.usagePercentage))
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.purple)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Text("\(overage.formattedUsedCredits) 사용 / \(overage.formattedCreditLimit) 한도 (잔액 \(overage.formattedRemainingCredits))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.vertical, 2)
    }
}

struct CompactOverageRow: View {
    let overage: OverageSpendLimitResponse

    var body: some View {
        HStack(alignment: .center, spacing: PopoverLayoutMetrics.compactRowSpacing) {
            (Text("추가 사용량")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            + Text(" \(overage.formattedRemainingCredits)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary))
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .truncationMode(.tail)
            .frame(width: PopoverLayoutMetrics.compactRowLabelWidth, alignment: .leading)

            HStack(spacing: 4) {
                ProgressBarView(
                    percentage: overage.usagePercentage,
                    height: PopoverLayoutMetrics.compactProgressBarHeight,
                    color: .purple
                )
                .frame(maxWidth: .infinity)

                Text(String(format: "%.0f%%", overage.usagePercentage))
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.medium)
                    .foregroundStyle(.purple)
                    .lineLimit(1)
                    .frame(width: 32, alignment: .trailing)
            }
            .frame(width: PopoverLayoutMetrics.compactRowMeterWidth, alignment: .trailing)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: PopoverLayoutMetrics.compactUsageRowHeight,
            maxHeight: PopoverLayoutMetrics.compactUsageRowHeight,
            alignment: .center
        )
    }
}
