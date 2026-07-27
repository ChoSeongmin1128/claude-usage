import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
        case .resetCredits(let resetCredits):
            if density.isCompact {
                CompactCodexResetCreditsRow(data: resetCredits)
            } else {
                CodexResetCreditsView(data: resetCredits)
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
                    .minimumScaleFactor(0.8)
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

enum PopoverDisplayEditorMode: String, CaseIterable, Identifiable {
    case standard
    case compact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard:
            return "일반 보기"
        case .compact:
            return "간소화 보기"
        }
    }

    var isCompact: Bool {
        self == .compact
    }

    var showsPersistentIdentityRail: Bool {
        self == .standard
    }
}

struct PopoverDisplayEditorView: View {
    @ObservedObject var settings: AppSettings
    let service: PopoverService
    @Binding var selectedMode: PopoverDisplayEditorMode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: modeSelection) {
                ForEach(PopoverDisplayEditorMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            PopoverDisplayItemsListView(
                settings: settings,
                service: service,
                isCompact: selectedMode.isCompact
            )
        }
        .padding(12)
        .frame(width: 280)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
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
    @State private var draggingItemID: String?

    private var items: [PopoverItemConfig] {
        isCompact
            ? settings.compactPopoverItems(for: service)
            : settings.popoverItems(for: service)
    }

    private var editableItems: [PopoverItemConfig] {
        service == .antigravity
            ? items.filter { $0.id != AntigravityItemCatalog.usageLimitsItemID }
            : items
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(editableItems.enumerated()), id: \.element.id) { displayIndex, item in
                if let index = items.firstIndex(where: { $0.id == item.id }) {
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .frame(width: 14)

                            Button {
                                var updated = items
                                updated[index].visible.toggle()
                                applyItems(updated, isCompact: isCompact)
                            } label: {
                                Image(systemName: item.visible ? "eye" : "eye.slash")
                                    .foregroundStyle(item.visible ? .primary : .tertiary)
                                    .font(.system(size: 12))
                                    .frame(width: 16, height: 16)
                            }
                            .buttonStyle(.borderless)
                            .help(item.visible ? "숨기기" : "보이기")
                            .accessibilityLabel("\(item.displayName) \(item.visible ? "숨기기" : "보이기")")

                            Text(item.displayName)
                                .font(.subheadline)
                                .foregroundStyle(item.visible ? .primary : .tertiary)

                            if unavailableItemIDs.contains(item.id) {
                                Text("지금 데이터 없음")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .help("현재 플랜/응답에는 이 항목의 데이터가 없어 팝오버에 표시되지 않습니다.")
                            }

                            Spacer()
                        }
                        .frame(height: 26)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())

                        if displayIndex < editableItems.count - 1 {
                            Divider().padding(.horizontal, 8)
                        }
                    }
                    .background(draggingItemID == item.id ? Color.accentColor.opacity(0.1) : Color.clear)
                    .cornerRadius(4)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(item.displayName)
                    .accessibilityValue(item.visible ? "표시 중" : "숨김")
                    .accessibilityAction(named: "위로 이동") {
                        moveItem(id: item.id, offset: -1)
                    }
                    .accessibilityAction(named: "아래로 이동") {
                        moveItem(id: item.id, offset: 1)
                    }
                    .onDrag {
                        draggingItemID = item.id
                        return NSItemProvider(object: item.id as NSString)
                    }
                    .onDrop(of: [UTType.text], delegate: PopoverItemDropDelegate(
                        targetID: item.id,
                        settings: settings,
                        isCompact: isCompact,
                        service: service,
                        reduceMotion: reduceMotion,
                        draggingItemID: $draggingItemID
                    ))
                }
            }
        }
        .padding(.vertical, 4)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.6))
        .cornerRadius(6)
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
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
            updated.swapAt(fromIndex, targetIndex)
            applyItems(updated, isCompact: isCompact)
        }
    }
}

private struct PopoverItemDropDelegate: DropDelegate {
    let targetID: String
    let settings: AppSettings
    let isCompact: Bool
    let service: PopoverService
    let reduceMotion: Bool
    @Binding var draggingItemID: String?

    func performDrop(info: DropInfo) -> Bool {
        draggingItemID = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggingID = draggingItemID, draggingID != targetID else { return }

        var items = isCompact
            ? settings.compactPopoverItems(for: service)
            : settings.popoverItems(for: service)
        guard let fromIndex = items.firstIndex(where: { $0.id == draggingID }),
              let toIndex = items.firstIndex(where: { $0.id == targetID }) else { return }

        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
            let offset = toIndex > fromIndex ? toIndex + 1 : toIndex
            items.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: offset)
            if isCompact {
                settings.setCompactPopoverItems(items, for: service)
            } else {
                settings.setPopoverItems(items, for: service)
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

struct ProviderStatusRow: View {
    let status: PopoverStatusSectionData

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(status.title)
                    .font(.subheadline)
                if let message = status.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Text(statusText)
                .font(.caption)
                .foregroundStyle(statusColor)
                .padding(.top, 1)
        }
        .padding(.vertical, 4)
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

struct CodexResetCreditsView: View {
    let data: PopoverResetCreditsSectionData

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.counterclockwise.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .center)
                Text("한도 초기화 크레딧")
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(data.availableCount)개")
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(data.availableCount > 0 ? Color.accentColor : .secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }

            if let expiryText {
                Text(expiryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 2)
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
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: PopoverLayoutMetrics.compactRowLabelWidth, alignment: .leading)

            Text("\(data.availableCount)개")
                .font(.system(.caption, design: .monospaced))
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

            Text(overage.formattedUsageLimitSummary)
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
            Text("추가 사용량")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
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
