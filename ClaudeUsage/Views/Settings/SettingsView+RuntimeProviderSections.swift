import AppKit
import SwiftUI

extension SettingsView {
    @ViewBuilder
    func runtimeProviderPanel(for provider: AppProviderKind) -> some View {
        runtimeProviderOverviewSection(for: provider)
        if provider == .antigravity {
            antigravityStatusSection()
        }
    }

    @ViewBuilder
    private func runtimeProviderOverviewSection(for provider: AppProviderKind) -> some View {
        let _ = runtimeEnvironmentRefreshTick
        let descriptor = SettingsProviderRegistry.providerShellDescriptor(for: provider)
        if let presentation = RuntimeProviderSettingsPresentation.authPresentation(
            for: provider,
            isEnabled: settings.isProviderEnabled(provider)
        ) {
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
    private func antigravityStatusSection() -> some View {
        let antigravitySignals = ProviderEnvironmentDetector.cachedAntigravitySignals()
        let credentialStatus = antigravitySignals?.oauthCredentialStatus
        let hasLocalOAuthAccount = !antigravityOAuthSettings.accounts.isEmpty
        let cliBinaryStatus = antigravitySignals?.cliBinaryStatus ?? .missing
        let hasCLIStateDirectory = antigravitySignals?.hasCLIStateDirectory == true
        let hasCLISettingsFile = antigravitySignals?.hasCLISettingsFile == true
        let lastUsage = antigravityLastUsage?()
        RuntimeProviderPanelShell(
            descriptor: SettingsProviderRegistry.providerShellDescriptor(for: .antigravity),
            title: "Antigravity 연결",
            detail: "계정과 사용량 상태만 확인합니다."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(antigravityStatusTitle(lastUsage: lastUsage, credentialStatus: credentialStatus, signals: antigravitySignals))
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    if lastUsage?.hasUsageWindows == true {
                        RuntimeProviderBadgeView(title: "quota 조회됨", tone: .blue)
                    } else if lastUsage != nil || credentialStatus?.hasCredential == true {
                        RuntimeProviderBadgeView(title: "계정 확인", tone: .secondary)
                    }
                }

                Text(antigravityStatusDetail(lastUsage: lastUsage, credentialStatus: credentialStatus, signals: antigravitySignals))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let accountLine = antigravityAccountLine(lastUsage: lastUsage, credentialStatus: credentialStatus) {
                    Text(accountLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let message = antigravityOAuthSettings.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !antigravityOAuthSettings.accounts.isEmpty {
                    Picker("Google 계정", selection: Binding(
                        get: { antigravityOAuthSettings.activeAccountID ?? "" },
                        set: { accountID in
                            guard !accountID.isEmpty else { return }
                            antigravityOAuthSettings.selectAccount(
                                id: accountID,
                                refreshEnvironment: refreshAntigravityEnvironmentState
                            )
                        }
                    )) {
                        ForEach(antigravityOAuthSettings.accounts) { account in
                            Text(account.label).tag(account.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                }

                HStack(spacing: 8) {
                    Button("새로고침") {
                        refreshAntigravityEnvironmentState()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(antigravityOAuthSettings.isLoggingIn
                        ? "로그인 진행 중"
                        : (antigravityOAuthSettings.accounts.isEmpty ? "Google 계정 연결" : "Google 계정 추가"))
                    {
                        antigravityOAuthSettings.connect(
                            settings: settings,
                            refreshEnvironment: refreshAntigravityEnvironmentState
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(antigravityOAuthSettings.isLoggingIn)

                    if antigravityOAuthSettings.isLoggingIn {
                        Button("로그인 취소") {
                            antigravityOAuthSettings.cancelLogin()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        Button(antigravityOAuthSettings.accounts.count > 1 ? "선택 계정 제거" : "Google 연결 해제") {
                            antigravityOAuthSettings.disconnect(
                                refreshEnvironment: refreshAntigravityEnvironmentState
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!hasLocalOAuthAccount)

                        if antigravityOAuthSettings.accounts.count > 1 {
                            Button("모든 계정 제거") {
                                antigravityOAuthSettings.disconnectAll(
                                    refreshEnvironment: refreshAntigravityEnvironmentState
                                )
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }

                DisclosureGroup("고급 진단") {
                    VStack(alignment: .leading, spacing: 8) {
                        antigravityDiagnosticRow(
                            title: "앱 연결",
                            value: antigravitySignals?.hasRuntimeConnection == true
                                ? "사용 가능"
                                : (antigravitySignals?.appRunning == true ? "준비 중" : "앱 대기")
                        )
                        antigravityDiagnosticRow(
                            title: "AGY CLI",
                            value: antigravityCLIDiagnosticSummary(
                                cliBinaryStatus: cliBinaryStatus,
                                hasCLISettingsFile: hasCLISettingsFile,
                                hasCLIStateDirectory: hasCLIStateDirectory,
                                isLoading: antigravitySignals == nil
                            )
                        )
                        antigravityDiagnosticRow(
                            title: "Google 계정",
                            value: credentialStatus?.hasCredential == true
                                ? "연결됨"
                                : "미연결"
                        )
                        if let lastUsageSource = antigravityLastUsageSource?() {
                            antigravityDiagnosticRow(
                                title: "최근 조회",
                                value: "\(lastUsageSource.displayName) · \(lastUsage?.hasUsageWindows == true ? "quota 조회됨" : "수치 없음")"
                            )
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.caption)
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.45))
            .cornerRadius(8)
        }
    }

    private func refreshAntigravityEnvironmentState() {
        antigravityOAuthSettings.refreshAccounts()
        ProviderEnvironmentDetector.invalidateCache(for: .antigravity)
        ProviderEnvironmentDetector.refreshStatusInBackground(for: .antigravity)
        ProviderEnvironmentDetector.refreshAntigravitySignalsInBackground()
        AntigravityStatusProbe.refreshAllInBackground()
        runtimeEnvironmentRefreshTick &+= 1
        onRefreshAntigravityUsage?()
    }

    private func antigravityStatusTitle(
        lastUsage: AntigravityUsageResponse?,
        credentialStatus: AntigravityOAuthCredentialStatus?,
        signals: AntigravityEnvironmentSignals?
    ) -> String {
        if lastUsage?.hasUsageWindows == true {
            return "Model quota 조회됨"
        }
        if lastUsage != nil || credentialStatus?.hasCredential == true {
            return "계정 확인됨"
        }
        if signals?.hasRuntimeConnection == true || signals?.hasCLIBinary == true {
            return "사용량 조회 준비"
        }
        return signals == nil ? "상태 확인 중" : "연결 필요"
    }

    private func antigravityStatusDetail(
        lastUsage: AntigravityUsageResponse?,
        credentialStatus: AntigravityOAuthCredentialStatus?,
        signals: AntigravityEnvironmentSignals?
    ) -> String {
        if let lastUsage, lastUsage.hasUsageWindows {
            return "Antigravity model quota를 조회했습니다."
        }
        if lastUsage != nil {
            return "계정은 확인됐지만 사용량 수치는 아직 제공되지 않았습니다. 자동 조회가 다시 시도합니다."
        }
        if credentialStatus?.hasCredential == true {
            return "Google 계정은 연결됐고 사용량 수치를 확인하는 중입니다."
        }
        if signals?.hasCLIBinary == true || signals?.hasRuntimeConnection == true {
            return "사용량 조회 준비가 감지됐습니다. 새로고침하면 다시 확인합니다."
        }
        return "Antigravity 앱 로그인 또는 Google 계정 연결이 필요합니다."
    }

    private func antigravityAccountLine(
        lastUsage: AntigravityUsageResponse?,
        credentialStatus: AntigravityOAuthCredentialStatus?
    ) -> String? {
        let email = lastUsage?.accountEmail ?? credentialStatus?.email
        let plan = lastUsage?.accountPlan
        switch (email, plan) {
        case let (.some(email), .some(plan)):
            return "\(email) · \(plan)"
        case let (.some(email), .none):
            return email
        case (.none, .some(let plan)):
            return plan
        case (.none, .none):
            return nil
        }
    }

    @ViewBuilder
    private func antigravityDiagnosticRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .leading)
            Text(value)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private func antigravityCLIDiagnosticSummary(
        cliBinaryStatus: AntigravityCLIBinaryStatus,
        hasCLISettingsFile: Bool,
        hasCLIStateDirectory: Bool,
        isLoading: Bool
    ) -> String {
        if cliBinaryStatus.isBroken {
            return "복구 필요"
        }
        if cliBinaryStatus.isRunnable {
            return "사용 가능"
        }
        if hasCLISettingsFile || hasCLIStateDirectory {
            return "설정만 감지"
        }
        return isLoading ? "확인 중" : "미감지"
    }
}
