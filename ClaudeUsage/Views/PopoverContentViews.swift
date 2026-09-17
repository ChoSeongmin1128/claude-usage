import AppKit
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
            .frame(
                height: density.isCompact
                    ? (actionTitle != nil && action != nil
                        ? AppDesign.Control.compactHitSize : PopoverLayoutMetrics.compactStatusHeadingHeight)
                    : nil)

            Text(message)
                .font(density.isCompact ? .system(size: 10, weight: .medium) : .subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(
                    maxHeight: density.isCompact ? PopoverLayoutMetrics.compactStatusMessageHeight : nil,
                    alignment: .topLeading)
        }
        .help("\(title)\n\(message)")
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
                    timeFormatStyle: usage.timeFormatStyle,
                    basis: usage.basis
                )
            } else {
                UsageSectionView(
                    title: usage.title,
                    percentage: usage.percentage,
                    resetAt: usage.resetAt,
                    isWeekly: usage.isWeekly,
                    timeFormatStyle: usage.timeFormatStyle,
                    basis: usage.basis
                )
            }
        case .credits(let credits):
            if density.isCompact {
                CompactCodexCreditsRow(credits: credits.credits)
            } else {
                CodexCreditsView(credits: credits.credits)
            }
        case .resetCredits(let resetCredits):
            if density.isCompact {
                CompactCodexResetCreditsRow(data: resetCredits)
            } else {
                CodexResetCreditsView(data: resetCredits)
            }
        case .overage(let overage):
            if density.isCompact {
                CompactOverageRow(overage: overage.overage, updatedAt: overage.updatedAt, isStale: overage.isStale)
            } else {
                OverageUsageView(overage: overage.overage, updatedAt: overage.updatedAt, isStale: overage.isStale)
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
                .font(AppDesign.Typography.caption)
                .foregroundStyle(.secondary)
            if let email = account.email {
                Text(email)
                    .font(density.isCompact ? .caption : .subheadline)
                    .lineLimit(1)
            }
            if let plan = account.plan {
                Text("플랜: \(plan)")
                    .font(AppDesign.Typography.caption)
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
            HStack(spacing: AppDesign.Space.control) {
                Text(status.title)
                    .font(AppDesign.Typography.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(statusText)
                    .font(AppDesign.Typography.caption)
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
            ProviderStatusRow(status: status)
        }
    }

    private var statusText: String {
        if let error = status.error {
            return error.compactStatusText
        }
        return status.statusText ?? "데이터 없음"
    }

    private var statusColor: Color {
        if let error = status.error {
            return error.compactStatusColor
        }
        return status.statusText == nil ? .secondary : .orange
    }
}

struct PopoverDisplayEditorView: View {
    @ObservedObject var settings: AppSettings
    let service: PopoverService
    @Binding var selectedMode: PopoverDisplayEditorMode

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.label) {
            DisplayModePicker(selection: modeSelection)

            PopoverDisplayItemsListView(
                settings: settings,
                service: service,
                isCompact: selectedMode.isCompact
            )
        }
        .padding(AppDesign.Space.content)
        .frame(width: 280)
        .background(AppDesign.Surface.group)
    }

    private var modeSelection: Binding<PopoverDisplayEditorMode> {
        Binding(
            get: { selectedMode },
            set: { newMode in
                if newMode.isCompact && !settings.separateCompactConfig {
                    settings.separateCompactConfig = true
                }
                selectedMode = newMode
            }
        )
    }
}

struct PopoverDisplayItemsListView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var settings: AppSettings
    let service: PopoverService
    let isCompact: Bool
    /// 프로바이더 응답은 정상인데 현재 표시할 데이터가 없는 항목 (설정 목록에 안내 표시)
    var unavailableItemIDs: Set<String> = []
    private var items: [PopoverItemConfig] {
        isCompact
            ? settings.compactPopoverItems(for: service)
            : settings.popoverItems(for: service)
    }

    var body: some View {
        if let model = CatalogDisplayAdapter
            .editorModel(
                service: service,
                surface:
                    isCompact ? .compact : .standard,
                settings: settings,
                unavailableItemIDs:
                    unavailableItemIDs
            )
        {
            DisplayItemList(
                model: model,
                onToggleVisibility: {
                    toggleVisibility(id: $0)
                },
                onMoveByOffset: {
                    moveItem(id: $0, offset: $1)
                },
                onMoveToItem: moveItem
            )
        }
    }

    private func applyItems(_ items: [PopoverItemConfig], isCompact: Bool) {
        if isCompact {
            settings.setCompactPopoverItems(items, for: service)
        } else {
            settings.setPopoverItems(items, for: service)
        }
    }

    private func moveItem(id: String, offset: Int) {
        var updated = items
        guard let fromIndex = updated.firstIndex(where: { $0.id == id }) else { return }
        let targetIndex = fromIndex + offset
        guard updated.indices.contains(targetIndex) else { return }
        withAnimation(settings.motion.animation(for: .itemChanges, reduceMotion: reduceMotion)) {
            updated.swapAt(fromIndex, targetIndex)
            applyItems(updated, isCompact: isCompact)
        }
    }

    private func moveItem(
        sourceID: String,
        targetID: String
    ) {
        var updated = items
        guard let sourceIndex = updated.firstIndex(
            where: { $0.id == sourceID }
        ),
        let targetIndex = updated.firstIndex(
            where: { $0.id == targetID }
        ),
        sourceIndex != targetIndex
        else {
            return
        }
        withAnimation(
            settings.motion.animation(for: .itemChanges, reduceMotion: reduceMotion)
        ) {
            let item = updated.remove(
                at: sourceIndex
            )
            let destination = min(
                targetIndex,
                updated.count
            )
            updated.insert(item, at: destination)
            applyItems(
                updated,
                isCompact: isCompact
            )
        }
    }

    private func toggleVisibility(id: String) {
        var updated = items
        guard let index = updated.firstIndex(
            where: { $0.id == id }
        ) else {
            return
        }
        withAnimation(settings.motion.animation(for: .itemChanges, reduceMotion: reduceMotion)) {
            updated[index].visible.toggle()
            applyItems(updated, isCompact: isCompact)
        }
    }
}

struct ProviderStatusRow: View {
    let status: PopoverStatusSectionData

    var body: some View {
        HStack(alignment: .top, spacing: AppDesign.Space.row) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: AppDesign.Space.micro) {
                Text(status.title)
                    .font(AppDesign.Typography.subheadline)
                if let message = status.message {
                    Text(message)
                        .font(AppDesign.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Text(statusText)
                .font(AppDesign.Typography.caption)
                .foregroundStyle(statusColor)
                .padding(.top, 1)
        }
        .padding(.vertical, AppDesign.Space.compact)
    }

    private var statusText: String {
        if let error = status.error {
            return error.compactStatusText
        }
        return status.statusText ?? "데이터 없음"
    }

    private var statusColor: Color {
        if let error = status.error {
            return error.compactStatusColor
        }
        return status.statusText == nil ? .secondary : .orange
    }
}

private extension APIError {
    var compactStatusText: String {
        if isDefinitiveAuthFailure {
            return "인증 필요"
        }
        if isPermissionDenied {
            return "권한 없음"
        }
        return "조회 실패"
    }

    var compactStatusColor: Color {
        (isDefinitiveAuthFailure || isPermissionDenied) ? .orange : .secondary
    }
}

struct CodexCreditsView: View {
    let credits: CodexCredits

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.row) {
            HStack {
                Text("Codex 크레딧")
                    .font(AppDesign.Typography.subheadline.weight(.semibold))
                Spacer()
                Text(credits.formattedBalance)
                    .font(AppDesign.Typography.headline)
                    .fontWeight(.semibold)
            }
            HStack {
                Text(credits.unlimited ? "무제한 플랜" : "사용 가능한 크레딧")
                    .font(AppDesign.Typography.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.vertical, AppDesign.Space.compact)
    }
}

struct CompactCodexCreditsRow: View {
    let credits: CodexCredits

    var body: some View {
        HStack(spacing: PopoverLayoutMetrics.compactRowSpacing) {
            Text("크레딧")
                .font(AppDesign.Typography.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: PopoverLayoutMetrics.compactRowLabelWidth, alignment: .leading)

            Text(credits.formattedBalance)
                .font(AppDesign.Typography.compactValue)
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

struct CodexResetCreditsView: View {
    let data: PopoverResetCreditsSectionData

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.compact) {
            HStack(spacing: AppDesign.Space.row) {
                Text("한도 초기화 크레딧")
                    .font(AppDesign.Typography.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(data.availableCount)개")
                    .font(AppDesign.Typography.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(data.availableCount > 0 ? Color.accentColor : .secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }

            if let expiryText {
                Text(expiryText)
                    .font(AppDesign.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, AppDesign.Space.tight)
    }

    /// "만료: 6일 3시간 후 (7/28(월))" — 주간 한도와 동일한 시간 표기 규칙(1일 이상은 분 생략)
    private var expiryText: String? {
        guard let iso = data.nextExpiresAtISO else { return nil }
        return TimeFormatter.formatRelativeTimeWithClockWeekly(
            from: iso,
            style: data.timeFormatStyle,
            label: "만료"
        )
    }
}

struct CompactCodexResetCreditsRow: View {
    let data: PopoverResetCreditsSectionData

    var body: some View {
        HStack(spacing: PopoverLayoutMetrics.compactRowSpacing) {
            Text("초기화 크레딧")
                .font(AppDesign.Typography.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: PopoverLayoutMetrics.compactRowLabelWidth, alignment: .leading)

            Text("\(data.availableCount)개")
                .font(AppDesign.Typography.compactValue)
                .fontWeight(.medium)
                .foregroundStyle(data.availableCount > 0 ? Color.accentColor : .secondary)
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
    var updatedAt: Date? = nil
    var isStale = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.compact) {
            HStack(spacing: AppDesign.Space.row) {
                Text(isStale ? "추가 사용량 · 이전 값" : "추가 사용량")
                    .font(AppDesign.Typography.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Text(String(format: "%.0f%%", overage.usagePercentage))
                    .font(AppDesign.Typography.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.purple)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Text(overage.formattedUsageLimitSummary)
                .font(AppDesign.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.vertical, AppDesign.Space.tight)
        .help(OverageDisplayDescription.text(overage: overage, updatedAt: updatedAt, isStale: isStale))
    }
}

struct CompactOverageRow: View {
    let overage: OverageSpendLimitResponse
    var updatedAt: Date? = nil
    var isStale = false

    var body: some View {
        HStack(alignment: .center, spacing: PopoverLayoutMetrics.compactRowSpacing) {
            Text(isStale ? "추가 사용 · 이전 값" : "추가 사용량")
                .font(AppDesign.Typography.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .truncationMode(.tail)
                .frame(width: PopoverLayoutMetrics.compactRowLabelWidth, alignment: .leading)

            HStack(spacing: AppDesign.Space.compact) {
                ProgressBarView(
                    percentage: overage.usagePercentage,
                    height: PopoverLayoutMetrics.compactProgressBarHeight,
                    color: .purple
                )
                .frame(maxWidth: .infinity)

                Text(String(format: "%.0f%%", overage.usagePercentage))
                    .font(AppDesign.Typography.compactValue)
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
        .help(OverageDisplayDescription.text(overage: overage, updatedAt: updatedAt, isStale: isStale))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("추가 사용량")
        .accessibilityValue(OverageDisplayDescription.text(overage: overage, updatedAt: updatedAt, isStale: isStale))
    }
}

private enum OverageDisplayDescription {
    static func text(overage: OverageSpendLimitResponse, updatedAt: Date?, isStale: Bool) -> String {
        var parts = [overage.formattedUsageLimitSummary]
        if isStale { parts.append("추가 사용량 갱신 실패 · 이전 값") }
        if let updatedAt { parts.append("마지막 확인: \(PopoverViewModel.relativeTimestamp(for: updatedAt))") }
        return parts.joined(separator: " · ")
    }
}
