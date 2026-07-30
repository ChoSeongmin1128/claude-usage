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
            detail: "조회할 계정을 고르면 로컬 앱, AGY CLI, Google 계정 순서를 자동으로 결정합니다."
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
                .font(.caption)
                .foregroundStyle(.secondary)

                antigravityIdentitySummary(state)

                if let notice = state.notice {
                    antigravityNoticeView(notice)
                }

                Picker(
                    "조회 계정",
                    selection:
                        antigravityAccountSelection
                ) {
                    Text("로컬 Antigravity/AGY 계정")
                        .tag(
                            Optional<AntigravityAccountID>
                                .none
                        )
                    ForEach(state.accounts) {
                        account in
                        Text(account.label)
                            .tag(
                                Optional(account.id)
                            )
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .disabled(
                    state.activity.isBusy
                )

                HStack(spacing: 8) {
                    Button("새로고침") {
                        Task {
                            _ = await
                                antigravitySettings
                                .refresh()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(
                        state.activity.isBusy
                    )

                    Button(
                        state.activity
                            == .authenticating
                            ? "로그인 진행 중"
                            : (
                                state.accounts
                                    .isEmpty
                                    ? "Google 계정 연결"
                                    : "Google 계정 추가"
                            )
                    ) {
                        Task {
                            _ = await
                                antigravitySettings
                                .addAccount()
                        }
                    }
                    .buttonStyle(
                        .borderedProminent
                    )
                    .controlSize(.small)
                    .disabled(
                        state.activity.isBusy
                    )

                    if state.activity
                        == .authenticating
                    {
                        Button("로그인 취소") {
                            antigravitySettings
                                .cancelOAuthLogin()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        Button(
                            state.accounts.count > 1
                                ? "선택 계정 제거"
                                : "Google 연결 해제"
                        ) {
                            pendingDestructiveAction =
                                .disconnectAntigravityAccount
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(
                            state.activeAccountID
                                == nil
                                || state.activity
                                    .isBusy
                        )

                        if state.accounts.count > 1 {
                            Button("모든 계정 제거") {
                                pendingDestructiveAction =
                                    .disconnectAllAntigravityAccounts
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(
                                state.activity.isBusy
                            )
                        }
                    }
                }

                DisclosureGroup("고급 진단") {
                    VStack(
                        alignment: .leading,
                        spacing: 8
                    ) {
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
                        antigravityDiagnosticRow(
                            title: "최근 결과",
                            value:
                                antigravityDiagnosticResult(
                                    state.presentation
                                )
                        )
                    }
                    .padding(.top, 6)
                }
                .font(.caption)
            }
            .padding(12)
            .background(
                Color(
                    NSColor
                        .controlBackgroundColor
                )
                .opacity(0.45)
            )
            .cornerRadius(8)
        }
    }

    private var antigravityAccountSelection:
        Binding<AntigravityAccountID?>
    {
        Binding(
            get: {
                antigravitySettings.state
                    .activeAccountID
            },
            set: { accountID in
                Task {
                    _ = await
                        antigravitySettings
                        .selectAccount(accountID)
                }
            }
        )
    }

    @ViewBuilder
    private func antigravityIdentitySummary(
        _ state: AntigravitySettingsViewState
    ) -> some View {
        if case .content(let presentation) =
            state.quotaPresentation
        {
            Text(
                presentation.identityRail
                    .visibleSegments
                    .joined(separator: " · ")
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(
                presentation.identityRail
                    .tooltip
            )
            .accessibilityElement(
                children: .ignore
            )
            .accessibilityLabel(
                presentation.identityRail
                    .accessibilityLabel
            )
            .accessibilityValue(
                presentation.identityRail
                    .accessibilityValue
            )
        } else if let account =
            state.accounts.first(where: {
                $0.isActive
            })
        {
            Text(
                [
                    account.label,
                    account.email,
                ]
                .compactMap { $0 }
                .joined(separator: " · ")
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
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
                    .font(.caption)
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
        .padding(10)
        .background(
            Color.accentColor.opacity(0.07)
        )
        .cornerRadius(8)
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
        case .cancelOAuthLogin:
            "취소"
        }
    }

    private func antigravityStatusTitle(
        _ state: AntigravitySettingsViewState
    ) -> String {
        if state.activity.isBusy {
            return state.activity
                == .authenticating
                ? "Google 로그인 진행 중"
                : "Antigravity 상태 갱신 중"
        }
        switch state.presentation {
        case .ready, .partial:
            return "사용량 한도 조회됨"
        case .limited:
            return "계정 연결됨"
        case .identityOnly:
            return "계정만 확인됨"
        case .stale:
            return "이전 사용량 표시 중"
        case .accountMismatch:
            return "계정이 일치하지 않음"
        case .setupRequired:
            return "조회 계정 또는 로그인 필요"
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
            return "Google 계정은 확인했지만 표시 가능한 quota 수치를 받지 못했습니다."
        case .accountMismatch:
            return "선택한 계정과 다른 세션의 숫자는 표시하지 않았습니다."
        case .setupRequired:
            return "Google 계정을 연결하거나 로그인된 로컬 세션을 선택해 주세요."
        case .stale:
            return "새 조회가 실패해 마지막으로 검증된 데이터만 유지합니다."
        case .failed:
            return "조회 계정, Antigravity 앱 또는 AGY CLI 로그인 상태를 확인해 주세요."
        case .refreshing:
            return "선택한 계정에 맞는 조회 경로를 자동으로 다시 확인하고 있습니다."
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
        case .stale:
            "이전 데이터"
        case .accountMismatch:
            "계정 불일치"
        case .setupRequired:
            "설정 필요"
        case .failed:
            "실패"
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
