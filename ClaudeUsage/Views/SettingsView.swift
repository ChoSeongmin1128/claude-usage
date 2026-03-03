//
//  SettingsView.swift
//  ClaudeUsage
//
//  Phase 3: 완전한 설정 창
//

import SwiftUI
import Combine
import UniformTypeIdentifiers


struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var sessionKey: String = ""
    @State private var storedSessionKey: String?
    @State private var testResult: TestResult?
    @State private var isTesting: Bool = false
    @State private var refreshIntervalText: String = ""
    @State private var showKeyHelp: Bool = false
    @State private var alertTexts: [String] = []
    @State private var snapshot: AppSettings.Snapshot?
    @State private var didSave = false
    @State private var draggingItemID: String?
    @State private var compactConfigTab: Int = 0
    @State private var selectedOrganizationID: String = ""
    @State private var organizations: [ClaudeAPIService.OrganizationSummary] = []
    @State private var organizationPreviews: [ClaudeAPIService.OrganizationPreview] = []
    @State private var isLoadingOrganizations = false
    @State private var isLoadingOrganizationPreviews = false
    @State private var organizationMessage: String?
    @State private var organizationOAuthFallbackSummary: String?

    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?
    var onOpenLogin: (() -> Void)?
    var onLogout: (() -> Void)?

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
        let normalized = normalizeSessionKey(sessionKey)
        if !normalized.hasPrefix("sk-ant-") {
            return "세션 키는 보통 sk-ant-로 시작합니다"
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

                    // 표시 항목 섹션
                    popoverItemsSection

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

                    Divider()

                    // 일반 섹션
                    generalSection
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
                storedSessionKey = key
                sessionKey = key
            } else {
                storedSessionKey = nil
                sessionKey = ""
            }
            testResult = nil
            refreshIntervalText = String(Int(settings.refreshInterval))
            alertTexts = settings.alertThresholds.map { String($0) }
            selectedOrganizationID = settings.preferredOrganizationID
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

            if let storedSessionKey, !storedSessionKey.isEmpty {
                // 저장된 세션 키 존재
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
                        Label("세션 키 저장됨", systemImage: "key.fill")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                HStack(spacing: 8) {
                    Text("세션 키: \(String(storedSessionKey.prefix(20)))...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if case .success = testResult {} else {
                        Button("다시 로그인") { onOpenLogin?() }
                    }
                    Button("로그아웃") { onLogout?() }
                        .foregroundStyle(.red)
                }
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

                    TextField("sk-ant-... 또는 sessionKey=sk-ant-...", text: $sessionKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))

                    Text("입력만으로 로그인 상태가 되지는 않으며, 저장 후 적용됩니다.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

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

            organizationSection
        }
    }

    private var organizationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            Text("Organization 선택")
                .font(.subheadline)

            Text("여러 organization을 사용하는 경우 조회 대상을 선택할 수 있습니다. 비워두면 자동 선택됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("목록 불러오기") { loadOrganizations() }
                    .disabled(isLoadingOrganizations || isLoadingOrganizationPreviews)
                if isLoadingOrganizations || isLoadingOrganizationPreviews {
                    ProgressView()
                        .controlSize(.small)
                }
                if !organizations.isEmpty {
                    Text("\(organizations.count)개")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("자동 선택") {
                    selectedOrganizationID = ""
                }
                .disabled(selectedOrganizationID.isEmpty)
            }

            Picker("조회 대상", selection: $selectedOrganizationID) {
                Text("자동 선택").tag("")
                ForEach(organizations, id: \.id) { org in
                    Text(org.displayName).tag(org.id)
                }
            }
            .labelsHidden()
            .disabled(organizations.isEmpty)

            TextField("Organization UUID 직접 입력 (선택)", text: $selectedOrganizationID)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))

            if !organizationPreviews.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("조회 미리보기")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(organizationPreviews, id: \.id) { preview in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(preview.organization.displayName)
                                .font(.caption)
                                .lineLimit(1)

                            if let err = preview.usageErrorMessage {
                                Text("조회 실패: \(err)")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            } else {
                                let fiveHour = preview.fiveHourPercentage.map { String(format: "%.0f%%", $0) } ?? "-"
                                let weekly = preview.weeklyPercentage.map { String(format: "%.0f%%", $0) } ?? "-"
                                Text("현재 \(fiveHour) · 주간 \(weekly)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(selectedOrganizationID == preview.id ? Color.accentColor.opacity(0.10) : Color(NSColor.controlBackgroundColor).opacity(0.45))
                        .cornerRadius(6)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedOrganizationID = preview.id
                        }
                    }
                }
                .padding(.top, 4)
            }

            if let message = organizationMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(message.contains("실패") || message.contains("없음") ? .orange : .secondary)
            }

            if let oauthSummary = organizationOAuthFallbackSummary {
                Text(oauthSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.45))
                    .cornerRadius(6)
            }
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

                Toggle("메뉴바 보조 텍스트 강조", isOn: $settings.menuBarTextHighContrast)
                Text("메뉴바의 리셋 시간, 구분자 등을 기본 텍스트와 동일한 색상으로 표시")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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

    // MARK: - 표시 항목 섹션

    private var isEditingCompact: Bool {
        settings.separateCompactConfig && compactConfigTab == 1
    }

    private var popoverItemsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("표시 항목", systemImage: "list.bullet")
                .font(.headline)

            Text("항목의 표시 여부와 순서를 설정합니다")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("기본/간소화 개별 설정", isOn: $settings.separateCompactConfig)

            if settings.separateCompactConfig {
                Picker("", selection: $compactConfigTab) {
                    Text("기본").tag(0)
                    Text("간소화").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }

            itemsList(isCompact: isEditingCompact)
        }
    }

    private func itemsList(isCompact: Bool) -> some View {
        let items = isCompact ? settings.compactPopoverItems : settings.popoverItems

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
                                settings.compactPopoverItems[index].visible.toggle()
                            } else {
                                settings.popoverItems[index].visible.toggle()
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
                .background(draggingItemID == item.id ? Color.accentColor.opacity(0.1) : Color.clear)
                .cornerRadius(4)
                .onDrag {
                    draggingItemID = item.id
                    return NSItemProvider(object: item.id as NSString)
                }
                .onDrop(of: [.text], delegate: PopoverItemDropDelegate(
                    targetID: item.id,
                    settings: settings,
                    isCompact: isCompact,
                    draggingItemID: $draggingItemID
                ))
            }
        }
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(6)
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

            Text("배터리 모드에서 새로고침 간격이 최소 60초로 제한됩니다")
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

            Picker("자동 확인", selection: $settings.updateCheckInterval) {
                ForEach(UpdateCheckInterval.allCases, id: \.self) { interval in
                    Text(interval.displayName).tag(interval)
                }
            }
            .pickerStyle(.segmented)

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
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if let result = updateCheckResult {
                HStack {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.contains("가능") ? .orange : result.contains("실패") ? .red : .green)
                    if result.contains("가능") {
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
        }
    }

    // MARK: - 일반 섹션

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("일반", systemImage: "gearshape.2")
                .font(.headline)

            Toggle("로그인 시 자동 시작", isOn: $settings.launchAtLogin)

            Text("시스템 설정 → 일반 → 로그인 항목에서도 관리할 수 있습니다")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func testConnection() {
        let normalizedKey = normalizeSessionKey(sessionKey)
        guard !normalizedKey.isEmpty else { return }
        if normalizedKey != sessionKey {
            sessionKey = normalizedKey
        }
        isTesting = true
        testResult = nil

        Task {
            do {
                let service = ClaudeAPIService(sessionKey: normalizedKey)
                await service.updatePreferredOrganizationID(normalizeOrganizationID(selectedOrganizationID))
                let _ = try await service.fetchUsage()
                await MainActor.run {
                    testResult = .success
                    isTesting = false
                    // 연결 성공 시 자동 저장
                    do {
                        try KeychainManager.shared.save(normalizedKey)
                        storedSessionKey = normalizedKey
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
        let normalizedKey = normalizeSessionKey(sessionKey)
        if normalizedKey != sessionKey {
            sessionKey = normalizedKey
        }

        // 세션 키 저장
        if !normalizedKey.isEmpty {
            do {
                try KeychainManager.shared.save(normalizedKey)
                storedSessionKey = normalizedKey
            } catch {
                Logger.error("세션 키 저장 실패: \(error)")
            }
        } else {
            try? KeychainManager.shared.delete()
            storedSessionKey = nil
            testResult = nil
        }

        // 새로고침 간격 유효성
        if let val = TimeInterval(refreshIntervalText), val >= 5, val <= 120 {
            settings.refreshInterval = val
        }

        let normalizedOrganizationID = normalizeOrganizationID(selectedOrganizationID)
        if normalizedOrganizationID != selectedOrganizationID {
            selectedOrganizationID = normalizedOrganizationID
        }
        settings.preferredOrganizationID = normalizedOrganizationID

        onSave?()
    }

    private func normalizeSessionKey(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if let prefixRange = value.range(of: "sessionKey=", options: [.anchored, .caseInsensitive]) {
            value = String(value[prefixRange.upperBound...])
        }

        if let semiIndex = value.firstIndex(of: ";") {
            value = String(value[..<semiIndex])
        }

        value = value.trimmingCharacters(in: .whitespacesAndNewlines)

        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }

        return value
    }

    private func normalizeOrganizationID(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadOrganizations() {
        let normalizedKey: String = {
            if !sessionKey.isEmpty {
                return normalizeSessionKey(sessionKey)
            }
            if let storedSessionKey, !storedSessionKey.isEmpty {
                return normalizeSessionKey(storedSessionKey)
            }
            return ""
        }()

        guard !normalizedKey.isEmpty else {
            organizationMessage = "세션 키가 없어 organization 목록을 불러올 수 없습니다."
            return
        }

        isLoadingOrganizations = true
        isLoadingOrganizationPreviews = false
        organizationMessage = nil
        organizationOAuthFallbackSummary = nil

        Task {
            let service = ClaudeAPIService(sessionKey: normalizedKey)
            await service.updatePreferredOrganizationID(normalizeOrganizationID(selectedOrganizationID))
            var resolvedOrganizations: [ClaudeAPIService.OrganizationSummary] = []

            do {
                resolvedOrganizations = try await service.fetchOrganizations()
            } catch {
                resolvedOrganizations = await service.cachedOrganizationsForDisplay()
                await MainActor.run {
                    if !resolvedOrganizations.isEmpty {
                        organizationMessage = "organization 목록 조회 실패로 캐시 목록을 표시합니다."
                    }
                }
            }

            await MainActor.run {
                organizations = resolvedOrganizations
                isLoadingOrganizations = false
                organizationPreviews = []
                organizationOAuthFallbackSummary = nil
            }

            guard !resolvedOrganizations.isEmpty else {
                do {
                    let fallbackUsage = try await service.fetchUsage()
                    await MainActor.run {
                        organizationMessage = "organization 목록 조회 실패로 OAuth 기준 사용량만 표시합니다."
                        let fiveHour = String(format: "%.0f%%", fallbackUsage.fiveHour.utilization)
                        let weekly = String(format: "%.0f%%", fallbackUsage.sevenDay?.utilization ?? 0)
                        organizationOAuthFallbackSummary = "OAuth 기준: 현재 \(fiveHour) · 주간 \(weekly)"
                    }
                } catch {
                    await MainActor.run {
                        organizationOAuthFallbackSummary = nil
                        organizationMessage = "organization 목록 조회 실패: \(error.localizedDescription)"
                    }
                }
                return
            }

            await MainActor.run {
                isLoadingOrganizationPreviews = true
                organizationMessage = "organization \(resolvedOrganizations.count)개 목록을 불러왔습니다. 상세 조회 중..."
            }

            let previews = await service.fetchOrganizationPreviews(for: resolvedOrganizations)
            await MainActor.run {
                organizationPreviews = previews
                isLoadingOrganizationPreviews = false

                let exists = selectedOrganizationID.isEmpty || previews.contains { $0.id == selectedOrganizationID }
                if !exists {
                    organizationMessage = "현재 선택한 organization이 목록에 없어 자동 선택으로 동작합니다."
                    return
                }

                let failedCount = previews.filter { $0.usageErrorMessage != nil }.count
                if failedCount > 0 {
                    organizationMessage = "organization \(previews.count)개 중 \(failedCount)개는 상세 조회에 실패했습니다."
                } else {
                    organizationMessage = "organization \(previews.count)개의 상세를 불러왔습니다."
                }
            }
        }
    }

    private func resetToDefaults() {
        settings.resetToDefaults()
        refreshIntervalText = String(Int(settings.refreshInterval))
        alertTexts = settings.alertThresholds.map { String($0) }
        selectedOrganizationID = settings.preferredOrganizationID
        organizationPreviews = []
        isLoadingOrganizationPreviews = false
        organizationMessage = nil
        organizationOAuthFallbackSummary = nil
    }
}

// MARK: - Drag & Drop Delegate

struct PopoverItemDropDelegate: DropDelegate {
    let targetID: String
    let settings: AppSettings
    let isCompact: Bool
    @Binding var draggingItemID: String?

    func performDrop(info: DropInfo) -> Bool {
        draggingItemID = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggingID = draggingItemID, draggingID != targetID else { return }

        let items = isCompact ? settings.compactPopoverItems : settings.popoverItems
        guard let fromIndex = items.firstIndex(where: { $0.id == draggingID }),
              let toIndex = items.firstIndex(where: { $0.id == targetID })
        else { return }

        withAnimation(.easeInOut(duration: 0.15)) {
            let offset = toIndex > fromIndex ? toIndex + 1 : toIndex
            if isCompact {
                settings.compactPopoverItems.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: offset)
            } else {
                settings.popoverItems.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: offset)
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
