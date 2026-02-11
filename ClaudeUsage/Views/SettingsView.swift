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

    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?

    enum TestResult {
        case success
        case failure(String)
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
        }

        // 하단 버튼
        HStack {
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

            VStack(alignment: .leading, spacing: 8) {
                Text("세션 키")
                    .font(.subheadline)

                TextField("sk-ant-sid01-...", text: $sessionKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))

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
        }
    }

    // MARK: - 디스플레이 섹션

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("디스플레이", systemImage: "paintbrush")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("추가 아이콘:")
                    .font(.subheadline)

                Picker("", selection: $settings.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.radioGroup)

                Toggle("퍼센트 표시", isOn: $settings.showPercentage)

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
                        .onChange(of: refreshIntervalText) { _, newValue in
                            if let val = TimeInterval(newValue), val >= 5, val <= 120 {
                                settings.refreshInterval = val
                            }
                        }
                    Text("초 (5~120)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

            VStack(alignment: .leading, spacing: 6) {
                Toggle("75% 알림", isOn: $settings.alertAt75)
                Toggle("90% 알림", isOn: $settings.alertAt90)
                Toggle("95% 알림", isOn: $settings.alertAt95)
            }
        }
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
}
