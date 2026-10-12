import AppKit
import SwiftUI

extension SettingsView {
    @ViewBuilder
    var antigravityConnectionSection: some View {
        let state = antigravitySettings.state
        let managedRuntime =
            state.managedRuntimePresentation
        VStack(alignment: .leading, spacing: AppDesign.Space.content) {
            ProviderSettingsSectionHeader(provider: .antigravity, title: "Antigravity")
            VStack(
                alignment: .leading,
                spacing: AppDesign.Space.content
            ) {
                settingsToggleRow(
                    "Antigravity 사용",
                    isOn: Binding(
                        get: {
                            settings.isProviderEnabled(
                                .antigravity
                            )
                        },
                        set: {
                            settings.setProviderEnabled(
                                $0,
                                for: .antigravity
                            )
                        }
                    )
                )

                let badge = antigravityStatusBadge(state)
                RuntimeProviderBadgeView(title: badge.title, tone: badge.tone)

                antigravityIdentitySummary(state)

                if let notice = state.notice {
                    antigravityNoticeView(notice)
                }

                HStack(spacing: AppDesign.Space.row) {
                    Label("AGY CLI", systemImage: "terminal")
                        .font(AppDesign.Typography.caption)
                        .foregroundStyle(AppDesign.Text.secondary)
                    Spacer(minLength: AppDesign.Space.row)
                    Button("새로고침") {
                        Task { _ = await antigravitySettings.refresh() }
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.small)
                .disabled(state.activity.isBusy)

                Text("Antigravity IDE는 아직 지원하지 않습니다.")
                    .font(AppDesign.Typography.caption)
                    .foregroundStyle(AppDesign.Text.secondary)

                DisclosureGroup("고급 진단") {
                    VStack(
                        alignment: .leading,
                        spacing: AppDesign.Space.row
                    ) {
                        antigravityDiagnosticRow(
                            title: "AGY CLI",
                            value:
                                managedRuntime
                                    .diagnosticTitle
                        )
                        if let date = state.lastAttemptAt {
                            antigravityDiagnosticRow(title: "조회 시각", value: date.formatted(date: .abbreviated, time: .standard))
                        }
                        antigravityDiagnosticRow(
                            title: "최근 결과",
                            value:
                                antigravityDiagnosticResult(
                                    state.presentation
                                )
                        )
                    }
                    .padding(.top, AppDesign.Space.control)
                }
                .font(AppDesign.Typography.caption)
            }
            .padding(AppDesign.Space.content)
            .background(
                Color(
                    NSColor
                        .controlBackgroundColor
                )
                .opacity(0.45)
            )
            .cornerRadius(AppDesign.Radius.group)
        }
    }

    /// CLI 보고에는 계정 정보가 없어 보고를 받았으면 CLI 로그인 계정이라고만 적는다.
    private func antigravityIdentitySummary(_ state: AntigravitySettingsViewState) -> some View {
        let hasReport: Bool
        let isPrevious: Bool
        switch state.presentation {
        case .ready, .partial: (hasReport, isPrevious) = (true, false)
        case .stale, .refreshing(previous: .some): (hasReport, isPrevious) = (true, true)
        case .disabled, .refreshing(previous: nil), .failed: (hasReport, isPrevious) = (false, false)
        }
        let accountText = hasReport ? AntigravityQuotaPresentationMapper.cliReportAccountLabel : "확인 전"
        return LabeledContent(isPrevious ? "마지막 확인 계정" : "로그인 계정") {
            Text(accountText)
                .textSelection(.enabled)
        }
        .font(AppDesign.Typography.caption)
        .foregroundStyle(AppDesign.Text.secondary)
    }

    @ViewBuilder
    private func antigravityNoticeView(
        _ notice: AntigravitySettingsNotice
    ) -> some View {
        HStack(
            alignment: .top,
            spacing: AppDesign.Space.label
        ) {
            Image(
                systemName:
                    notice.tone
                        == .failure
                        ? "exclamationmark.triangle.fill"
                        : (
                            notice.tone
                                == .progress
                                ? "clock.arrow.circlepath"
                                : "info.circle.fill"
                        )
            )
            .foregroundStyle(
                notice.tone == .failure
                    ? Color.red
                    : (
                        notice.tone == .warning
                            ? Color.orange
                            : Color.accentColor
                    )
            )

            VStack(
                alignment: .leading,
                spacing: AppDesign.Space.micro
            ) {
                Text(notice.title)
                    .font(
                        .caption.weight(
                            .semibold
                        )
                    )
                Text(notice.message)
                    .font(AppDesign.Typography.caption)
                    .foregroundStyle(AppDesign.Text.secondary)
            }
            Spacer(minLength: 8)
            if let action = notice.action {
                Button(
                    noticeActionTitle(action)
                ) {
                    Task {
                        await antigravitySettings
                            .performNoticeAction()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(AppDesign.Space.label)
        .background(
            Color.accentColor.opacity(0.07)
        )
        .cornerRadius(AppDesign.Radius.group)
    }

    private func noticeActionTitle(
        _ action:
            AntigravitySettingsNotice.Action
    ) -> String {
        switch action {
        case .dismiss:
            "확인"
        case .retryLoad:
            "다시 확인"
        case .acknowledgeDisplayMigrationNotice:
            "확인"
        }
    }

    private func antigravityStatusBadge(
        _ state: AntigravitySettingsViewState
    ) -> (
        title: String,
        tone:
            RuntimeProviderBadgeView.Tone
    ) {
        if state.activity.isBusy {
            return ("확인 중", .secondary)
        }
        switch state.presentation {
        case .ready: return ("연결됨", .blue)
        case .partial: return ("일부 한도만", .orange)
        case .stale: return (UsageStatusLabel.previousValue, .orange)
        case .failed: return ("확인 실패", .red)
        case .refreshing: return ("확인 중", .secondary)
        case .disabled: return ("준비 중", .secondary)
        }
    }

    @ViewBuilder
    private func antigravityDiagnosticRow(
        title: String,
        value: String
    ) -> some View {
        HStack(
            alignment: .firstTextBaseline,
            spacing: AppDesign.Space.content
        ) {
            Text(title)
                .foregroundStyle(AppDesign.Text.secondary)
                .frame(
                    width: 86,
                    alignment: .leading
                )
            Text(value)
                .foregroundStyle(AppDesign.Text.secondary)
            Spacer(minLength: 0)
        }
    }

    private func antigravityDiagnosticResult(
        _ presentation:
            AntigravityPresentationState
    ) -> String {
        switch presentation {
        case .ready:
            "전체 한도"
        case .partial:
            "일부 한도"
        case .stale(_, let reason):
            "\(UsageStatusLabel.previousValue) · " + reason.diagnosticCode
        case .failed(let reason):
            reason.diagnosticCode
        case .refreshing:
            "확인 중"
        case .disabled:
            "없음"
        }
    }
}
