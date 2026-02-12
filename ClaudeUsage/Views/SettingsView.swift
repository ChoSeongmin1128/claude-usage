//
//  SettingsView.swift
//  ClaudeUsage
//
//  Phase 3: 완전한 설정 창
//

import SwiftUI
import Combine

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var sessionKey: String = ""
    @State private var testResult: TestResult?
    @State private var isTesting: Bool = false
    @State private var refreshIntervalText: String = ""
    @State private var showKeyHelp: Bool = false
    @State private var alert1Text: String = ""
    @State private var alert2Text: String = ""
    @State private var alert3Text: String = ""

    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?
    var onOpenLogin: (() -> Void)?

    enum TestResult {
        case success
        case failure(String)
    }

    private var isRefreshIntervalValid: Bool {
        guard let val = Int(refreshIntervalText) else { return false }
        return val >= 5 && val <= 120
    }

    private var sessionKeyFormatWarning: String? {
        guard !sessionKey.isEmpty else { return nil }
        if !sessionKey.hasPrefix("sk-ant-sid01-") {
            return "세션 키는 보통 sk-ant-sid01-로 시작합니다"
        }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // 인증 섹션
                authSection

                Divider()

                // 디스플레이 섹션
                displaySection

                Divider()

                // 새로고침 섹션
                refreshSection

                Divider()

                // 알림 섹션
                alertSection

                Divider()

                // 절전 섹션
                powerSection
            }
            .padding(24)
        }
        .frame(width: 420, height: 560)
        .onAppear {
            if let key = KeychainManager.shared.load() {
                sessionKey = key
            }
            refreshIntervalText = String(Int(settings.refreshInterval))
            alert1Text = String(settings.alert1Threshold)
            alert2Text = String(settings.alert2Threshold)
            alert3Text = String(settings.alert3Threshold)
        }

        // 하단 버튼
        HStack {
            Button("기본값 복원") { resetToDefaults() }
                .foregroundStyle(.secondary)
            Spacer()
            Button("취소") { onCancel?() }
                .keyboardShortcut(.cancelAction)
            Button("저장") { save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    // MARK: - 인증 섹션

    private var authSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("인증", systemImage: "key")
                .font(.headline)

            if !sessionKey.isEmpty {
                // 로그인 상태
                HStack(spacing: 8) {
                    Label("로그인됨", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("다시 로그인") { onOpenLogin?() }
                }
                Text("세션 키: \(String(sessionKey.prefix(20)))...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // 미로그인 상태
                Button(action: { onOpenLogin?() }) {
                    Label("Claude 로그인", systemImage: "person.crop.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("claude.ai에 로그인하여 세션 키를 자동으로 가져옵니다")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 고급 옵션: 수동 세션 키 입력
            DisclosureGroup("고급 옵션") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        Text("세션 키 직접 입력")
                            .font(.subheadline)
                        Button(action: { showKeyHelp.toggle() }) {
                            Image(systemName: "questionmark.circle")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 14))
                        }
                        .buttonStyle(.borderless)
                        .popover(isPresented: $showKeyHelp) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("세션 키 가져오는 방법")
                                    .font(.headline)
                                Text("1. claude.ai에 로그인")
                                Text("2. ⌘⌥I (Cmd+Opt+I)로 개발자 도구 열기")
                                Text("3. Application 탭 → Cookies → https://claude.ai")
                                Text("4. sessionKey의 값을 복사")
                            }
                            .font(.callout)
                            .padding(16)
                            .frame(width: 320)
                        }
                    }

                    TextField("sk-ant-sid01-...", text: $sessionKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))

                    if let warning = sessionKeyFormatWarning {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    HStack {
                        Button("연결 테스트") { testConnection() }
                            .disabled(sessionKey.isEmpty || isTesting)

                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                        }

                        if let result = testResult {
                            switch result {
                            case .success:
                                Label("연결 성공", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                            case .failure(let msg):
                                Label(msg, systemImage: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
            .font(.subheadline)
        }
    }

    // MARK: - 디스플레이 섹션

    private var isIndividualStyle: Bool {
        settings.menuBarStyle == .batteryBar || settings.menuBarStyle == .circular
    }

    private var isDualStyle: Bool {
        settings.menuBarStyle.isDualStyle
    }

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("디스플레이", systemImage: "paintbrush")
                    .font(.headline)
                Spacer()
                Text("변경 즉시 반영")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("추가 아이콘:")
                    .font(.subheadline)

                // 없음
                styleRadioButton(.none)

                // 개별 세션
                categoryRadioButton(
                    label: "개별 세션",
                    isSelected: isIndividualStyle,
                    action: { settings.menuBarStyle = .batteryBar }
                )
                if isIndividualStyle {
                    VStack(alignment: .leading, spacing: 6) {
                        // 배터리바
                        styleRadioButton(.batteryBar)
                        if settings.menuBarStyle == .batteryBar {
                            VStack(alignment: .leading, spacing: 4) {
                                Toggle("배터리 내부 퍼센트", isOn: $settings.showBatteryPercent)
                                Text("남은 사용량을 배터리 형태로 표시합니다")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.leading, 24)
                        }

                        // 원형
                        styleRadioButton(.circular)
                        if settings.menuBarStyle == .circular {
                            VStack(alignment: .leading, spacing: 4) {
                                Picker("표시 기준:", selection: $settings.circularDisplayMode) {
                                    ForEach(CircularDisplayMode.allCases, id: \.self) { mode in
                                        Text(mode.displayName).tag(mode)
                                    }
                                }
                                .pickerStyle(.radioGroup)
                                Text("원형 링이 채워진 만큼이 선택한 기준값입니다")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.leading, 24)
                        }
                    }
                    .padding(.leading, 24)
                }

                // 동시 표시
                categoryRadioButton(
                    label: "동시 표시",
                    isSelected: isDualStyle,
                    action: {
                        settings.menuBarStyle = .concentricRings
                        settings.showDualPercentage = true
                    }
                )
                if isDualStyle {
                    VStack(alignment: .leading, spacing: 6) {
                        styleRadioButton(.concentricRings)
                        if settings.menuBarStyle == .concentricRings {
                            Text("바깥 링: 5시간 세션 · 안쪽 링: 주간 한도")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 24)
                        }

                        styleRadioButton(.dualBattery)
                        if settings.menuBarStyle == .dualBattery {
                            Text("위: 5시간 세션 · 아래: 주간 한도")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 24)
                        }

                        styleRadioButton(.sideBySideBattery)
                        if settings.menuBarStyle == .sideBySideBattery {
                            Text("왼쪽: 5시간 세션 · 오른쪽: 주간 한도")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 24)
                        }
                    }
                    .padding(.leading, 24)
                }

                Toggle("퍼센트 표시", isOn: $settings.showPercentage)
                if settings.showPercentage {
                    Toggle("동시 퍼센트 표시 (67/45%)", isOn: $settings.showDualPercentage)
                        .padding(.leading, 24)
                }
                Toggle("리셋 시간 표시", isOn: $settings.showResetTime)

                if settings.showResetTime {
                    Picker("시간 형식:", selection: $settings.timeFormat) {
                        ForEach(TimeFormatStyle.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .pickerStyle(.radioGroup)
                }

                Text("Claude 아이콘은 항상 표시됩니다")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 새로고침 섹션

    private var refreshSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("새로고침", systemImage: "arrow.clockwise")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("간격:")
                        .font(.subheadline)
                    TextField("5", text: $refreshIntervalText)
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

                Toggle("자동 새로고침", isOn: $settings.autoRefresh)
            }
        }
    }

    // MARK: - 알림 섹션

    private var alertSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("알림", systemImage: "bell")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                alertThresholdRow(enabled: $settings.alert1Enabled, threshold: $settings.alert1Threshold, text: $alert1Text)
                alertThresholdRow(enabled: $settings.alert2Enabled, threshold: $settings.alert2Threshold, text: $alert2Text)
                alertThresholdRow(enabled: $settings.alert3Enabled, threshold: $settings.alert3Threshold, text: $alert3Text)

                Text("설정한 사용량에 도달하면 알림을 보냅니다")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func alertThresholdRow(enabled: Binding<Bool>, threshold: Binding<Int>, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: enabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 50)
                .onChange(of: text.wrappedValue) { _, newValue in
                    if let val = Int(newValue), val >= 1, val <= 100 {
                        threshold.wrappedValue = val
                    }
                }
                .disabled(!enabled.wrappedValue)
            Text("% 도달 시 알림")
                .font(.subheadline)
                .foregroundStyle(enabled.wrappedValue ? .primary : .secondary)
        }
    }

    // MARK: - 스타일 라디오 버튼

    private func styleRadioButton(_ style: MenuBarStyle) -> some View {
        Button(action: { settings.menuBarStyle = style }) {
            HStack(spacing: 6) {
                Image(systemName: settings.menuBarStyle == style ? "circle.inset.filled" : "circle")
                    .foregroundColor(settings.menuBarStyle == style ? .accentColor : .secondary)
                    .font(.system(size: 14))
                Text(style.displayName)
            }
        }
        .buttonStyle(.plain)
    }

    private func categoryRadioButton(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .font(.system(size: 14))
                Text(label)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 절전 섹션

    private var powerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("절전 모드", systemImage: "battery.75percent")
                .font(.headline)

            Toggle("배터리 사용 시 새로고침 감소", isOn: $settings.reducedRefreshOnBattery)

            Text("배터리 모드에서 새로고침 간격이 30초로 변경됩니다")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func testConnection() {
        guard !sessionKey.isEmpty else { return }
        isTesting = true
        testResult = nil

        Task {
            do {
                let service = ClaudeAPIService(sessionKey: sessionKey)
                let _ = try await service.fetchUsage()
                await MainActor.run {
                    testResult = .success
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testResult = .failure(error.localizedDescription)
                    isTesting = false
                }
            }
        }
    }

    private func save() {
        // 세션 키 저장
        if !sessionKey.isEmpty {
            do {
                try KeychainManager.shared.save(sessionKey)
            } catch {
                Logger.error("세션 키 저장 실패: \(error)")
            }
        }

        // 새로고침 간격 유효성
        if let val = TimeInterval(refreshIntervalText), val >= 5, val <= 120 {
            settings.refreshInterval = val
        }

        onSave?()
    }

    private func resetToDefaults() {
        settings.resetToDefaults()
        refreshIntervalText = String(Int(settings.refreshInterval))
        alert1Text = String(settings.alert1Threshold)
        alert2Text = String(settings.alert2Threshold)
        alert3Text = String(settings.alert3Threshold)
    }
}
