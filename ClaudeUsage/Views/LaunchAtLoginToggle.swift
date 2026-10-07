import AppKit
import SwiftUI

struct LaunchAtLoginToggle: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.tight) {
            Toggle(
                isOn: Binding(
                    get: { settings.launchAtLoginState.isSelected },
                    set: { settings.setLaunchAtLogin($0) }
                )
            ) {
                VStack(alignment: .leading, spacing: AppDesign.Space.tight) {
                    Text("로그인 시 자동 시작")
                    if let notice = settings.launchAtLoginState.notice {
                        Text(notice)
                            .font(AppDesign.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            if settings.launchAtLoginState.canOpenSystemSettings {
                Button("로그인 항목 설정 열기") { settings.openLoginItemSettings() }
                    .buttonStyle(.link)
            }
        }
        .padding(.vertical, AppDesign.Space.tight)
        .onAppear { settings.refreshLaunchAtLoginStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refreshLaunchAtLoginStatus()
        }
    }
}
