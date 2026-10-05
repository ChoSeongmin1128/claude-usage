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
        .foregroundStyle(.secondary)
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
        .foregroundStyle(.secondary)
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
            .help(data.status == .executableNotFound ? ClaudeCodeCredentialIssue.executableNotFoundExplanation : "")
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: AppDesign.Space.control) {
                    Text(data.name).font(AppDesign.Typography.subheadline.weight(.semibold)).lineLimit(1)
                    if data.isRuntime { InUseAccountLabel() }
                    ForEach(data.badges, id: \.self) { AccountBadgeView(badge: $0) }
                    Spacer(minLength: 0)
                    statusText
                }
                statusOrGauges
            }
            .opacity(data.status == .archived || data.status == .loginExpired ? 0.55 : 1)
            .help(data.status == .executableNotFound ? ClaudeCodeCredentialIssue.executableNotFoundExplanation : "")
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
        case .executableNotFound where data.usage == nil:
            Text("Claude Code 없음").font(AppDesign.Typography.caption).foregroundStyle(.orange)
                .help(ClaudeCodeCredentialIssue.executableNotFoundExplanation)
        case .checking where data.usage == nil:
            Text("확인 중").font(AppDesign.Typography.caption).foregroundStyle(.secondary)
        case .failed:
            Text("확인 실패").font(AppDesign.Typography.caption).foregroundStyle(.orange)
        default:
            HStack(spacing: AppDesign.Space.row) {
                miniGauge(label: "5시간", window: data.usage?.fiveHour, isWeekly: false)
                miniGauge(label: "주간", window: data.usage?.weekly, isWeekly: true)
            }
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch data.status {
        case .stale:
            Text(Self.labeled(UsageStatusLabel.previousValue, since: data.fetchedAt))
                .font(AppDesign.Typography.caption2).foregroundStyle(.orange)
        case .archived:
            Text(Self.labeled("보관", since: data.fetchedAt))
                .font(AppDesign.Typography.caption2).foregroundStyle(.secondary)
        case .loginExpired:
            Text("로그인 만료").font(AppDesign.Typography.caption2).foregroundStyle(.red)
        case .executableNotFound where data.usage != nil:
            Text("Claude Code 없음").font(AppDesign.Typography.caption2).foregroundStyle(.orange)
                .help(ClaudeCodeCredentialIssue.executableNotFoundExplanation)
        default:
            EmptyView()
        }
    }

    private static func labeled(_ label: String, since date: Date?) -> String {
        date.map { "\(label) · \(TimeFormatter.elapsed(since: $0))" } ?? label
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
    private func miniGauge(label: String, window: UsageAccountUsage.Window?, isWeekly: Bool) -> some View {
        HStack(spacing: 4) {
            if !density.isCompact {
                Text(label).font(AppDesign.Typography.caption2).foregroundStyle(.secondary)
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
        .accessibilityLabel("\(label) \(window.map { data.basis.spokenValue(fromUsed: $0.usedPercent) } ?? "데이터 없음")")
    }
}
