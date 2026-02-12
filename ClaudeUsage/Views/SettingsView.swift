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
    @State private var alertTexts: [String] = []
    @State private var snapshot: AppSettings.Snapshot?
    @State private var didSave = false

    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?
    var onOpenLogin: (() -> Void)?
    var onOpenLoginNewAccount: (() -> Void)?

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
        VStack(spacing: 0) {
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

                    Divider()

                    // 업데이트 섹션
                    updateSection
                }
                .padding(24)
            }

            // 하단 버튼
            HStack {
                Button("기본값 복원") { resetToDefaults() }
                    .foregroundStyle(.secondary)
                Spacer()
                Button("취소") { onCancel?() }
                    .keyboardShortcut(.cancelAction)
                Button("저장") { didSave = true; save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .frame(width: 420, height: 580)
        .onAppear {
            snapshot = settings.createSnapshot()
            if let key = KeychainManager.shared.load() {
                sessionKey = key
                // 세션 키 유효성 자동 확인
                testConnection()
            }
            refreshIntervalText = String(Int(settings.refreshInterval))
            alertTexts = settings.alertThresholds.map { String($0) }
        }
        .onDisappear {
            if !didSave, let snapshot = snapshot {
                settings.restore(from: snapshot)
            }
        }
    }

    // MARK: - 인증 섹션

    private var authSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("인증", systemImage: "key")
                .font(.headline)

            if !sessionKey.isEmpty {
                // 세션 키 존재
                HStack(spacing: 8) {
                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                        Text("확인 중...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let result = testResult {
                        switch result {
                        case .success:
                            Label("연결 확인됨", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .failure(let msg):
                            Label(msg, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        }
                    } else {
                        Label("세션 키 설정됨", systemImage: "key.fill")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("다시 로그인") { onOpenLogin?() }
                    Button("계정 변경") { onOpenLoginNewAccount?() }
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

    private var isBatteryWithPercent: Bool {
        settings.menuBarStyle == .batteryBar || settings.menuBarStyle == .sideBySideBattery
    }

    private var styleDescription: String? {
        switch settings.menuBarStyle {
        case .none: return nil
        case .batteryBar: return "남은 사용량을 배터리 형태로 표시"
        case .circular: return "원형 링이 채워진 만큼이 사용량"
        case .concentricRings: return "바깥 링: 현재 세션 · 안쪽 링: 주간"
        case .dualBattery: return "위: 현재 세션 · 아래: 주간"
        case .sideBySideBattery: return "왼쪽: 현재 세션 · 오른쪽: 주간"
        }
    }

    private var isCircularStyle: Bool {
        settings.menuBarStyle == .circular || settings.menuBarStyle == .concentricRings
    }

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("디스플레이", systemImage: "paintbrush")
                    .font(.headline)
                Spacer()
                Text("실시간 미리보기")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Claude 아이콘", isOn: $settings.showClaudeIcon)
                Picker("퍼센트:", selection: $settings.percentageDisplay) {
                    ForEach(PercentageDisplay.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Picker("리셋 시간:", selection: $settings.resetTimeDisplay) {
                    ForEach(ResetTimeDisplay.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                if settings.resetTimeDisplay != .none {
                    Picker("시간 형식:", selection: $settings.timeFormat) {
                        ForEach(TimeFormatStyle.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                }

                Divider()

                Picker("아이콘:", selection: $settings.menuBarStyle) {
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
                .onChange(of: settings.menuBarStyle) { _, newValue in
                    if newValue == .batteryBar || newValue == .dualBattery || newValue == .sideBySideBattery {
                        settings.circularDisplayMode = .remaining
                    } else if newValue == .none {
                        settings.circularDisplayMode = .usage
                    }
                }

                if let desc = styleDescription {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }

                // 배터리 하위: 내부 숫자
                if isBatteryWithPercent {
                    Toggle("배터리 내부 숫자", isOn: $settings.showBatteryPercent)
                        .padding(.leading, 20)
                }

                // 원형 하위: 표시 기준
                if isCircularStyle {
                    Picker("표시 기준:", selection: $settings.circularDisplayMode) {
                        ForEach(CircularDisplayMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .padding(.leading, 20)
                }
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
                ForEach(Array(settings.alertThresholds.indices), id: \.self) { index in
                    HStack(spacing: 8) {
                        TextField("", text: Binding(
                            get: { index < alertTexts.count ? alertTexts[index] : "" },
                            set: { newValue in
                                guard index < alertTexts.count else { return }
                                alertTexts[index] = newValue
                                if let val = Int(newValue), val >= 1, val <= 100 {
                                    settings.alertThresholds[index] = val
                                }
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 50)

                        Text(settings.alertRemainingMode ? "% 남았을 때 알림" : "% 사용 시 알림")
                            .font(.subheadline)

                        Spacer()

                        Button {
                            settings.alertThresholds.remove(at: index)
                            alertTexts.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red.opacity(0.7))
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Button {
                    let next = suggestNextThreshold()
                    settings.alertThresholds.append(next)
                    alertTexts.append(String(next))
                } label: {
                    Label("임계값 추가", systemImage: "plus.circle.fill")
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)

                Picker("기준:", selection: $settings.alertRemainingMode) {
                    Text("사용량").tag(false)
                    Text("남은 사용량").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .onChange(of: settings.alertRemainingMode) { _, _ in
                    settings.alertThresholds = settings.alertThresholds.map { max(1, min(100 - $0, 99)) }
                    alertTexts = settings.alertThresholds.map { String($0) }
                }

                Divider()

                Text("알림 대상")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Toggle("현재 세션", isOn: $settings.alertFiveHourEnabled)
                Toggle("주간 세션", isOn: $settings.alertWeeklyEnabled)

                Divider()

                Text("시스템 설정 → 알림 → ClaudeUsage에서 알림을 허용해야 합니다.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func suggestNextThreshold() -> Int {
        let existing = settings.alertThresholds.sorted()
        if existing.isEmpty { return 75 }
        let candidates = [50, 60, 70, 75, 80, 85, 90, 95, 100]
        for c in candidates where !existing.contains(c) {
            return c
        }
        return min((existing.last ?? 90) + 5, 100)
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

    // MARK: - 업데이트 섹션

    @State private var isCheckingUpdate = false
    @State private var updateCheckResult: String?

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("업데이트", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)

            Toggle("앱 시작 시 자동 확인", isOn: $settings.autoCheckUpdates)

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
                    Button("지금 확인") {
                        isCheckingUpdate = true
                        updateCheckResult = nil
                        Task {
                            let update = await UpdateService.shared.checkForUpdates()
                            await MainActor.run {
                                isCheckingUpdate = false
                                if let update {
                                    updateCheckResult = "v\(update.version) 업데이트 가능"
                                } else {
                                    updateCheckResult = "최신 버전입니다"
                                }
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if let result = updateCheckResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(result.contains("가능") ? .orange : .green)
            }
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
                    // 연결 성공 시 자동 저장
                    do {
                        try KeychainManager.shared.save(sessionKey)
                        Logger.info("연결 테스트 성공, 세션 키 자동 저장됨")
                    } catch {
                        Logger.error("세션 키 저장 실패: \(error)")
                    }
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
        alertTexts = settings.alertThresholds.map { String($0) }
    }
}
