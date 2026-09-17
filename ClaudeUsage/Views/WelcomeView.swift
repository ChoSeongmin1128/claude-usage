import SwiftUI

struct WelcomeView<Connection: View, Display: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var settings: AppSettings
    @Binding var selectedProvider: AppProviderKind
    let statuses: [AppProviderKind: WelcomeServiceStatus]
    let connection: Connection
    let display: Display
    var onVerify: (PopoverService) -> Void
    var onDefer: () -> Void
    var onFinish: () -> Void

    private var welcomeServices: [AppProviderKind] {
        AppProviderKind.allCases.filter { settings.isProviderEnabled($0) }
    }

    var body: some View {
        let services = welcomeServices
        let verified = WelcomeServiceStatus.allVerified(services, statuses: statuses)
        return VStack(alignment: .leading, spacing: AppDesign.Space.section) {
            Text("메뉴바에서 사용량 확인하기").font(AppDesign.Typography.title)
            Text("사용할 서비스를 연결하고, 실제 사용량을 확인한 뒤 메뉴바를 꾸며 보세요.")
                .font(AppDesign.Typography.subheadline).foregroundStyle(.secondary)
            HStack(spacing: AppDesign.Space.content) {
                ForEach(WelcomeStep.allCases, id: \.rawValue) { step in
                    Text("\(step.rawValue + 1). \(step.title)")
                        .font(AppDesign.Typography.caption.weight(step == settings.welcomeStep ? .semibold : .regular))
                        .foregroundStyle(step == settings.welcomeStep ? Color.accentColor : .secondary)
                }
            }
            Divider()
            Group {
                switch settings.welcomeStep {
                case .services:
                    ForEach(AppProviderKind.allCases, id: \.rawValue) { provider in
                        HStack(spacing: AppDesign.Space.content) {
                            ProviderBrandIconView(provider: provider, kind: .settings, size: 24)
                            Toggle(
                                provider.displayName,
                                isOn: Binding(
                                    get: { settings.isProviderEnabled(provider) },
                                    set: { settings.setProviderEnabled($0, for: provider) }))
                        }
                        .padding(AppDesign.Space.content).appPanelStyle()
                    }
                    Text("계정은 서비스별로 연결합니다. 사용하지 않는 서비스는 켜지 않아도 됩니다.")
                        .font(AppDesign.Typography.caption).foregroundStyle(.secondary)
                case .connection:
                    if !services.isEmpty {
                        Picker("연결할 서비스", selection: $selectedProvider) {
                            ForEach(services, id: \.rawValue) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        connection
                        HStack {
                            if statuses[selectedProvider] == .verified {
                                Label("현재 계정의 사용량을 확인했습니다", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Text("로그인 후 숫자로 된 사용량까지 확인합니다.").foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(statuses[selectedProvider] == .checking ? "확인 중…" : "사용량 확인") {
                                if let service = selectedProvider.runtimeService { onVerify(service) }
                            }
                            .disabled(statuses[selectedProvider] == .checking)
                        }
                        .font(AppDesign.Typography.caption)
                    }
                case .appearance:
                    MenuBarDesignPicker(settings: settings, basis: settings.usageDisplayMode.basis ?? .used)
                    if !services.isEmpty {
                        Picker("표시할 서비스", selection: $selectedProvider) {
                            ForEach(services, id: \.rawValue) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        display
                    }
                    Toggle("로그인 시 자동 시작", isOn: $settings.launchAtLogin)
                    Text("메뉴바 아이콘을 누르면 사용량을 볼 수 있습니다. 설정은 언제든 다시 바꿀 수 있습니다.")
                        .font(AppDesign.Typography.caption).foregroundStyle(.secondary)
                }
            }
            .id(settings.welcomeStep)
            .transition(.opacity)
            .animation(
                settings.motion.animation(for: .navigation, reduceMotion: reduceMotion), value: settings.welcomeStep)
            Divider()
            HStack {
                if settings.welcomeStep != .services {
                    Button("이전") {
                        settings.welcomeStep = WelcomeStep(rawValue: settings.welcomeStep.rawValue - 1) ?? .services
                    }
                }
                Button("나중에 설정") {
                    if settings.welcomeState == .pending { settings.welcomeState = .deferred }
                    onDefer()
                }
                Spacer()
                Button(settings.welcomeStep == .appearance ? (verified ? "시작하기" : "연결 다시 확인") : "계속") {
                    switch settings.welcomeStep {
                    case .services:
                        selectedProvider = services.first ?? .claude
                        settings.welcomeStep = .connection
                    case .connection: settings.welcomeStep = .appearance
                    case .appearance:
                        if verified {
                            settings.welcomeState = .completed
                            onFinish()
                        } else {
                            settings.welcomeStep = .connection
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(services.isEmpty || (settings.welcomeStep == .connection && !verified))
            }
            if settings.welcomeStep == .connection && !verified && services.count > 1 {
                Text("선택한 서비스마다 사용량을 확인해 주세요. 나머지 서비스는 나중에 연결해도 됩니다.")
                    .font(AppDesign.Typography.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: services) { _, available in
            if !available.contains(selectedProvider) { selectedProvider = available.first ?? .claude }
        }
    }
}
