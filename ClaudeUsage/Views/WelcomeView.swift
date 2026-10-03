import SwiftUI

/// 처음 설정의 서비스 한 줄. 상태 문구와 바로 할 일 하나를 보여준다.
struct OnboardingServiceRow: Identifiable {
    enum Tone { case connected, ready, missing, checking }

    struct Action {
        let title: String
        let perform: () -> Void
    }

    let provider: AppProviderKind
    let status: String
    let tone: Tone
    var detail: String? = nil
    var primary: Action? = nil
    var secondary: Action? = nil

    var id: AppProviderKind { provider }
}

struct WelcomeView<Display: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var settings: AppSettings
    @Binding var selectedProvider: AppProviderKind
    let statuses: [AppProviderKind: WelcomeServiceStatus]
    let rows: [OnboardingServiceRow]
    let display: Display
    var onDefer: () -> Void
    var onFinish: () -> Void

    private var connectedServices: [AppProviderKind] {
        AppProviderKind.allCases.filter { settings.isProviderEnabled($0) && statuses[$0] == .verified }
    }

    private var step: WelcomeStep {
        settings.welcomeStep == .connection ? .services : settings.welcomeStep
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.section) {
            Text("시작하기").font(AppDesign.Typography.title)
            HStack(spacing: AppDesign.Space.content) {
                ForEach([WelcomeStep.services, .appearance], id: \.rawValue) { item in
                    Text(item.title)
                        .font(AppDesign.Typography.caption.weight(item == step ? .semibold : .regular))
                        .foregroundStyle(item == step ? Color.accentColor : .secondary)
                }
            }
            Divider()
            Group {
                switch step {
                case .services, .connection:
                    Text("사용량을 볼 서비스").font(AppDesign.Typography.headline)
                    ForEach(rows) { row in serviceRow(row) }
                    Text("연결한 서비스만 메뉴바에 나타납니다. 나머지는 설정의 계정에서 언제든 연결할 수 있습니다.")
                        .font(AppDesign.Typography.caption).foregroundStyle(.secondary)
                case .appearance:
                    MenuBarDesignPicker(settings: settings, basis: settings.usageDisplayMode.basis ?? .used)
                    if !connectedServices.isEmpty {
                        Picker("표시할 서비스", selection: $selectedProvider) {
                            ForEach(connectedServices, id: \.rawValue) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        display
                    }
                    Toggle("로그인 시 자동 시작", isOn: $settings.launchAtLogin)
                    Text("메뉴바 아이콘을 누르면 사용량을 볼 수 있습니다. 설정은 언제든 다시 바꿀 수 있습니다.")
                        .font(AppDesign.Typography.caption).foregroundStyle(.secondary)
                }
            }
            .id(step)
            .transition(.opacity)
            .animation(settings.motion.animation(for: .navigation, reduceMotion: reduceMotion), value: step)
            Divider()
            HStack {
                if step == .appearance {
                    Button("이전") { settings.welcomeStep = .services }
                }
                Button("나중에 설정") {
                    if settings.welcomeState == .pending { settings.welcomeState = .deferred }
                    onDefer()
                }
                Spacer()
                Button(step == .appearance ? "완료" : "계속") {
                    if step == .appearance {
                        settings.welcomeState = .completed
                        onFinish()
                    } else {
                        selectedProvider = connectedServices.first ?? .claude
                        settings.welcomeStep = .appearance
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(connectedServices.isEmpty)
            }
        }
        .onChange(of: connectedServices) { _, available in
            if !available.contains(selectedProvider) { selectedProvider = available.first ?? .claude }
        }
    }

    private func serviceRow(_ row: OnboardingServiceRow) -> some View {
        HStack(spacing: AppDesign.Space.content) {
            ProviderBrandIconView(provider: row.provider, kind: .settings, size: 24)
            VStack(alignment: .leading, spacing: AppDesign.Space.tight) {
                Text(row.provider.displayName).font(AppDesign.Typography.subheadline.weight(.semibold))
                if let detail = row.detail {
                    Text(detail).font(AppDesign.Typography.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: AppDesign.Space.row)
            if row.tone == .checking {
                ProgressView().controlSize(.small)
            }
            Text(row.status)
                .font(AppDesign.Typography.caption)
                .foregroundStyle(row.tone == .connected ? Color.green : .secondary)
                .lineLimit(1)
            if let secondary = row.secondary {
                Button(secondary.title, action: secondary.perform).buttonStyle(.link).controlSize(.small)
            }
            if let primary = row.primary {
                Button(primary.title, action: primary.perform)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(AppDesign.Space.content)
        .appPanelStyle()
    }
}
