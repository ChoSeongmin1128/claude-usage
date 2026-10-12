import SwiftUI

/// 여러 계정 줄에서 누를 수 있는 동작. 팝오버가 환경으로 넘긴다.
struct PopoverAccountActions {
    var toggle: (PopoverService, String) -> Void = { _, _ in }
    var reconnect: (PopoverService, String) -> Void = { _, _ in }
    var allow: (PopoverService, String) -> Void = { _, _ in }
}

private struct PopoverAccountActionsKey: EnvironmentKey {
    static let defaultValue = PopoverAccountActions()
}

extension EnvironmentValues {
    var popoverAccountActions: PopoverAccountActions {
        get { self[PopoverAccountActionsKey.self] }
        set { self[PopoverAccountActionsKey.self] = newValue }
    }
}

/// 계정이 어디서 왔는지(기본 로그인, CLI, 웹). 설명은 서비스마다 다르다.
struct AccountBadge: Hashable {
    let title: String
    let help: String
}

struct AccountBadgeView: View {
    let badge: AccountBadge

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(Color.secondary.opacity(0.6)).frame(width: 5, height: 5)
            Text(badge.title)
        }
        .font(AppDesign.Typography.caption2)
        .foregroundStyle(AppDesign.Text.secondary)
        .help(badge.help)
    }
}

/// 메뉴바와 팝오버 큰 카드가 쓰는 계정. 출처 배지(기본 로그인, CLI, 웹)와 따로 붙인다.
struct InUseAccountLabel: View {
    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(Color.green).frame(width: 5, height: 5)
            Text("사용 중")
        }
        .font(AppDesign.Typography.caption2)
        .foregroundStyle(AppDesign.Text.secondary)
        .help("메뉴바와 팝오버에 나오는 계정")
    }
}

struct AccountPickerRow: View {
    let data: PopoverAccountPickerData
    let density: PopoverDensity
    @Environment(\.popoverAccountActions) private var actions

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppDesign.Space.control) {
                ForEach(data.chips) { chip in
                    Button {
                        actions.toggle(data.service, chip.id)
                    } label: {
                        Text(chip.name)
                            .font(density.isCompact ? AppDesign.Typography.caption2 : AppDesign.Typography.caption)
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, density.isCompact ? 1 : 3)
                            .background(
                                chip.isSelected ? Color.accentColor.opacity(0.18) : AppDesign.Surface.group,
                                in: Capsule()
                            )
                            .foregroundStyle(chip.isSelected ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chip.isSelected ? .isSelected : [])
                }
            }
        }
    }
}

nonisolated struct OtherAccountStatusPresentation: Equatable {
    let status: UsageAccountState.Status
    let lastSuccessAge: String?

    init(status: UsageAccountState.Status, fetchedAt: Date?, now: Date = Date()) {
        self.status = status
        if let fetchedAt, TimeFormatter.validatedResetDate(fetchedAt) != nil,
            TimeFormatter.validatedResetDate(now) != nil
        {
            lastSuccessAge = TimeFormatter.elapsed(since: fetchedAt, now: now)
        } else {
            lastSuccessAge = nil
        }
    }

    var stateLabel: String {
        switch status {
        case .current: "현재 값"
        case .stale: UsageStatusLabel.previousValue
        case .archived: "보관"
        case .checking: "확인 중"
        case .failed: "확인 실패"
        case .loginExpired: "로그인 만료"
        case .needsPermission: "허용 필요"
        case .executableNotFound: "Claude Code 없음"
        }
    }

    var compactText: String? {
        switch status {
        case .stale, .archived:
            lastSuccessAge.map { "\(stateLabel) / \($0)" } ?? stateLabel
        default:
            nil
        }
    }

    func generalText(hasUsage: Bool) -> String? {
        switch status {
        case .stale, .archived: compactText
        case .loginExpired: stateLabel
        case .executableNotFound where hasUsage: stateLabel
        default: nil
        }
    }

    var accessibilityState: String {
        let confirmation = lastSuccessAge.map { "마지막 성공 확인 \($0)" } ?? "마지막 성공 확인 시각 미확인"
        return "\(stateLabel), \(confirmation)"
    }

    func accountAccessibilityLabel(name: String) -> String {
        "\(name), \(accessibilityState)"
    }

    func quotaAccessibilityLabel(
        accountName: String, label: String, window: UsageAccountUsage.Window?, basis: UsageValueBasis
    ) -> String {
        let value = window.map { basis.spokenValue(fromUsed: $0.usedPercent) } ?? "데이터 없음"
        return "\(accountName), \(label) \(value), \(accessibilityState)"
    }
}

struct OtherAccountRow: View {
    let data: PopoverAccountRowData
    let density: PopoverDensity
    @Environment(\.popoverAccountActions) private var actions

    var body: some View {
        let presentation = OtherAccountStatusPresentation(status: data.status, fetchedAt: data.fetchedAt)
        if density.isCompact {
            HStack(spacing: PopoverLayoutMetrics.compactRowSpacing) {
                VStack(alignment: .leading, spacing: AppDesign.Space.tight) {
                    accountName(presentation)
                    if let text = presentation.compactText {
                        metadata(text)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                statusOrGauges(presentation).layoutPriority(1)
            }
            .opacity(data.status == .archived || data.status == .loginExpired ? 0.55 : 1)
            .help(data.status == .executableNotFound ? ClaudeCodeCredentialIssue.executableNotFoundExplanation : "")
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: AppDesign.Space.control) {
                    accountName(presentation)
                    if data.isRuntime { InUseAccountLabel() }
                    ForEach(data.badges, id: \.self) { AccountBadgeView(badge: $0) }
                    Spacer(minLength: 0)
                    if let text = presentation.generalText(hasUsage: data.usage != nil) {
                        metadata(text)
                    }
                }
                statusOrGauges(presentation)
            }
            .opacity(data.status == .archived || data.status == .loginExpired ? 0.55 : 1)
            .help(data.status == .executableNotFound ? ClaudeCodeCredentialIssue.executableNotFoundExplanation : "")
        }
    }

    private func accountName(_ presentation: OtherAccountStatusPresentation) -> some View {
        Text(data.name)
            .font(
                density.isCompact
                    ? AppDesign.Typography.caption.weight(.semibold)
                    : AppDesign.Typography.subheadline.weight(.semibold)
            )
            .foregroundStyle(density.isCompact && data.status != .current ? .secondary : .primary)
            .lineLimit(1)
            .truncationMode(density.isCompact ? .middle : .tail)
            .accessibilityLabel(presentation.accountAccessibilityLabel(name: data.name))
    }

    private func metadata(_ text: String) -> some View {
        Text(text)
            .font(AppDesign.Typography.metadata)
            .foregroundStyle(metadataColor)
            .fixedSize(horizontal: false, vertical: true)
            .help(data.status == .executableNotFound ? ClaudeCodeCredentialIssue.executableNotFoundExplanation : "")
            .accessibilityHidden(true)
    }

    private var metadataColor: Color {
        switch data.status {
        case .stale, .executableNotFound: .orange
        case .loginExpired: .red
        default: AppDesign.Text.secondary
        }
    }

    @ViewBuilder
    private func statusOrGauges(_ presentation: OtherAccountStatusPresentation) -> some View {
        switch data.status {
        case .loginExpired:
            Button("다시 로그인") { actions.reconnect(data.service, data.id) }
                .buttonStyle(.link).font(AppDesign.Typography.caption)
        case .needsPermission:
            Button("허용") { actions.allow(data.service, data.id) }
                .buttonStyle(.link).font(AppDesign.Typography.caption)
                .help("macOS 확인 창에서 \"항상 허용\"을 누르면 다시 묻지 않습니다")
        case .executableNotFound where data.usage == nil:
            Text("Claude Code 없음").font(AppDesign.Typography.caption).foregroundStyle(.orange)
                .help(ClaudeCodeCredentialIssue.executableNotFoundExplanation)
        case .checking where data.usage == nil:
            Text("확인 중").font(AppDesign.Typography.caption).foregroundStyle(AppDesign.Text.secondary)
        case .failed:
            Text("확인 실패").font(AppDesign.Typography.caption).foregroundStyle(.orange)
        default:
            HStack(spacing: AppDesign.Space.row) {
                miniGauge(label: "5시간", window: data.usage?.fiveHour, isWeekly: false, presentation: presentation)
                miniGauge(label: "주간", window: data.usage?.weekly, isWeekly: true, presentation: presentation)
            }
        }
    }

    func exhaustedQuotaText(
        for window: UsageAccountUsage.Window, isWeekly: Bool, now: Date = Date()
    ) -> String? {
        guard window.usedPercent >= 100, let resetsAt = window.resetsAt else { return nil }
        return TimeFormatter.formatRemaining(
            until: resetsAt, now: now, isWeekly: isWeekly)
    }

    /// 다른 계정 줄은 초기화 시각을 빼고, 다 쓴 한도만 언제 풀리는지 보여준다.
    @ViewBuilder
    private func miniGauge(
        label: String, window: UsageAccountUsage.Window?, isWeekly: Bool,
        presentation: OtherAccountStatusPresentation
    ) -> some View {
        HStack(spacing: 4) {
            if !density.isCompact {
                Text(label).font(AppDesign.Typography.caption2).foregroundStyle(AppDesign.Text.secondary)
            }
            if let window {
                let value = window.usedPercent
                let shown = min(max(data.basis.percentage(fromUsed: value) ?? 0, 0), 100)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.18))
                        Capsule().fill(ColorProvider.statusColor(for: value))
                            .frame(width: geometry.size.width * shown / 100)
                    }
                }
                .frame(width: density.isCompact ? 34 : 64, height: 5)
                Group {
                    if let resetText = exhaustedQuotaText(for: window, isWeekly: isWeekly) {
                        Text(resetText).foregroundStyle(.red)
                    } else {
                        Text(data.basis.text(fromUsed: value)).foregroundStyle(AppDesign.Text.secondary)
                    }
                }
                .font(AppDesign.Typography.caption2.monospacedDigit())
                .lineLimit(1)
                .frame(width: density.isCompact ? 40 : 52, alignment: .leading)
            } else {
                Text("—").font(AppDesign.Typography.caption2).foregroundStyle(.tertiary)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            presentation.quotaAccessibilityLabel(
                accountName: data.name, label: label, window: window, basis: data.basis))
    }
}
