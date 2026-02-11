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
                Picker("", selection: $viewModel.selectedTab) {
                    Text("5시간").tag(0)
                    Text("주간").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)

                Spacer()

                Button(action: { viewModel.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14))
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isLoading)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            if viewModel.isLoading && viewModel.usage == nil {
                // 최초 로딩
                VStack(spacing: 12) {
                    ProgressView()
                    Text("데이터 로딩 중...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 150)

            } else if let error = viewModel.error, viewModel.usage == nil {
                // 에러 (데이터 없음)
                ErrorSectionView(error: error) {
                    viewModel.refresh()
                }
                .padding(16)

            } else if let usage = viewModel.usage {
                // 데이터 표시
                ScrollView {
                    VStack(spacing: 12) {
                        if viewModel.selectedTab == 0 {
                            // 5시간 세션
                            UsageSectionView(
                                icon: "📊",
                                title: "5시간 세션",
                                percentage: usage.fiveHour.utilization,
                                resetAt: usage.fiveHour.resetsAt
                            )
                        } else {
                            // 주간 한도
                            UsageSectionView(
                                icon: "📅",
                                title: "주간 한도 (전체 모델)",
                                percentage: usage.sevenDay.utilization,
                                resetAt: usage.sevenDay.resetsAt
                            )

                            if let sonnet = usage.sevenDaySonnet {
                                Divider()
                                UsageSectionView(
                                    icon: "✨",
                                    title: "Sonnet (주간)",
                                    percentage: sonnet.utilization,
                                    resetAt: sonnet.resetsAt
                                )
                            }

                            if let opus = usage.sevenDayOpus {
                                Divider()
                                UsageSectionView(
                                    icon: "🎯",
                                    title: "Opus (주간)",
                                    percentage: opus.utilization,
                                    resetAt: opus.resetsAt
                                )
                            }
                        }
                    }
                    .padding(16)
                }

            } else {
                // 데이터 없음
                VStack {
                    Text("데이터 없음")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 100)
            }

            Divider()

            // 하단 버튼
            HStack {
                Button("사용량 상세 보기 →") {
                    viewModel.openUsagePage()
                }
                .buttonStyle(.borderless)
                .font(.caption)

                Spacer()

                Button("⚙️ 설정") {
                    viewModel.openSettings()
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
        }
        .frame(width: 340)
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
    @Published var selectedTab: Int = 0

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

    func update(usage: ClaudeUsageResponse?, error: APIError?, isLoading: Bool) {
        self.usage = usage
        self.error = error
        self.isLoading = isLoading
    }
}
