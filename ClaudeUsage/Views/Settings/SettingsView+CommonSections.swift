import AppKit
import SwiftUI

extension SettingsView {
    var commonDisplaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("공통 표시", systemImage: "paintbrush")
                .font(.headline)

            settingsToggleRow(
                "메뉴바 보조 텍스트 강조",
                subtitle: "리셋 시간, 구분자 등을 기본 텍스트와 동일한 색상으로 표시합니다",
                isOn: $settings.menuBarTextHighContrast
            )

            Divider()

            settingsToggleRow(
                "Claude/Codex 기본·간소화 항목 분리",
                subtitle: "두 provider의 기본 popover 항목과 간소화 popover 항목 순서/표시 여부를 따로 관리합니다",
                isOn: $settings.separateCompactConfig
            )

            Divider()

            settingsToggleRow(
                "간소화 보기",
                subtitle: "팝오버를 간소화된 레이아웃으로 표시합니다",
                isOn: $settings.popoverCompact
            )
            settingsToggleRow(
                "팝오버 고정",
                subtitle: "팝오버가 클릭 시 자동으로 닫히지 않도록 고정합니다",
                isOn: $settings.popoverPinned
            )
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

                settingsToggleRow(
                    "자동 새로고침",
                    subtitle: "설정된 간격으로 사용량을 자동 조회합니다",
                    isOn: $settings.autoRefresh
                )
            }
        }
    }

    var commonAlertSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("알림", systemImage: "bell")
                .font(.headline)

            settingsToggleRow(
                "전체 알림 사용",
                subtitle: "사용량 임계치 도달 시 macOS 알림을 표시합니다",
                isOn: $settings.notificationsEnabled
            )

            if !settings.notificationsEnabled {
                Label("전체 알림이 꺼져 있어 모든 provider 알림이 중지됩니다.", systemImage: "bell.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Provider 알림")
                    .font(.subheadline.weight(.semibold))

                ForEach(AppProviderKind.allCases, id: \.self) { provider in
                    settingsToggleRow(
                        "\(provider.displayName) 알림 사용",
                        isOn: Binding(
                            get: { settings.isProviderAlertEnabled(provider) },
                            set: { settings.setProviderAlertEnabled($0, for: provider) }
                        )
                    )
                }

                Text("퍼센트 프리셋은 모든 provider가 공통으로 사용하고, 여기서는 provider별 발송 여부만 켜고 끕니다.")
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

                settingsToggleRow(
                    "현재 세션 알림",
                    subtitle: "5시간 세션 사용량에 대한 알림입니다",
                    isOn: $settings.alertFiveHourEnabled
                )
                settingsToggleRow(
                    "주간 세션 알림",
                    subtitle: "주간 한도 사용량에 대한 알림입니다",
                    isOn: $settings.alertWeeklyEnabled
                )
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

            settingsToggleRow(
                "배터리 사용 시 새로고침 감소",
                subtitle: "배터리 모드에서 새로고침 간격을 최소 60초로 제한합니다",
                isOn: $settings.reducedRefreshOnBattery
            )
        }
    }

    func refreshUpdateEnginePresentation() {
        updateRuntimeState.refreshEngineStatus()
    }

    var updateSection: some View {
        UpdateDiagnosticsSectionShell(updateModeSummary: updateRuntimeState.modeSummary) {
            Picker("자동 확인", selection: $settings.updateCheckInterval) {
                ForEach(UpdateCheckInterval.allCases, id: \.self) { interval in
                    Text(interval.displayName).tag(interval)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Text("현재 버전: \(updateRuntimeState.currentVersionText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let lastCheckedAt = updateRuntimeState.lastCheckedAt {
                    Text("마지막 확인 \(shortRelativeTimestamp(lastCheckedAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if updateRuntimeState.isChecking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("지금 확인") {
                        updateRuntimeState.checkNow()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!updateRuntimeState.canCheckNow)

                    if updateRuntimeState.showsPrimaryAction {
                        Button(updateRuntimeState.primaryActionTitle) {
                            updateRuntimeState.performPrimaryAction()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!updateRuntimeState.isPrimaryActionEnabled)
                    }
                }
            }

            updateStatusCard

            DisclosureGroup(isExpanded: $isUpdateGuidanceExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    if let updateEngineStatus = updateRuntimeState.engineStatus {
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
                            chip(
                                title: "스케줄러",
                                value: updateRuntimeState.usesExternalScheduler ? "외부" : "앱 내부",
                                color: updateRuntimeState.usesExternalScheduler ? .blue : .secondary
                            )
                        }

                        Text(updateReadinessSummary(updateEngineStatus))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if !updateEngineStatus.usesSparkleReadyPath {
                            if !updateEngineStatus.missingSparkleRequirements.isEmpty {
                                Text("아직 필요한 항목: \(updateEngineStatus.missingSparkleRequirements.joined(separator: ", "))")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }

                            Text("release xcconfig의 `SUFeedURL`과 `SUPublicEDKey`가 준비되면 Sparkle 기본 경로로 승격됩니다.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("고급 진단")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var updateStatusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(updateRuntimeState.statusTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(updateRuntimeState.statusSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    chip(title: "현재", value: updateRuntimeState.currentVersionText, color: .secondary)
                    chip(title: "경로", value: updateEngineChipValue, color: updateEngineChipColor)
                    if let update = updateRuntimeState.latestKnownUpdate {
                        chip(title: "새 버전", value: "v\(update.version)", color: .blue)
                    }
                }
            }

            if let detail = updateRuntimeState.statusDetail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let releaseNotesPreview = updateRuntimeState.releaseNotesPreview {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("릴리즈 노트 미리보기")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(releaseNotesPreview)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
        .padding(12)
        .background(updateStatusColor.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(updateStatusColor.opacity(0.22), lineWidth: 1)
        )
        .cornerRadius(10)
    }

    private var updateEngineChipValue: String {
        guard let updateEngineStatus = updateRuntimeState.engineStatus else {
            return "확인 중"
        }
        if updateEngineStatus.usesSparkleReadyPath {
            return "Sparkle"
        }
        if updateEngineStatus.sparkleIntegrated {
            return "GitHub 보조"
        }
        return "GitHub"
    }

    private var updateEngineChipColor: Color {
        guard let updateEngineStatus = updateRuntimeState.engineStatus else {
            return .secondary
        }
        return updateEngineStatus.usesSparkleReadyPath ? .blue : .orange
    }

    private var updateStatusColor: Color {
        switch updateRuntimeState.tone {
        case .accent:
            return .blue
        case .positive:
            return .green
        case .caution:
            return .orange
        case .destructive:
            return .red
        case .secondary:
            return .secondary
        }
    }

    private func updateReadinessSummary(_ status: UpdateEngineStatus) -> String {
        if status.usesSparkleReadyPath {
            return "현재 빌드는 Sparkle 경로를 사용할 수 있습니다."
        }
        if status.sparkleIntegrated {
            return "Sparkle 패키지는 포함됐지만 appcast 또는 공개키가 아직 부족해 GitHub 보조 경로를 유지합니다."
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
                if ProviderEnvironmentDetector.requiresInteractiveSetupFromCache(for: .gemini) {
                    return "로그인 필요"
                }
                return "활성"
            case .antigravity:
                if ProviderEnvironmentDetector.requiresInteractiveSetupFromCache(for: .antigravity) {
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

        // UI 경로 — SWR 로 캐시만 읽고 blocking 없이 리턴.
        let environmentStatus = ProviderEnvironmentDetector.staleWhileRevalidate(for: provider)

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
