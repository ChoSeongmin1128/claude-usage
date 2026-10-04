import AppKit
import SwiftUI

extension SettingsView {
    func runtimeProviderPanel(for provider: AppProviderKind) -> some View {
        antigravityStatusSection()
    }

    @ViewBuilder
    private func antigravityStatusSection()
        -> some View
    {
        let state = antigravitySettings.state
        let managedRuntime =
            state.managedRuntimePresentation
        VStack(alignment: .leading, spacing: AppDesign.Space.content) {
            ProviderSettingsSectionHeader(provider: .antigravity, title: "Antigravity")
            VStack(
                alignment: .leading,
                spacing: 12
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
                        .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)

                DisclosureGroup("고급 진단") {
                    VStack(
                        alignment: .leading,
                        spacing: 8
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

    private func antigravityIdentitySummary(_ state: AntigravitySettingsViewState) -> some View {
        let identity: ProviderAccountIdentity?
        let isPrevious: Bool
        var isCLIReport = false
        switch state.presentation {
        case .ready(let quota), .partial(let quota, _):
            identity = quota.identity ?? quota.provenance.accountIdentity
            isPrevious = false
            isCLIReport = quota.provenance.transport == .cliUsageReport
        case .stale(let quota, _), .refreshing(previous: let quota?):
            identity = quota.identity ?? quota.provenance.accountIdentity
            isPrevious = true
            isCLIReport = quota.provenance.transport == .cliUsageReport
        case .limited(let value):
            identity = value.evidence.identity
            isPrevious = false
        case .identityOnly(let value):
            identity = value.identity
            isPrevious = false
        default:
            identity = nil
            isPrevious = false
        }
        let accountText: String
        if let identity {
            accountText = identity.email ?? "이메일 없음"
        } else if isCLIReport {
            accountText = AntigravityQuotaPresentationMapper.cliReportAccountLabel
        } else {
            accountText = "확인 전"
        }
        return LabeledContent(isPrevious ? "마지막 확인 계정" : "로그인 계정") {
            Text(accountText)
                .textSelection(.enabled)
        }
        .font(AppDesign.Typography.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func antigravityNoticeView(
        _ notice: AntigravitySettingsNotice
    ) -> some View {
        HStack(
            alignment: .top,
            spacing: 10
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
                spacing: 3
            ) {
                Text(notice.title)
                    .font(
                        .caption.weight(
                            .semibold
                        )
                    )
                Text(notice.message)
                    .font(AppDesign.Typography.caption)
                    .foregroundStyle(.secondary)
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
        case .limited, .identityOnly: return ("사용량 수치 없음", .orange)
        case .setupRequired(.ambiguousLocalSessions): return ("계정 여러 개", .orange)
        case .setupRequired: return ("로그인 필요", .orange)
        case .accountMismatch: return ("계정 불일치", .red)
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
            spacing: 12
        ) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(
                    width: 86,
                    alignment: .leading
                )
            Text(value)
                .foregroundStyle(.secondary)
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
        case .limited:
            "수치 없음"
        case .identityOnly:
            "계정만"
        case .stale(_, let reason):
            "\(UsageStatusLabel.previousValue) · " + reason.diagnosticCode
        case .accountMismatch:
            "계정 불일치"
        case .setupRequired:
            "설정 필요"
        case .failed(let reason):
            reason.diagnosticCode
        case .refreshing:
            "확인 중"
        case .disabled:
            "없음"
        }
    }
}
