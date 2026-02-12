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

    // MARK: - Standard Content

    @ViewBuilder
    private func standardContent(usage: ClaudeUsageResponse) -> some View {
        VStack(spacing: 12) {
            UsageSectionView(
                systemIcon: "gauge.medium",
                title: "현재 세션",
                percentage: usage.fiveHour.utilization,
                resetAt: usage.fiveHour.resetsAt
            )

            Divider()

            UsageSectionView(
                systemIcon: "calendar",
                title: "주간 한도",
                percentage: usage.sevenDay.utilization,
                resetAt: usage.sevenDay.resetsAt,
                isWeekly: true
            )

            if let sonnet = usage.sevenDaySonnet {
                Divider()
                UsageSectionView(
                    systemIcon: "bolt.fill",
                    title: "Sonnet (주간)",
                    percentage: sonnet.utilization,
                    resetAt: sonnet.resetsAt,
                    isWeekly: true
                )
            }

            if let opus = usage.sevenDayOpus {
                Divider()
                UsageSectionView(
                    systemIcon: "diamond.fill",
                    title: "Opus (주간)",
                    percentage: opus.utilization,
                    resetAt: opus.resetsAt,
                    isWeekly: true
                )
            }
        }
        .padding(16)
    }

    // MARK: - Compact Content

    @ViewBuilder
    private func compactContent(usage: ClaudeUsageResponse) -> some View {
        VStack(spacing: 5) {
            CompactUsageRow(label: "현재", percentage: usage.fiveHour.utilization, resetAt: usage.fiveHour.resetsAt)
            CompactUsageRow(label: "주간", percentage: usage.sevenDay.utilization, resetAt: usage.sevenDay.resetsAt, isWeekly: true)

            if let sonnet = usage.sevenDaySonnet {
                CompactUsageRow(label: "Sonnet", percentage: sonnet.utilization, resetAt: sonnet.resetsAt, isWeekly: true)
            }
            if let opus = usage.sevenDayOpus {
                CompactUsageRow(label: "Opus", percentage: opus.utilization, resetAt: opus.resetsAt, isWeekly: true)
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
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)

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
                .frame(width: 36, alignment: .trailing)

            if let resetText = compactResetText {
                Text(resetText)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(width: 46, alignment: .trailing)
            }
        }
    }

    private var compactResetText: String? {
        guard let resetAt = resetAt else { return nil }
        let style = AppSettings.shared.timeFormat
        if isWeekly {
            return TimeFormatter.formatResetTimeWeekly(from: resetAt, style: style)
        }
        return TimeFormatter.formatResetTime(from: resetAt, style: style)
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

    func update(usage: ClaudeUsageResponse?, error: APIError?, isLoading: Bool, lastUpdated: Date? = nil) {
        self.usage = usage
        self.error = error
        self.isLoading = isLoading
        if let lastUpdated { self.lastUpdated = lastUpdated }
    }
}
