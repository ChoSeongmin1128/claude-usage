import AppKit
import SwiftUI

extension SettingsView {
    var commonDisplaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("공통 표시", systemImage: "paintbrush")
                .font(.headline)

            settingsToggleRow("메뉴바 보조 텍스트 강조", isOn: $settings.menuBarTextHighContrast)
            Text("메뉴바의 리셋 시간, 구분자 등을 기본 텍스트와 동일한 색상으로 표시")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    var refreshSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("새로고침", systemImage: "arrow.clockwise")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("간격:")
                        .font(.subheadline)
                    TextField("30", text: $refreshIntervalText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(
                                    !refreshIntervalText.isEmpty && !isRefreshIntervalValid ? Color.red : Color.clear,
                                    lineWidth: 1
                                )
                        )
                        .onChange(of: refreshIntervalText) { _, newValue in
                            if let val = TimeInterval(newValue), val >= 5, val <= 120 {
                                settings.refreshInterval = val
                            }
                        }
                    Text("초")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !refreshIntervalText.isEmpty && !isRefreshIntervalValid {
                    Label("5~120 사이의 값을 입력하세요", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                settingsToggleRow("자동 새로고침", isOn: $settings.autoRefresh)
            }
        }
    }

    var commonAlertSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("알림", systemImage: "bell")
                .font(.headline)

            settingsToggleRow("전체 알림 사용", isOn: $settings.notificationsEnabled)

            if !settings.notificationsEnabled {
                Label("전체 알림이 꺼져 있어 Claude/Codex 알림이 모두 중지됩니다.", systemImage: "bell.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Provider 알림")
                    .font(.subheadline.weight(.semibold))

                ForEach(AppProviderKind.runtimeKinds, id: \.self) { provider in
                    settingsToggleRow(
                        "\(provider.displayName) 알림 사용",
                        isOn: Binding(
                            get: { settings.isProviderAlertEnabled(provider) },
                            set: { settings.setProviderAlertEnabled($0, for: provider) }
                        )
                    )
                }

                Text("퍼센트 프리셋은 모든 runtime provider가 공통으로 사용하고, 여기서는 provider별 발송 여부만 켜고 끕니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let claudeNotificationPolicySummary {
                    Text(claudeNotificationPolicySummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!settings.notificationsEnabled)
            .opacity(settings.notificationsEnabled ? 1.0 : 0.6)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("공통 알림 프리셋")
                    .font(.subheadline.weight(.semibold))
                ForEach(Array(settings.sortedNotificationPresets.enumerated()), id: \.element.id) { index, preset in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { preset.isEnabled },
                            set: { newValue in
                                updateNotificationPreset(id: preset.id) { $0.isEnabled = newValue }
                            }
                        ))
                        .labelsHidden()

                        TextField("", text: Binding(
                            get: { index < alertPresetTexts.count ? alertPresetTexts[index] : String(preset.threshold) },
                            set: { newValue in
                                guard index < alertPresetTexts.count else { return }
                                alertPresetTexts[index] = newValue
                                if let threshold = Int(newValue), (1...100).contains(threshold) {
                                    updateNotificationPreset(id: preset.id) { $0.threshold = threshold }
                                }
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 52)

                        Text(settings.alertRemainingMode ? "% 남았을 때" : "% 사용 시")
                            .font(.subheadline)

                        Spacer()

                        Button {
                            removeNotificationPreset(id: preset.id)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red.opacity(0.7))
                        }
                        .buttonStyle(.borderless)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        addNotificationPreset()
                    } label: {
                        Label("프리셋 추가", systemImage: "plus.circle.fill")
                            .font(.subheadline)
                    }
                    .buttonStyle(.borderless)

                    Picker("기준:", selection: $settings.alertRemainingMode) {
                        Text("사용량").tag(false)
                        Text("남은 사용량").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    .onChange(of: settings.alertRemainingMode) { _, _ in
                        settings.notificationPresets = settings.notificationPresets.map {
                            NotificationPreset(
                                id: $0.id,
                                threshold: max(1, min(100 - $0.threshold, 99)),
                                isEnabled: $0.isEnabled
                            )
                        }
                        alertPresetTexts = settings.sortedNotificationPresets.map { String($0.threshold) }
                    }
                }

                settingsToggleRow("현재 세션 알림", isOn: $settings.alertFiveHourEnabled)
                settingsToggleRow("주간 세션 알림", isOn: $settings.alertWeeklyEnabled)
            }
            .disabled(!settings.notificationsEnabled)
            .opacity(settings.notificationsEnabled ? 1.0 : 0.6)

            Divider()

            Text("시스템 설정 → 알림 → ClaudeUsage에서 알림을 허용해야 합니다.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    var powerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("절전 모드", systemImage: "battery.75percent")
                .font(.headline)

            settingsToggleRow("배터리 사용 시 새로고침 감소", isOn: $settings.reducedRefreshOnBattery)

            Text("배터리 모드에서 새로고침 간격이 최소 60초로 제한됩니다")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    func refreshUpdateEnginePresentation() {
        Task {
            let modeSummary = await UpdateService.shared.currentModeSummary()
            let engineStatus = await UpdateService.shared.currentEngineStatus()
            let supportsInteractive = await UpdateService.shared.supportsInteractiveCheck()
            await MainActor.run {
                updateModeSummary = modeSummary
                updateEngineStatus = engineStatus
                supportsInteractiveUpdates = supportsInteractive
            }
        }
    }

    var updateSection: some View {
        UpdateDiagnosticsSectionShell(updateModeSummary: updateModeSummary) {
            Picker("자동 확인", selection: $settings.updateCheckInterval) {
                ForEach(UpdateCheckInterval.allCases, id: \.self) { interval in
                    Text(interval.displayName).tag(interval)
                }
            }
            .pickerStyle(.segmented)

            if supportsInteractiveUpdates {
                Text("현재 빌드는 Sparkle 앱내 확인을 지원하지만, 자동 확인 주기는 앱이 계속 관리합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
                Text("현재 버전: v\(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if isCheckingUpdate {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(supportsInteractiveUpdates ? "Sparkle로 확인" : "지금 확인") {
                        isCheckingUpdate = true
                        updateCheckResult = nil
                        Task {
                            if supportsInteractiveUpdates {
                                let message = await UpdateService.shared.performInteractiveCheck()
                                await MainActor.run {
                                    isCheckingUpdate = false
                                    updateCheckResult = message ?? "Sparkle 업데이트 확인을 시작했습니다"
                                }
                                refreshUpdateEnginePresentation()
                            } else {
                                let result = await UpdateService.shared.checkForUpdates()
                                await MainActor.run {
                                    isCheckingUpdate = false
                                    switch result {
                                    case .available(let info):
                                        updateCheckResult = "v\(info.version) 업데이트 가능"
                                        AppSettings.shared.availableUpdate = info
                                    case .upToDate:
                                        updateCheckResult = "최신 버전입니다"
                                        AppSettings.shared.availableUpdate = nil
                                    case .error(let msg):
                                        updateCheckResult = "확인 실패: \(msg)"
                                    }
                                }
                                refreshUpdateEnginePresentation()
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if let updateEngineStatus {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        chip(
                            title: "엔진",
                            value: updateEngineChipValue,
                            color: updateEngineChipColor
                        )
                        chip(
                            title: "appcast",
                            value: updateEngineStatus.feedConfigured ? "준비됨" : "미설정",
                            color: updateEngineStatus.feedConfigured ? .green : .orange
                        )
                        chip(
                            title: "공개키",
                            value: updateEngineStatus.publicKeyConfigured ? "준비됨" : "미설정",
                            color: updateEngineStatus.publicKeyConfigured ? .green : .orange
                        )
                    }

                    Text(updateReadinessSummary(updateEngineStatus))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.45))
                .cornerRadius(8)

                if !updateEngineStatus.usesSparkleReadyPath {
                    DisclosureGroup(isExpanded: $isUpdateGuidanceExpanded) {
                        VStack(alignment: .leading, spacing: 6) {
                            if !updateEngineStatus.missingSparkleRequirements.isEmpty {
                                Text("아직 필요한 항목: \(updateEngineStatus.missingSparkleRequirements.joined(separator: ", "))")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }

                            Text("1. release xcconfig에서 `SUFeedURL`, `SUPublicEDKey`를 채웁니다.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("2. `Scripts/build-notarize-release.sh`로 notarized ZIP을 만듭니다.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("3. `Scripts/generate-sparkle-appcast.sh`로 appcast.xml을 생성하고 함께 배포합니다.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                    } label: {
                        Text("Sparkle 전환 다음 단계 보기")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let result = updateCheckResult {
                HStack {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.contains("가능") ? .orange : result.contains("실패") ? .red : .green)
                    if result.contains("가능") && !supportsInteractiveUpdates {
                        Button("다운로드") {
                            Task {
                                let url = await UpdateService.shared.latestDownloadURL()
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("업데이트 설치 가이드")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if supportsInteractiveUpdates {
                    Text("1. 'Sparkle로 확인'을 누르면 앱 내부에서 업데이트 확인을 시작합니다.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("2. 새 버전이 있으면 Sparkle 설치 안내가 열리고, 없으면 조용히 유지됩니다.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("3. appcast/feed가 아직 설정되지 않은 빌드에서는 GitHub Release 엔진으로 자동 fallback됩니다.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("1. '다운로드'를 눌러 최신 앱을 받습니다.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("2. 실행 중인 ClaudeUsage를 완전히 종료합니다.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("3. 기존 앱 파일을 새 앱으로 교체(덮어쓰기)합니다.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("4. 다시 실행합니다. 최초 실행에서 차단되면 시스템 설정 > 개인정보 보호 및 보안 > 그래도 열기를 선택하세요.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(8)
        }
    }

    private var updateEngineChipValue: String {
        guard let updateEngineStatus else {
            return "확인 중"
        }
        if updateEngineStatus.usesSparkleReadyPath {
            return "Sparkle 확인 가능"
        }
        if updateEngineStatus.sparkleIntegrated {
            return "GitHub fallback"
        }
        return "GitHub 전용"
    }

    private var updateEngineChipColor: Color {
        guard let updateEngineStatus else {
            return .secondary
        }
        return updateEngineStatus.usesSparkleReadyPath ? .blue : .orange
    }

    private func updateReadinessSummary(_ status: UpdateEngineStatus) -> String {
        if status.usesSparkleReadyPath {
            return "현재 빌드는 Sparkle 앱내 확인을 지원하고, 자동 확인 주기는 앱 설정을 계속 사용합니다."
        }
        if status.sparkleIntegrated {
            return "Sparkle 패키지는 포함됐지만 appcast 또는 공개키가 없어 아직 GitHub fallback을 사용합니다."
        }
        return "현재 빌드는 GitHub Release 수동 다운로드 경로를 사용합니다."
    }

    var generalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("일반", systemImage: "gearshape.2")
                .font(.headline)

            providerOverviewCard

            settingsToggleRow("로그인 시 자동 시작", isOn: $settings.launchAtLogin)

            Text("시스템 설정 → 일반 → 로그인 항목에서도 관리할 수 있습니다")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var providerOverviewCard: some View {
        let selectionState = settings.providerSelectionState
        let items = AppProviderKind.allCases.map { provider in
            ProviderOverviewCardView.Item(
                id: provider.rawValue,
                title: provider.displayName,
                isEnabled: settings.isProviderEnabled(provider),
                isActive: settings.providerState(for: provider).isActive,
                summary: providerRuntimeSummary(provider, selectionState: selectionState)
            )
        }
        return ProviderOverviewCardView(
            title: "Provider 상태",
            subtitle: "활성 \(selectionState.enabledKinds.count) · 실동작 \(selectionState.runtimeEnabledKinds.count)",
            items: items
        )
    }

    private func providerRuntimeSummary(_ provider: AppProviderKind, selectionState: ProviderSelectionState) -> String {
        if !settings.isProviderEnabled(provider) {
            return "비활성화됨"
        }

        if provider.isRuntimeProvider {
            if selectionState.activeRuntimeKind == provider {
                return "활성 · 기본"
            }

            switch provider {
            case .claude:
                if !hasReadyClaudeCredential {
                    return "인증 필요"
                }
                return "활성"
            case .codex:
                return CodexAuthManager.shared.isAuthenticated ? "활성" : "인증 필요"
            case .gemini:
                if ProviderEnvironmentDetector.requiresInteractiveSetup(for: .gemini) {
                    return "로그인 필요"
                }
                return "활성"
            case .antigravity:
                if ProviderEnvironmentDetector.requiresInteractiveSetup(for: .antigravity) {
                    return "앱 실행 필요"
                }
                return "활성"
            }
        }
        return "활성 예정"
    }

    func shellSectionFootnote(for provider: AppProviderKind, selectionState: ProviderSelectionState) -> String {
        if provider.isRuntimeProvider {
            if settings.isProviderEnabled(provider) {
                return "이 provider는 활성화 즉시 메뉴바와 조회 경로에 연결됩니다."
            }
            return "활성화하면 메뉴바와 조회 경로에 바로 연결됩니다."
        }

        let environmentStatus = ProviderEnvironmentDetector.status(for: provider)

        if selectionState.shellEnabledKinds.contains(provider) {
            if let environmentStatus, environmentStatus.isDetected {
                return "로컬 환경은 감지됐고 다음 연결 단계만 남아 있습니다."
            }
            return "활성화 상태는 저장되지만 실제 조회 연결은 다음 단계에서 열립니다."
        }

        if let environmentStatus, environmentStatus.isDetected {
            return "로컬 환경이 이미 감지됩니다. 활성화하면 다음 단계에서 이 상태를 이어받습니다."
        }

        return "아직 연결 준비가 필요합니다. 환경이 준비되면 여기서 바로 활성화할 수 있습니다."
    }
}
