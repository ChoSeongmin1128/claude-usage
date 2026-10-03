import SwiftUI

/// 여러 계정 줄에서 누를 수 있는 동작. 팝오버가 환경으로 넘긴다.
struct PopoverAccountActions {
    var toggle: (PopoverService, String) -> Void = { _, _ in }
    var showInMenuBar: (PopoverService, String) -> Void = { _, _ in }
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

struct AccountBadgeView: View {
    let badge: UsageAccountBadge
    let service: PopoverService

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(badge == .inUse ? Color.green : Color.secondary.opacity(0.6)).frame(width: 5, height: 5)
            Text(badge.title)
        }
        .font(AppDesign.Typography.caption2)
        .foregroundStyle(.secondary)
        .help(badge.help(for: service) ?? "")
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
                        if data.selectsMenuBarAccount {
                            actions.showInMenuBar(data.service, chip.id)
                        } else {
                            actions.toggle(data.service, chip.id)
                        }
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

struct OtherAccountRow: View {
    let data: PopoverAccountRowData
    let density: PopoverDensity
    @Environment(\.popoverAccountActions) private var actions

    var body: some View {
        if density.isCompact {
            HStack(spacing: PopoverLayoutMetrics.compactRowSpacing) {
                Text(data.name)
                    .font(AppDesign.Typography.caption.weight(.semibold))
                    .foregroundStyle(data.status == .current ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                statusOrGauges.layoutPriority(1)
            }
            .opacity(data.status == .archived || data.status == .loginExpired ? 0.55 : 1)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: AppDesign.Space.control) {
                    Text(data.name).font(AppDesign.Typography.subheadline.weight(.semibold)).lineLimit(1)
                    ForEach(data.badges, id: \.self) { AccountBadgeView(badge: $0, service: data.service) }
                    Spacer(minLength: 0)
                    statusText
                }
                statusOrGauges
            }
            .opacity(data.status == .archived || data.status == .loginExpired ? 0.55 : 1)
        }
    }

    @ViewBuilder
    private var statusOrGauges: some View {
        switch data.status {
        case .loginExpired:
            Button("다시 로그인") { actions.reconnect(data.service, data.id) }
                .buttonStyle(.link).font(AppDesign.Typography.caption)
        case .needsPermission:
            Button("허용") { actions.allow(data.service, data.id) }
                .buttonStyle(.link).font(AppDesign.Typography.caption)
                .help("macOS 확인 창에서 \"항상 허용\"을 누르면 다시 묻지 않습니다")
        case .checking where data.fiveHour == nil && data.weekly == nil:
            Text("확인 중").font(AppDesign.Typography.caption).foregroundStyle(.secondary)
        default:
            HStack(spacing: AppDesign.Space.row) {
                miniGauge(label: "5시간", value: data.fiveHour, resetAt: data.fiveHourResetAt, isWeekly: false)
                miniGauge(label: "주간", value: data.weekly, resetAt: data.weeklyResetAt, isWeekly: true)
            }
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch data.status {
        case .stale:
            Text(data.fetchedAt.map { "오래된 값 · \(Self.age(since: $0))" } ?? "오래된 값")
                .font(AppDesign.Typography.caption2).foregroundStyle(.orange)
        case .archived:
            Text(data.fetchedAt.map { "보관 · \(Self.age(since: $0))" } ?? "보관")
                .font(AppDesign.Typography.caption2).foregroundStyle(.secondary)
        case .loginExpired:
            Text("로그인 만료").font(AppDesign.Typography.caption2).foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    /// 다른 계정 줄은 초기화 시각을 빼고, 다 쓴 창만 언제 풀리는지 보여준다.
    @ViewBuilder
    private func miniGauge(label: String, value: Double?, resetAt: String?, isWeekly: Bool) -> some View {
        HStack(spacing: 4) {
            if !density.isCompact {
                Text(label).font(AppDesign.Typography.caption2).foregroundStyle(.secondary)
            }
            if let value {
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
                    if value >= 100, let resetAt, let date = TimeFormatter.parseISO8601(resetAt) {
                        Text(
                            TimeFormatter.formatRemaining(
                                until: date, style: AppSettings.shared.timeFormat, isWeekly: isWeekly)
                        )
                        .foregroundStyle(.red)
                    } else {
                        Text(data.basis.text(fromUsed: value)).foregroundStyle(.secondary)
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
        .accessibilityLabel("\(label) \(value.map { data.basis.spokenValue(fromUsed: $0) } ?? "데이터 없음")")
    }

    static func age(since date: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 1 { return "방금" }
        if minutes < 60 { return "\(minutes)분 전" }
        if minutes < 1440 { return "\(minutes / 60)시간 전" }
        return "\(minutes / 1440)일 전"
    }
}
