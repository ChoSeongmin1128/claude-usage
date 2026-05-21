import AppKit
import SwiftUI

extension SettingsView {
    @ViewBuilder
    func runtimeProviderPanel(for provider: AppProviderKind) -> some View {
        runtimeProviderOverviewSection(for: provider)
        if provider == .antigravity {
            antigravityDataSourceSection()
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
    private func antigravityDataSourceSection() -> some View {
        let antigravitySignals = ProviderEnvironmentDetector.cachedAntigravitySignals()
        let credentialStatus = antigravitySignals?.oauthCredentialStatus
        let hasLocalOAuthAccount = !antigravityOAuthSettings.accounts.isEmpty
        let hasCLIBinary = antigravitySignals?.hasCLIBinary == true
        let cliBinaryStatus = antigravitySignals?.cliBinaryStatus ?? .missing
        let hasBrokenCLICommand = cliBinaryStatus.isBroken
        let hasCLIStateDirectory = antigravitySignals?.hasCLIStateDirectory == true
        let hasCLISettingsFile = antigravitySignals?.hasCLISettingsFile == true
        let resolvedSourceDetail = RuntimeProviderSettingsPresentation.antigravityResolvedSourceDetail(
            configuredSource: settings.antigravityUsageDataSource,
            lastResolvedSource: antigravityLastUsageSource?()
        )
        let oauthBadgeTitle = credentialStatus.map { $0.hasCredential ? "OAuth 연결됨" : "OAuth 미연결" }
            ?? "OAuth 확인 중"
        let oauthBadgeTone: RuntimeProviderAuthPresentation.BadgeTone = credentialStatus?.hasCredential == true
            ? .blue
            : .secondary
        let cliBadgeTitle = antigravitySignals.map { signals in
            if signals.hasBrokenCLICommand {
                return "CLI 복구 필요"
            }
            if signals.hasCLIBinary {
                return "CLI 감지됨"
            }
            if signals.hasCLISettingsFile {
                return "CLI 설정 감지"
            }
            if signals.hasCLIStateDirectory {
                return "CLI 상태 감지"
            }
            return "CLI 미감지"
        } ?? "CLI 확인 중"
        let cliBadgeTone: RuntimeProviderAuthPresentation.BadgeTone = hasBrokenCLICommand
            ? .red
            : hasCLIBinary
            ? .blue
            : ((hasCLISettingsFile || hasCLIStateDirectory) ? .orange : .secondary)
        RuntimeProviderPanelShell(
            descriptor: SettingsProviderRegistry.providerShellDescriptor(for: .antigravity),
            title: "Antigravity 데이터 소스",
            detail: "Antigravity 2.0과 AGY CLI는 같은 agent harness와 설정을 공유하며, CLI 작업도 같은 계정 quota에 반영되므로 Google OAuth 원격 quota로 확인합니다."
        ) {
            Picker("사용량 조회 방식", selection: Binding(
                get: { settings.antigravityUsageDataSource },
                set: { newValue in
                    settings.antigravityUsageDataSource = newValue
                    refreshAntigravityEnvironmentState()
                }
            )) {
                ForEach(AntigravityUsageDataSource.allCases) { source in
                    Text(source.displayName).tag(source)
                }
            }
            .pickerStyle(.segmented)

            Text(settings.antigravityUsageDataSource.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let resolvedSourceDetail {
                Text(resolvedSourceDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    RuntimeProviderBadgeView(
                        title: oauthBadgeTitle,
                        tone: oauthBadgeTone
                    )
                    RuntimeProviderBadgeView(
                        title: cliBadgeTitle,
                        tone: cliBadgeTone
                    )
                    if let email = credentialStatus?.email {
                        Text(email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }

                Text(antigravityCLIStatusDetail(
                    cliBinaryStatus: cliBinaryStatus,
                    hasCLISettingsFile: hasCLISettingsFile,
                    hasCLIStateDirectory: hasCLIStateDirectory,
                    isLoading: antigravitySignals == nil
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
                    Button(antigravityOAuthSettings.isLoggingIn
                        ? "로그인 진행 중"
                        : (antigravityOAuthSettings.accounts.isEmpty ? "Google OAuth 연결" : "Google 계정 추가"))
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
                        Button(antigravityOAuthSettings.accounts.count > 1 ? "선택 계정 제거" : "OAuth 연결 해제") {
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

    private func antigravityCLIStatusDetail(
        cliBinaryStatus: AntigravityCLIBinaryStatus,
        hasCLISettingsFile: Bool,
        hasCLIStateDirectory: Bool,
        isLoading: Bool
    ) -> String {
        if cliBinaryStatus.isBroken {
            if let target = cliBinaryStatus.brokenTarget {
                return "agy 명령은 PATH에 있지만 대상 실행 파일을 찾지 못했습니다: \(target)"
            }
            return "agy 명령은 PATH에 있지만 현재 실행할 수 없습니다. Antigravity 2.0 또는 CLI를 다시 설치해 주세요."
        }
        let hasCLIBinary = cliBinaryStatus.isRunnable
        if hasCLIBinary && hasCLISettingsFile {
            return "CLI 설정은 ~/.gemini/antigravity-cli/settings.json 기준으로 확인하며, 사용량은 같은 Antigravity quota에 반영됩니다."
        }
        if hasCLIBinary {
            return "AGY CLI는 감지됐지만 settings.json은 아직 없습니다. CLI에서 /config 또는 /settings를 열면 설정 파일이 생성될 수 있습니다."
        }
        if hasCLISettingsFile {
            return "CLI 설정 파일은 감지됐지만 agy 실행 파일은 PATH에서 찾지 못했습니다."
        }
        if hasCLIStateDirectory {
            return "CLI 상태 디렉터리는 감지됐지만 settings.json은 아직 없습니다."
        }
        if isLoading {
            return "Antigravity와 CLI 설치 상태를 확인하는 중입니다."
        }
        return "CLI가 없어도 앱 로컬 API와 OAuth 원격 조회는 사용할 수 있습니다."
    }
}
