import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    var codexAuthSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Codex 인증", systemImage: "bubble.left.and.bubble.right")
                .font(.headline)

            settingsToggleRow(
                "Codex 모니터링 활성화",
                isOn: Binding(
                    get: { settings.isProviderEnabled(.codex) },
                    set: { settings.setProviderEnabled($0, for: .codex) }
                )
            )

            if settings.isProviderEnabled(.codex) {
                HStack(spacing: 8) {
                    switch codexAuthStatus {
                    case .checking:
                        ProgressView()
                            .controlSize(.small)
                        Text("확인 중...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .authenticated:
                        Label("연결됨 (auth.json)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .expired:
                        Label("토큰 만료됨", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    case .notInstalled:
                        Label("Codex CLI 미설치", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    case .notLoggedIn:
                        Label("로그인 필요", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                }

                if codexAuthStatus == .notInstalled {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Codex CLI를 먼저 설치하세요:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        codexCommandRow("brew install --cask codex", label: "Homebrew")
                        codexCommandRow("npm i -g @openai/codex", label: "npm")
                    }
                }

                if codexAuthStatus == .notInstalled || codexAuthStatus == .notLoggedIn {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("터미널에서 로그인하세요:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        codexCommandRow("codex login", label: "로그인")
                    }
                }

                if codexAuthStatus == .expired {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("토큰이 만료되었습니다. 다시 로그인하세요:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        codexCommandRow("codex login", label: "재로그인")
                    }
                }

                HStack(spacing: 8) {
                    Button("인증 상태 새로고침") {
                        checkCodexAuth()
                    }

                    if codexAuthStatus == .authenticated {
                        Button("Codex 로그아웃") {
                            onCodexLogout?()
                            checkCodexAuth()
                        }
                        .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private func codexCommandRow(_ command: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(command)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(4)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("\(label) 명령어 복사")
        }
    }

    func checkCodexAuth() {
        if !settings.isProviderEnabled(.codex) {
            codexAuthStatus = .notLoggedIn
            return
        }

        if CodexAuthManager.shared.authJsonExists {
            if let token = CodexAuthManager.shared.getToken() {
                codexAuthStatus = token.isExpired ? .expired : .authenticated
            } else {
                codexAuthStatus = .notLoggedIn
            }
            return
        }

        let codexInstalled = FileManager.default.isExecutableFile(atPath: "/usr/local/bin/codex")
            || FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/codex")
            || FileManager.default.isExecutableFile(atPath: "\(NSHomeDirectory())/.npm-global/bin/codex")
            || {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
                process.arguments = ["codex"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                try? process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            }()

        codexAuthStatus = codexInstalled ? .notLoggedIn : .notInstalled
    }

    var codexDisplaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Codex 표시", systemImage: "slider.horizontal.3")
                .font(.headline)

            settingsToggleRow("Codex 아이콘", isOn: $settings.showCodexIcon)
            Picker("퍼센트:", selection: Binding(
                get: { settings.codexPercentageDisplay },
                set: { settings.codexPercentageDisplay = $0 }
            )) {
                ForEach(PercentageDisplay.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            Picker("리셋 시간:", selection: Binding(
                get: { settings.codexResetTimeDisplay },
                set: { settings.codexResetTimeDisplay = $0 }
            )) {
                ForEach(ResetTimeDisplay.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            if settings.codexResetTimeDisplay != .none {
                Picker("시간 형식:", selection: Binding(
                    get: { settings.codexTimeFormat },
                    set: { settings.codexTimeFormat = $0 }
                )) {
                    ForEach(TimeFormatStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
            }

            Divider()

            Picker("아이콘:", selection: Binding(
                get: { settings.codexMenuBarStyle },
                set: { newValue in
                    settings.codexMenuBarStyle = newValue
                    if newValue.isBatteryStyle {
                        settings.codexCircularDisplayMode = .remaining
                    } else if newValue == .none {
                        settings.codexCircularDisplayMode = .usage
                    }
                }
            )) {
                Text("없음").tag(MenuBarStyle.none)
                Section("개별 세션") {
                    Text("배터리바").tag(MenuBarStyle.batteryBar)
                    Text("원형").tag(MenuBarStyle.circular)
                }
                Section("동시 표시 (현재 세션 + 주간)") {
                    Text("동심원").tag(MenuBarStyle.concentricRings)
                    Text("이중 배터리").tag(MenuBarStyle.dualBattery)
                    Text("좌우 배터리").tag(MenuBarStyle.sideBySideBattery)
                }
            }

            if isCodexBatteryWithPercent {
                settingsToggleRow("배터리 내부 숫자", isOn: $settings.codexShowBatteryPercent)
                    .padding(.leading, 20)
            }
            if isCodexSingleMetricStyle {
                Picker("아이콘 기준:", selection: Binding(
                    get: { settings.codexIconMetric },
                    set: { settings.codexIconMetric = $0 }
                )) {
                    ForEach(IconMetric.allCases, id: \.self) { metric in
                        Text(metric.displayName).tag(metric)
                    }
                }
                .pickerStyle(.radioGroup)
                .padding(.leading, 20)
            }
            if isCodexCircularStyle {
                Picker("표시 기준:", selection: Binding(
                    get: { settings.codexCircularDisplayMode },
                    set: { settings.codexCircularDisplayMode = $0 }
                )) {
                    ForEach(CircularDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .padding(.leading, 20)
            }
        }
    }

    private var isCodexBatteryWithPercent: Bool {
        switch settings.codexMenuBarStyle {
        case .batteryBar, .dualBattery, .sideBySideBattery: return true
        default: return false
        }
    }

    private var isCodexCircularStyle: Bool {
        settings.codexMenuBarStyle != .none
    }

    private var isCodexSingleMetricStyle: Bool {
        settings.codexMenuBarStyle == .batteryBar || settings.codexMenuBarStyle == .circular
    }

    private var isEditingCodexCompact: Bool {
        settings.separateCompactConfig && codexCompactConfigTab == 1
    }

    var codexPopoverItemsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Codex 표시 항목", systemImage: "list.bullet.indent")
                .font(.headline)

            Text("Codex 항목의 표시 여부와 순서를 설정합니다")
                .font(.caption)
                .foregroundStyle(.secondary)

            settingsToggleRow("기본/간소화 개별 설정", isOn: $settings.separateCompactConfig)

            if settings.separateCompactConfig {
                Picker("", selection: $codexCompactConfigTab) {
                    Text("기본").tag(0)
                    Text("간소화").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }

            codexItemsList(isCompact: isEditingCodexCompact)
        }
    }

    private func codexItemsList(isCompact: Bool) -> some View {
        let items = isCompact ? settings.codexCompactPopoverItems : settings.codexPopoverItems
        return VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .frame(width: 14)

                        Button {
                            if isCompact {
                                settings.codexCompactPopoverItems[index].visible.toggle()
                            } else {
                                settings.codexPopoverItems[index].visible.toggle()
                            }
                        } label: {
                            Image(systemName: item.visible ? "eye" : "eye.slash")
                                .foregroundStyle(item.visible ? .primary : .tertiary)
                                .font(.system(size: 12))
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.borderless)

                        Text(item.displayName)
                            .font(.subheadline)
                            .foregroundStyle(item.visible ? .primary : .tertiary)
                        Spacer()
                    }
                    .frame(height: 26)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())

                    if index < items.count - 1 {
                        Divider().padding(.horizontal, 8)
                    }
                }
                .background(codexDraggingItemID == item.id ? Color.accentColor.opacity(0.1) : Color.clear)
                .cornerRadius(4)
                .onDrag {
                    codexDraggingItemID = item.id
                    return NSItemProvider(object: item.id as NSString)
                }
                .onDrop(of: [.text], delegate: PopoverItemDropDelegate(
                    targetID: item.id,
                    settings: settings,
                    isCompact: isCompact,
                    provider: .codex,
                    draggingItemID: $codexDraggingItemID
                ))
            }
        }
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(6)
    }

    var codexAlertSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Codex 알림", systemImage: "bell.badge")
                .font(.headline)

            Text("알림 프리셋과 provider별 발송 여부는 공통 > 알림에서만 관리합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !settings.notificationsEnabled {
                Label("전체 알림이 꺼져 있어 실제 알림은 발송되지 않습니다.", systemImage: "bell.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Button {
                selectedPanel = .common
                selectedCommonTab = .alerts
            } label: {
                Label("공통 알림 설정 열기", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
        }
    }
}
