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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 상단 바
            HStack {
                Text("Claude 사용량")
                    .font(.headline)

                Spacer()

                if let lastUpdated = viewModel.lastUpdated {
                    Text(lastUpdated, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Button(action: { viewModel.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14))
                        .rotationEffect(.degrees(viewModel.isLoading ? 360 : 0))
                        .animation(viewModel.isLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: viewModel.isLoading)
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isLoading)
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
                .frame(maxWidth: .infinity, minHeight: 150)

            } else if let error = viewModel.error, viewModel.usage == nil {
                ErrorSectionView(error: error) {
                    viewModel.refresh()
                }
                .padding(16)

            } else if let usage = viewModel.usage {
                VStack(spacing: 12) {
                    UsageSectionView(
                        systemIcon: "gauge.medium",
                        title: "5시간 세션",
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

            } else {
                VStack {
                    Text("데이터 없음")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 100)
            }

            Divider()

            // 하단 버튼
            HStack {
                Button {
                    viewModel.openUsagePage()
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "safari")
                        Text("claude.ai/settings/usage")
                    }
                    .foregroundColor(.accentColor)
                }
                .buttonStyle(.borderless)
                .font(.caption)

                Spacer()

                Button {
                    viewModel.openSettings()
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "gearshape")
                        Text("설정")
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)

                Button("종료") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // 단축키 안내
            HStack(spacing: 8) {
                Text("⌘R 새로고침")
                Text("⌘, 설정")
            }
            .font(.system(size: 10))
            .foregroundStyle(.quaternary)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 6)
        }
        .frame(width: 340)
        .background(Color(NSColor.windowBackgroundColor))
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
