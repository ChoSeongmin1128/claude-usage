//
//  PopoverView.swift
//  ClaudeUsage
//
//  Phase 2: 메인 Popover UI
//

import SwiftUI
import Combine

struct PopoverView: View {
    @ObservedObject var viewModel: PopoverViewModel
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 상단 바
            HStack(spacing: 6) {
                Text("Claude 사용량")
                    .font(.headline)

                // 새로고침 (제목 옆)
                Button(action: { viewModel.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .frame(width: 14, height: 14)
                        .rotationEffect(.degrees(viewModel.isLoading ? 360 : 0))
                        .animation(viewModel.isLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: viewModel.isLoading)
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isLoading)

                Spacer()

                if let lastUpdated = viewModel.lastUpdated {
                    Text(lastUpdated, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                // 간소화 토글
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        settings.popoverCompact.toggle()
                    }
                } label: {
                    Image(systemName: settings.popoverCompact ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help(settings.popoverCompact ? "기본 보기" : "간소화")

                // 고정 핀
                Button {
                    settings.popoverPinned.toggle()
                    viewModel.onPinChanged?(settings.popoverPinned)
                } label: {
                    Image(systemName: settings.popoverPinned ? "pin.fill" : "pin")
                        .font(.system(size: 12))
                        .foregroundColor(settings.popoverPinned ? .accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help(settings.popoverPinned ? "고정 해제" : "고정")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // 시스템 상태 배너 (장애 시에만 표시)
            if let status = viewModel.systemStatus, status.hasIssue {
                Divider()
                Button {
                    if let url = URL(string: "https://status.claude.com") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(statusColor(for: status.indicator))
                        Text(status.indicator.displayText)
                            .font(.caption)
                            .foregroundColor(.primary)
                        Spacer()
                        Text("상세보기")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(statusColor(for: status.indicator).opacity(0.08))
                }
                .buttonStyle(.plain)
            }

            // 업데이트 배너
            if let update = settings.availableUpdate {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundColor(.accentColor)
                    Text("v\(update.version) 업데이트 가능")
                        .font(.caption)
                    Spacer()
                    Button("다운로드") {
                        viewModel.downloadLatestRelease()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.08))
            }

            Divider()

            if viewModel.isLoading && viewModel.usage == nil {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("데이터 로딩 중...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: settings.popoverCompact ? 60 : 150)

            } else if let error = viewModel.error, viewModel.usage == nil {
                ErrorSectionView(error: error) {
                    viewModel.refresh()
                }
                .padding(16)

            } else if let usage = viewModel.usage {
                if settings.popoverCompact {
                    compactContent(usage: usage)
                } else {
                    standardContent(usage: usage)
                }

            } else {
                VStack {
                    Text("데이터 없음")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: settings.popoverCompact ? 40 : 100)
            }

            Divider()

            // 하단 버튼
            HStack {
                Button {
                    viewModel.openUsagePage()
                } label: {
                    Image(systemName: "safari")
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("claude.ai/settings/usage")

                if !settings.popoverCompact {
                    Button {
                        viewModel.openUsagePage()
                    } label: {
                        Text("claude.ai/settings/usage")
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }

                Spacer()

                Button {
                    viewModel.openSettings()
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "gearshape")
                        if !settings.popoverCompact { Text("설정") }
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "power")
                        if !settings.popoverCompact { Text("종료") }
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, settings.popoverCompact ? 6 : 8)

            if !settings.popoverCompact {
                HStack(spacing: 8) {
                    Text("⌘R 새로고침")
                    Text("⌘, 설정")
                }
                .font(.system(size: 10))
                .foregroundStyle(.quaternary)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 6)
            }
        }
        .frame(width: settings.popoverCompact ? 300 : 340)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Helpers

    private func statusColor(for indicator: StatusIndicator) -> Color {
        switch indicator {
        case .none: return .green
        case .minor: return .yellow
        case .major: return .orange
        case .critical: return .red
        }
    }

    // MARK: - Standard Content

    @ViewBuilder
    private func standardContent(usage: ClaudeUsageResponse) -> some View {
        let visibleItems = settings.popoverItems.filter { $0.visible }
        VStack(spacing: 12) {
            ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider() }
                switch item.id {
                case "currentSession":
                    UsageSectionView(
                        systemIcon: "gauge.medium",
                        title: "현재 세션",
                        percentage: usage.fiveHour.utilization,
                        resetAt: usage.fiveHour.resetsAt
                    )
                case "weeklyLimit":
                    if let sevenDay = usage.sevenDay {
                        UsageSectionView(
                            systemIcon: "calendar",
                            title: "주간 한도",
                            percentage: sevenDay.utilization,
                            resetAt: sevenDay.resetsAt,
                            isWeekly: true
                        )
                    }
                case "modelUsage":
                    if let sonnet = usage.sevenDaySonnet {
                        UsageSectionView(
                            systemIcon: "bolt.fill",
                            title: "Sonnet (주간)",
                            percentage: sonnet.utilization,
                            resetAt: sonnet.resetsAt,
                            isWeekly: true
                        )
                    }
                    if let opus = usage.sevenDayOpus {
                        if usage.sevenDaySonnet != nil { Divider() }
                        UsageSectionView(
                            systemIcon: "diamond.fill",
                            title: "Opus (주간)",
                            percentage: opus.utilization,
                            resetAt: opus.resetsAt,
                            isWeekly: true
                        )
                    }
                case "overageUsage":
                    if let overage = viewModel.overage, overage.isEnabled {
                        OverageUsageView(overage: overage)
                    }
                case "codexPrimary":
                    if let codex = viewModel.codexUsage, let window = codex.rateLimit?.primaryWindow {
                        UsageSectionView(
                            systemIcon: "bubble.left.and.bubble.right",
                            title: "Codex 현재",
                            percentage: window.utilization,
                            resetAt: window.resetAtISO
                        )
                    }
                case "codexSecondary":
                    if let codex = viewModel.codexUsage, let window = codex.rateLimit?.secondaryWindow {
                        UsageSectionView(
                            systemIcon: "calendar.badge.clock",
                            title: "Codex 주간",
                            percentage: window.utilization,
                            resetAt: window.resetAtISO,
                            isWeekly: true
                        )
                    }
                case "codexCredits":
                    if let codex = viewModel.codexUsage, let credits = codex.credits {
                        CodexCreditsView(credits: credits)
                    }
                default:
                    EmptyView()
                }
            }
        }
        .padding(16)
    }

    // MARK: - Compact Content

    @ViewBuilder
    private func compactContent(usage: ClaudeUsageResponse) -> some View {
        VStack(spacing: 5) {
            ForEach(settings.effectiveCompactItems.filter { $0.visible }, id: \.id) { item in
                switch item.id {
                case "currentSession":
                    CompactUsageRow(label: "현재", percentage: usage.fiveHour.utilization, resetAt: usage.fiveHour.resetsAt)
                case "weeklyLimit":
                    if let sevenDay = usage.sevenDay {
                        CompactUsageRow(label: "주간", percentage: sevenDay.utilization, resetAt: sevenDay.resetsAt, isWeekly: true)
                    }
                case "modelUsage":
                    if let sonnet = usage.sevenDaySonnet {
                        CompactUsageRow(label: "Sonnet", percentage: sonnet.utilization, resetAt: sonnet.resetsAt, isWeekly: true)
                    }
                    if let opus = usage.sevenDayOpus {
                        CompactUsageRow(label: "Opus", percentage: opus.utilization, resetAt: opus.resetsAt, isWeekly: true)
                    }
                case "overageUsage":
                    if let overage = viewModel.overage, overage.isEnabled {
                        CompactOverageRow(overage: overage)
                    }
                case "codexPrimary":
                    if let codex = viewModel.codexUsage, let window = codex.rateLimit?.primaryWindow {
                        CompactUsageRow(label: "CX현재", percentage: window.utilization, resetAt: window.resetAtISO)
                    }
                case "codexSecondary":
                    if let codex = viewModel.codexUsage, let window = codex.rateLimit?.secondaryWindow {
                        CompactUsageRow(label: "CX주간", percentage: window.utilization, resetAt: window.resetAtISO, isWeekly: true)
                    }
                case "codexCredits":
                    if let codex = viewModel.codexUsage, let credits = codex.credits {
                        CompactCodexCreditsRow(credits: credits)
                    }
                default:
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Compact Usage Row

struct CompactUsageRow: View {
    let label: String
    let percentage: Double
    var resetAt: String? = nil
    var isWeekly: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(ColorProvider.statusColor(for: percentage))
                        .frame(width: geo.size.width * min(percentage, 100) / 100)
                }
            }
            .frame(height: 6)

            Text(String(format: "%.0f%%", percentage))
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)
                .foregroundStyle(ColorProvider.statusColor(for: percentage))
                .frame(width: 34, alignment: .trailing)

            Text(compactResetText ?? "")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(width: 72, alignment: .trailing)
        }
    }

    private var compactResetText: String? {
        guard let resetAt = resetAt else { return nil }
        let style = AppSettings.shared.timeFormat
        if isWeekly {
            return TimeFormatter.formatResetTimeWeekly(from: resetAt, style: style)
        }
        // 현재 세션(5시간)은 날짜 없이 시간만 표시
        return TimeFormatter.formatResetTime(from: resetAt, style: style, includeDateIfNotToday: false)
    }
}

// MARK: - Error Section

struct ErrorSectionView: View {
    let error: APIError
    let retryAction: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)

            Text("데이터를 가져올 수 없습니다")
                .font(.headline)

            Text(error.errorDescription ?? "알 수 없는 오류")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("다시 시도") {
                    retryAction()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - ViewModel

class PopoverViewModel: ObservableObject {
    @Published var usage: ClaudeUsageResponse?
    @Published var error: APIError?
    @Published var isLoading: Bool = false
    @Published var lastUpdated: Date?
    @Published var overage: OverageSpendLimitResponse?
    @Published var systemStatus: ClaudeSystemStatus?
    @Published var codexUsage: CodexUsageResponse?
    @Published var codexError: APIError?
    var onRefresh: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onPinChanged: ((Bool) -> Void)?

    func refresh() {
        onRefresh?()
    }

    func openSettings() {
        onOpenSettings?()
    }

    func openUsagePage() {
        if let url = URL(string: "https://claude.ai/settings/usage") {
            NSWorkspace.shared.open(url)
        }
    }

    func downloadLatestRelease() {
        Task {
            let url = await UpdateService.shared.latestDownloadURL()
            NSWorkspace.shared.open(url)
        }
    }

    func update(usage: ClaudeUsageResponse?, error: APIError?, isLoading: Bool, lastUpdated: Date? = nil, overage: OverageSpendLimitResponse? = nil) {
        self.usage = usage
        self.error = error
        self.isLoading = isLoading
        if let lastUpdated { self.lastUpdated = lastUpdated }
        if let overage { self.overage = overage }
    }
}

// MARK: - Overage Usage View (Standard)

struct OverageUsageView: View {
    let overage: OverageSpendLimitResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "creditcard")
                    .foregroundStyle(.secondary)
                Text("추가 사용량")
                    .font(.headline)
                Spacer()
                Text(String(format: "%.0f%%", overage.usagePercentage))
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.purple)
            }

            ProgressBarView(percentage: overage.usagePercentage, color: .purple)

            Text("\(overage.formattedUsedCredits) 사용 / \(overage.formattedCreditLimit) 한도 (잔액 \(overage.formattedRemainingCredits))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Codex Credits View (Standard)

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
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.teal)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Compact Codex Credits Row

struct CompactCodexCreditsRow: View {
    let credits: CodexCredits

    var body: some View {
        HStack(spacing: 4) {
            Text("CX잔액")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)

            Spacer()

            Text(credits.formattedBalance)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)
                .foregroundStyle(.teal)
        }
    }
}

// MARK: - Compact Overage Row

struct CompactOverageRow: View {
    let overage: OverageSpendLimitResponse

    var body: some View {
        HStack(spacing: 4) {
            Text("추가")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(Color.purple)
                        .frame(width: geo.size.width * min(overage.usagePercentage, 100) / 100)
                }
            }
            .frame(height: 6)

            Text(String(format: "%.0f%%", overage.usagePercentage))
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)
                .foregroundStyle(.purple)
                .frame(width: 34, alignment: .trailing)

            Text("잔액 \(overage.formattedRemainingCredits)")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(width: 72, alignment: .trailing)
        }
    }
}
