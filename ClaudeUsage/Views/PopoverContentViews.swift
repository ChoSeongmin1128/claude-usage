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
    let message: String?
    let actionTitle: String?
    let actionStyle: StatusPanelActionStyle
    let action: (() -> Void)?
    var isActionEnabled = true

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

            if let message {
                Text(message)
                    .font(density.isCompact ? .system(size: 10, weight: .medium) : .subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(
                        maxHeight: density.isCompact ? PopoverLayoutMetrics.compactStatusMessageHeight : nil,
                        alignment: .topLeading)
            }
        }
        .help(message.map { "\(title)\n\($0)" } ?? title)
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
                .disabled(!isActionEnabled)
        } else {
            Button(title, action: action)
                .buttonStyle(.bordered)
                .controlSize(density.isCompact ? .small : .regular)
                .disabled(!isActionEnabled)
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
                    timeUnitLanguage: usage.timeUnitLanguage,
                    basis: usage.basis
                )
            } else {
                UsageSectionView(
                    title: usage.title,
                    percentage: usage.percentage,
                    resetAt: usage.resetAt,
                    isWeekly: usage.isWeekly,
                    timeFormatStyle: usage.timeFormatStyle,
                    timeUnitLanguage: usage.timeUnitLanguage,
                    basis: usage.basis
                )
            }
        case .credits(let credits):
            if density.isCompact {
                CompactCodexCreditsRow(credits: credits.credits)
            } else {
                CodexCreditsView(credits: credits.credits, rateCardURL: credits.rateCardURL)
            }
        case .resetCredits(let resetCredits):
            if density.isCompact {
                CompactResetCreditsRow(data: resetCredits)
            } else {
                ResetCreditsView(data: resetCredits)
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
        case .accountPicker(let picker):
            AccountPickerRow(data: picker, density: density)
        case .accountRow(let row):
            OtherAccountRow(data: row, density: density)
        case .accountSummary(let summary):
            Text(summary.text)
                .font(AppDesign.Typography.caption.weight(summary.isWarning ? .semibold : .regular))
                .foregroundStyle(summary.isWarning ? Color.orange : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
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
            DisplayModePicker(selection: $selectedMode)

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
            return "로그인 필요"
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

private struct PopoverFixedRowHeight: ViewModifier {
    let height: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .center)
    }
}

private extension CodexCredits {
    var popoverBalanceText: String {
        let unit = " 크레딧"
        return formattedBalance.hasSuffix(unit)
            ? String(formattedBalance.dropLast(unit.count)) : formattedBalance
    }
}

struct CodexCreditsView: View {
    let credits: CodexCredits
    var rateCardURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.tight) {
            HStack {
                Text("크레딧")
                    .font(AppDesign.Typography.subheadline.weight(.semibold))
                Spacer(minLength: AppDesign.Space.row)
                Text(credits.popoverBalanceText)
                    .font(AppDesign.Typography.headline.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .accessibilityLabel(credits.formattedBalance)
            }
            HStack {
                Text(credits.unlimited ? "무제한 플랜" : "사용 가능")
                    .font(AppDesign.Typography.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: AppDesign.Space.row)
                if let rateCardURL {
                    Link("요금표", destination: rateCardURL)
                        .font(AppDesign.Typography.caption)
                        .help("작업별 크레딧 사용량(OpenAI 도움말)")
                }
            }
        }
        .modifier(PopoverFixedRowHeight(height: PopoverLayoutMetrics.standardCreditsRowHeight))
        .help(credits.formattedBalance)
    }
}

struct CompactCodexCreditsRow: View {
    let credits: CodexCredits

    var body: some View {
        HStack(spacing: PopoverLayoutMetrics.compactRowSpacing) {
            Text("크레딧")
                .font(AppDesign.Typography.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: PopoverLayoutMetrics.compactRowLabelWidth, alignment: .leading)

            Text(credits.popoverBalanceText)
                .font(AppDesign.Typography.compactValue)
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: PopoverLayoutMetrics.compactRowMeterWidth, alignment: .trailing)
        }
        .modifier(PopoverFixedRowHeight(height: PopoverLayoutMetrics.compactCreditsRowHeight))
        .help(credits.formattedBalance)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("크레딧")
        .accessibilityValue(credits.formattedBalance)
    }
}

struct ResetCreditsView: View {
    let data: PopoverResetCreditsSectionData

    var body: some View {
        let summary = data.summary
        let expiring = summary.isExpiringSoon()
        HStack(spacing: AppDesign.Space.label) {
            VStack(alignment: .leading, spacing: AppDesign.Space.tight) {
                Text("초기화권")
                    .font(AppDesign.Typography.subheadline.weight(.semibold))
                    .lineLimit(1)
                if summary.availableCount > 0 {
                    Text(summary.expiryText() ?? "만료 미확인")
                        .font(AppDesign.Typography.caption)
                        .foregroundStyle(expiring ? Color.red : .secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: AppDesign.Space.row) {
                ResetCreditScopeText(data: data)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ResetCreditCountText(summary: summary, expiring: expiring, compact: false, isNew: data.isNew)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(width: PopoverLayoutMetrics.standardRowMeterWidth, alignment: .trailing)
        }
        .modifier(PopoverFixedRowHeight(height: PopoverLayoutMetrics.standardSecondaryUsageRowHeight))
        .help(ResetCreditDisplayDescription.tooltip(data))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("초기화권")
        .accessibilityValue(ResetCreditDisplayDescription.value(data))
    }
}

struct CompactResetCreditsRow: View {
    let data: PopoverResetCreditsSectionData

    var body: some View {
        let summary = data.summary
        let expiring = summary.isExpiringSoon()
        HStack(spacing: PopoverLayoutMetrics.compactRowSpacing) {
            HStack(spacing: AppDesign.Space.tight) {
                Text("초기화권")
                    .font(AppDesign.Typography.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .truncationMode(.tail)
                if summary.availableCount > 0 {
                    let expiry =
                        summary.expiryText()?.replacingOccurrences(of: " 뒤 만료", with: "")
                        ?? "만료 미확인"
                    Text("· " + expiry)
                        .font(AppDesign.Typography.metadata)
                        .foregroundStyle(expiring ? Color.red : .secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(width: PopoverLayoutMetrics.compactRowLabelWidth, alignment: .leading)

            HStack(spacing: AppDesign.Space.compact) {
                ResetCreditScopeText(data: data)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ResetCreditCountText(summary: summary, expiring: expiring, compact: true, isNew: data.isNew)
                    .frame(width: PopoverLayoutMetrics.compactPercentageLabelWidth, alignment: .trailing)
            }
            .frame(width: PopoverLayoutMetrics.compactRowMeterWidth, alignment: .trailing)
        }
        .modifier(PopoverFixedRowHeight(height: PopoverLayoutMetrics.compactCreditsRowHeight))
        .help(ResetCreditDisplayDescription.tooltip(data))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("초기화권")
        .accessibilityValue(ResetCreditDisplayDescription.value(data))
    }
}

private struct ResetCreditScopeText: View {
    let data: PopoverResetCreditsSectionData

    var body: some View {
        Text(text)
            .font(AppDesign.Typography.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }

    private var text: String {
        guard data.summary.availableCount > 0 else { return "" }
        let scope = data.summary.items.first?.scope.title ?? ResetCreditSummary.Scope.all.title
        return data.isNew ? "\(scope) 신규" : scope
    }
}

private enum ResetCreditDisplayDescription {
    static func value(_ data: PopoverResetCreditsSectionData) -> String {
        let summary = data.summary
        var parts = ["\(summary.availableCount)개"]
        if summary.availableCount > 0 {
            parts.append(summary.scopeText)
            if data.isNew { parts.append("신규") }
            if summary.isExpiringSoon() { parts.append("곧 만료") }
            parts.append(summary.expiryText() ?? "만료 시각 미확인")
            if summary.atLimit { parts.append("쓰면 한도가 다시 채워집니다") }
        }
        return parts.joined(separator: ", ")
    }

    static func tooltip(_ data: PopoverResetCreditsSectionData) -> String {
        [data.summary.items.first?.serverTitle, value(data)].compactMap { $0 }.joined(separator: "\n")
    }
}

private struct ResetCreditCountText: View {
    let summary: ResetCreditSummary
    let expiring: Bool
    let compact: Bool
    let isNew: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppDesign.Space.micro) {
            Text("\(summary.availableCount)개")
                .font(compact ? AppDesign.Typography.compactValue : AppDesign.Typography.headline)
                .foregroundStyle(expiring ? Color.red : isNew && summary.availableCount > 0 ? .blue : .primary)
            Text("남음")
                .font(AppDesign.Typography.caption2)
                .foregroundStyle(.secondary)
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .accessibilityLabel("초기화권 \(summary.availableCount)개 남음")
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
                Text(overage.headlineText)
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
            Text(isStale ? "추가 사용량 · 이전 값" : "추가 사용량")
                .font(AppDesign.Typography.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .truncationMode(.tail)
                .frame(width: PopoverLayoutMetrics.compactRowLabelWidth, alignment: .leading)

            HStack(spacing: AppDesign.Space.compact) {
                ProgressBarView(
                    percentage: overage.usagePercentage ?? 0,
                    height: PopoverLayoutMetrics.compactProgressBarHeight,
                    color: .purple
                )
                .frame(maxWidth: .infinity)

                Text(overage.headlineText)
                    .font(AppDesign.Typography.compactValue)
                    .fontWeight(.medium)
                    .foregroundStyle(.purple)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: PopoverLayoutMetrics.compactPercentageLabelWidth, alignment: .trailing)
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
