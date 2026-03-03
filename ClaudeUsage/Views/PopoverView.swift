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
    @State private var isStatusExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 상단 바
            HStack(spacing: 6) {
                Text("Claude 사용량")
                    .font(.headline)

                // 새로고침 (제목 옆)
                Button(action: { viewModel.refresh() }) {
                    Group {
                        if viewModel.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12))
                        }
                    }
                    .frame(width: 14, height: 14)
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

            if let health = viewModel.usageHealthSnapshot {
                Divider()
                HStack(spacing: 6) {
                    popoverChip(
                        title: settings.popoverCompact ? nil : "경로",
                        value: runtimePathLabel(health.runtime.activePath),
                        color: runtimePathColor(health.runtime.activePath)
                    )

                    if !settings.popoverCompact, let lastSuccess = health.lastOverallSuccessAt {
                        popoverChip(
                            title: "최근 성공",
                            value: shortRelativeText(for: lastSuccess),
                            color: .secondary
                        )
                    }

                    if let retryAt = viewModel.nextUsageRetryAt, retryAt > Date() {
                        popoverChip(
                            title: settings.popoverCompact ? nil : "재시도",
                            value: shortRelativeText(for: retryAt),
                            color: .orange
                        )
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }

            // 시스템 상태 배너 (장애 시에만 표시)
            if let status = viewModel.systemStatus, status.hasIssue {
                Divider()
                VStack(alignment: .leading, spacing: settings.popoverCompact ? 4 : 5) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(statusColor(for: status.indicator))

                        Text(status.indicator.displayText)
                            .font(.caption)
                            .foregroundColor(.primary)

                        if status.activeIncidentCount > 0 {
                            Text("활성 \(status.activeIncidentCount)건")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(statusColor(for: status.indicator).opacity(0.16))
                                .foregroundColor(statusColor(for: status.indicator))
                                .cornerRadius(4)
                        }

                        Spacer()

                        if !settings.popoverCompact {
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    isStatusExpanded.toggle()
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(isStatusExpanded ? "접기" : "상세")
                                        .font(.caption2)
                                    Image(systemName: isStatusExpanded ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .foregroundColor(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }

                        Button {
                            if let url = URL(string: status.latestIncident?.shortlink ?? "https://status.claude.com") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("status.claude.com 열기")
                    }

                    if !settings.popoverCompact && isStatusExpanded {
                        HStack(spacing: 8) {
                            Text("상태")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(status.description)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Spacer()
                        }

                        if let incident = status.latestIncident {
                            Text(incident.name)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                                .lineLimit(1)

                            if let body = incident.latestUpdateBody, !body.isEmpty {
                                Text(body)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(settings.popoverCompact ? 1 : 2)
                            }

                            let affected = affectedComponentsSummary(incident.affectedComponents)
                            if !affected.isEmpty {
                                Text("영향: \(affected)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            if let updatedAt = incident.latestUpdateAt {
                                Text("업데이트: \(updatedAt, style: .relative)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        } else if !status.degradedComponents.isEmpty {
                            Text("영향: \(affectedComponentsSummary(status.degradedComponents))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(statusColor(for: status.indicator).opacity(0.08))
                .onChange(of: settings.popoverCompact) { _, isCompact in
                    if isCompact {
                        isStatusExpanded = false
                    }
                }
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

            if let staleMessage = staleDataMessage {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(staleMessage)
                        .font(.caption)
                        .foregroundColor(.primary)
                    Spacer()
                    if viewModel.error != nil {
                        Text("자동 재시도 중")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.08))
            }

            Divider()

            if settings.popoverCompact {
                compactMainSection
            } else {
                standardMainSection
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

    private func runtimePathLabel(_ path: ClaudeAPIService.RuntimeAuthSnapshot.ActivePath) -> String {
        switch path {
        case .sessionPrimary:
            return "세션키"
        case .oauthPreferred:
            return "OAuth 우선"
        case .oauthFallback:
            return "OAuth 폴백"
        }
    }

    private func runtimePathColor(_ path: ClaudeAPIService.RuntimeAuthSnapshot.ActivePath) -> Color {
        switch path {
        case .sessionPrimary:
            return .green
        case .oauthPreferred:
            return .blue
        case .oauthFallback:
            return .orange
        }
    }

    private func shortRelativeText(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func popoverChip(title: String?, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            if let title {
                Text(title)
            }
            Text(value)
                .fontWeight(.semibold)
        }
        .font(.caption2)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.16))
        .foregroundStyle(color)
        .cornerRadius(6)
    }

    private func affectedComponentsSummary(_ components: [String], maxShown: Int = 3) -> String {
        guard !components.isEmpty else { return "" }
        let head = components.prefix(maxShown)
        let tailCount = max(0, components.count - head.count)
        let base = head.joined(separator: ", ")
        if tailCount > 0 {
            return "\(base) +\(tailCount)"
        }
        return base
    }

    private var staleDataMessage: String? {
        guard let lastUpdated = viewModel.lastUpdated else { return nil }

        let elapsed = Date().timeIntervalSince(lastUpdated)
        let threshold = max(180.0, settings.refreshInterval * 4.0)
        guard elapsed >= threshold else { return nil }

        let minutes = Int(elapsed / 60)
        if minutes < 1 {
            return "데이터가 최신이 아닐 수 있습니다 (마지막 성공: 방금 전)"
        } else if minutes < 60 {
            return "데이터가 최신이 아닐 수 있습니다 (마지막 성공: \(minutes)분 전)"
        } else {
            let hours = minutes / 60
            let remainMinutes = minutes % 60
            if remainMinutes == 0 {
                return "데이터가 최신이 아닐 수 있습니다 (마지막 성공: \(hours)시간 전)"
            }
            return "데이터가 최신이 아닐 수 있습니다 (마지막 성공: \(hours)시간 \(remainMinutes)분 전)"
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
                default:
                    EmptyView()
                }
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var compactMainSection: some View {
        Group {
            if viewModel.isLoading && viewModel.usage == nil {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("데이터 로딩 중...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 56)

            } else if let error = viewModel.error, viewModel.usage == nil {
                ErrorSectionView(error: error) {
                    viewModel.refresh()
                }
                .padding(12)

            } else if let usage = viewModel.usage {
                compactContent(usage: usage)

            } else {
                Text("데이터 없음")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var standardMainSection: some View {
        Group {
            if viewModel.isLoading && viewModel.usage == nil {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("데이터 로딩 중...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 150)

            } else if let error = viewModel.error, viewModel.usage == nil {
                ErrorSectionView(error: error) {
                    viewModel.refresh()
                }
                .padding(16)

            } else if let usage = viewModel.usage {
                standardContent(usage: usage)

            } else {
                VStack {
                    Text("데이터 없음")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 100)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .top)
        .padding(.bottom, 4)
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

            if error.isTemporaryFailure {
                Text("세션키 경로가 일시적으로 불안정합니다. 설정 > 인증에서 Claude CLI OAuth 인증을 권장합니다.")
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(6)
            }

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
    @Published var usageHealthSnapshot: ClaudeAPIService.UsageHealthSnapshot?
    @Published var nextUsageRetryAt: Date?
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
