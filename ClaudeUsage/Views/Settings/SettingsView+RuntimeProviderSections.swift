import AppKit
import SwiftUI

extension SettingsView {
    @ViewBuilder
    func runtimeProviderPanel(
        for provider: AppProviderKind
    ) -> some View {
        if provider == .antigravity {
            antigravityStatusSection()
        } else {
            runtimeProviderOverviewSection(for: provider)
        }
    }

    @ViewBuilder
    private func runtimeProviderOverviewSection(
        for provider: AppProviderKind
    ) -> some View {
        let descriptor =
            SettingsProviderRegistry
                .providerShellDescriptor(for: provider)
        if let presentation =
            RuntimeProviderSettingsPresentation
                .authPresentation(
                    for: provider,
                    isEnabled:
                        settings.isProviderEnabled(
                            provider
                        ),
                    antigravityState:
                        provider == .antigravity
                            ? antigravitySettings
                                .state
                            : nil
                )
        {
            RuntimeProviderOverviewSectionView(
                settings: settings,
                provider: provider,
                descriptor: descriptor,
                presentation: presentation
            )
        } else {
            RuntimeProviderPanelShell(
                descriptor: descriptor,
                title: descriptor.title,
                detail: descriptor.detail
            ) {
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func antigravityStatusSection()
        -> some View
    {
        let state = antigravitySettings.state
        let managedRuntime =
            state.managedRuntimePresentation
        RuntimeProviderPanelShell(
            descriptor:
                SettingsProviderRegistry
                    .providerShellDescriptor(
                        for: .antigravity
                    ),
            title: "Antigravity 연결",
            detail: "앱·CLI에서 확인한 로컬 계정을 선택하면 같은 계정의 사용량만 표시합니다."
        ) {
            VStack(
                alignment: .leading,
                spacing: 12
            ) {
                settingsToggleRow(
                    "Antigravity 사용",
                    subtitle: "끄면 조회와 메뉴바·팝오버 표시를 중지합니다",
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

                HStack(
                    alignment: .firstTextBaseline,
                    spacing: 8
                ) {
                    Text(
                        antigravityStatusTitle(
                            state
                        )
                    )
                    .font(
                        .subheadline.weight(
                            .semibold
                        )
                    )
                    Spacer(minLength: 0)
                    let badge =
                        antigravityStatusBadge(
                            state
                        )
                    RuntimeProviderBadgeView(
                        title: badge.title,
                        tone: badge.tone
                    )
                }

                Text(
                    antigravityStatusDetail(state)
                )
                .font(AppDesign.Typography.caption)
                .foregroundStyle(.secondary)

                antigravityIdentitySummary(state)

                if let notice = state.notice {
                    antigravityNoticeView(notice)
                }

                HStack(spacing: AppDesign.Space.row) {
                    Picker("조회 대상", selection: antigravityUsageTargetSelection) {
                        if state.usageTarget == .unselected {
                            Text("조회 대상 선택").tag(AntigravityUsageTarget.unselected)
                        }
                        Text("AGY CLI").tag(AntigravityUsageTarget.cli)
                        Text("Antigravity 독립 앱").tag(AntigravityUsageTarget.app)
                    }
                    .pickerStyle(.menu)
                    Spacer(minLength: AppDesign.Space.row)
                    Button("새로고침") {
                        Task { _ = await antigravitySettings.refresh() }
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.small)
                .disabled(state.activity.isBusy)

                Text("로그인은 선택한 제품에서 변경한 뒤 새로고침해 주세요. Antigravity IDE는 아직 지원하지 않습니다.")
                    .font(AppDesign.Typography.caption)
                    .foregroundStyle(.secondary)

                DisclosureGroup("고급 진단") {
                    VStack(
                        alignment: .leading,
                        spacing: 8
                    ) {
                        if !state.accounts.isEmpty {
                            Text("이전 버전의 연결 정보는 현재 조회에 사용하지 않습니다.")
                                .font(AppDesign.Typography.caption)
                                .foregroundStyle(.secondary)
                            Button("이전 연결 정보 삭제") {
                                pendingDestructiveAction = .disconnectAllAntigravityAccounts
                            }
                            .buttonStyle(.bordered)
                            .disabled(state.activity.isBusy)
                        }
                        antigravityDiagnosticRow(
                            title: "저장 상태",
                            value:
                                state.repositoryRevision
                                    .map {
                                        "검증됨 · revision \($0)"
                                    }
                                    ?? "확인 중"
                        )
                        antigravityDiagnosticRow(
                            title: "AGY CLI",
                            value:
                                managedRuntime
                                    .diagnosticTitle
                        )
                        antigravityDiagnosticRow(
                            title: "계정 이전",
                            value:
                                migrationPhaseTitle(
                                    state
                                        .migrationStatus?
                                        .phase
                                )
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

    private var antigravityUsageTargetSelection: Binding<AntigravityUsageTarget> {
        Binding(
            get: { antigravitySettings.state.usageTarget },
            set: { selection in
                Task { _ = await antigravitySettings.selectTarget(selection) }
            })
    }

    private func antigravityIdentitySummary(_ state: AntigravitySettingsViewState) -> some View {
        let identity: ProviderAccountIdentity?
        let isPrevious: Bool
        switch state.presentation {
        case .ready(let quota), .partial(let quota, _):
            identity = quota.identity ?? quota.provenance.accountIdentity
            isPrevious = false
        case .stale(let quota, _), .refreshing(previous: let quota?):
            identity = quota.identity ?? quota.provenance.accountIdentity
            isPrevious = true
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
        return LabeledContent(isPrevious ? "마지막 확인 계정" : "로그인 계정") {
            Text(identity?.email ?? (identity == nil ? "확인 전" : "이메일 미제공"))
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
        case .retryLoad,
             .retryMigrationCheck:
            "다시 확인"
        case .continueMigration:
            "이전"
        case .removeLegacyData:
            "정리 계속"
        case .acknowledgeDisplayMigrationNotice:
            "확인"
        }
    }

    private func antigravityStatusTitle(
        _ state: AntigravitySettingsViewState
    ) -> String {
        if state.activity.isBusy {
            return "Antigravity 상태 갱신 중"
        }
        switch state.presentation {
        case .ready, .partial:
            return "사용량 한도 조회됨"
        case .limited:
            return "로그인 계정 확인됨"
        case .identityOnly:
            return "계정만 확인됨"
        case .stale:
            return "이전 사용량 표시 중"
        case .accountMismatch:
            return "계정이 일치하지 않음"
        case .setupRequired(.managedRecoveryBlocked):
            return "이전 AGY 실행 정리 필요"
        case .setupRequired(.usageTargetSelection):
            return "조회 대상 선택 필요"
        case .setupRequired(.ambiguousLocalSessions):
            return "실행 중인 연결 확인 필요"
        case .setupRequired:
            return "로그인 필요"
        case .failed:
            return "사용량 조회 실패"
        case .refreshing:
            return "사용량 확인 중"
        case .disabled:
            return "준비 중"
        }
    }

    private func antigravityStatusDetail(
        _ state: AntigravitySettingsViewState
    ) -> String {
        switch state.quotaPresentation {
        case .content(let presentation):
            return "\(presentation.observedLaneCount)개 사용 한도를 실제 출처와 계정 경계까지 검증해 표시합니다."
        case .unavailable:
            break
        }
        switch state.presentation {
        case .limited:
            return "현재 연결은 계정과 기능만 확인하며 수치형 quota는 제공하지 않습니다."
        case .identityOnly:
            return "계정은 확인했지만 표시 가능한 사용량 수치를 받지 못했습니다."
        case .accountMismatch:
            return "조회 중 계정이 달라져 이전 수치는 표시하지 않았습니다."
        case .setupRequired(.managedRecoveryBlocked):
            return "이전 AGY 실행 기록을 정리하지 못해 자동 실행이 중지됐습니다. Antigravity 앱이나 AGY CLI를 실행하면 조회는 가능합니다. ClaudeUsage를 재시동해 정리를 다시 시도해 주세요."
        case .setupRequired:
            return "조회 대상을 선택하고 해당 제품에서 로그인해 주세요."
        case .stale:
            return "새 조회가 실패해 마지막으로 검증된 데이터만 유지합니다."
        case .failed:
            return "선택한 조회 대상의 로그인과 연결 상태를 확인해 주세요."
        case .refreshing:
            return "선택한 제품의 로그인 계정과 사용량을 확인하고 있습니다."
        case .disabled:
            return "Antigravity 런타임을 준비하고 있습니다."
        case .ready, .partial:
            return "사용량을 확인했습니다."
        }
    }

    private func antigravityStatusBadge(
        _ state: AntigravitySettingsViewState
    ) -> (
        title: String,
        tone:
            RuntimeProviderAuthPresentation
                .BadgeTone
    ) {
        if state.activity.isBusy {
            return ("확인 중", .secondary)
        }
        switch state.presentation {
        case .ready:
            return ("최신", .blue)
        case .setupRequired(.managedRecoveryBlocked):
            return ("정리 필요", .red)
        case .partial,
             .stale,
             .limited,
             .identityOnly,
             .setupRequired:
            return ("확인 필요", .orange)
        case .accountMismatch,
             .failed:
            return ("조치 필요", .red)
        case .refreshing,
             .disabled:
            return ("준비 중", .secondary)
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

    private func migrationPhaseTitle(
        _ phase: AntigravityMigrationPhase?
    ) -> String {
        guard let phase else { return "확인 중" }
        return switch phase {
        case .complete:
            "완료"
        case .awaitingImportAuthorization:
            "사용자 이전 대기"
        case .cleanupPending:
            "기존 데이터 정리 대기"
        case .blockedBeforeCutover:
            "기존 데이터 보존 · 확인 필요"
        case .notStarted,
             .preflight,
             .writingCanonical,
             .canonicalVerified:
            "검증 중"
        }
    }

    private func antigravityDiagnosticResult(
        _ presentation:
            AntigravityPresentationState
    ) -> String {
        switch presentation {
        case .ready:
            "전체 quota"
        case .partial:
            "일부 quota"
        case .limited:
            "제한된 기능"
        case .identityOnly:
            "계정 정보만"
        case .stale(_, let reason):
            "이전 데이터 · " + reason.diagnosticCode
        case .accountMismatch:
            "계정 불일치"
        case .setupRequired(.managedRecoveryBlocked):
            "정리 필요"
        case .setupRequired:
            "설정 필요"
        case .failed(let reason):
            reason.diagnosticCode
        case .refreshing:
            "조회 중"
        case .disabled:
            "없음"
        }
    }

    func disconnectSelectedAntigravityAccount() {
        guard let accountID =
                antigravitySettings.state
                    .activeAccountID
        else {
            return
        }
        Task {
            _ = await antigravitySettings
                .deleteAccount(accountID)
        }
    }

    func disconnectAllAntigravityAccounts() {
        Task {
            _ = await antigravitySettings
                .deleteAllAccounts()
        }
    }
}
