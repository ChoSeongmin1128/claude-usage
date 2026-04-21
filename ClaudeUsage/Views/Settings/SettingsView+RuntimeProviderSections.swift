import AppKit
import SwiftUI

extension SettingsView {
    @ViewBuilder
    func runtimeProviderPanel(for provider: AppProviderKind) -> some View {
        runtimeProviderOverviewSection(for: provider)
    }

    @ViewBuilder
    private func runtimeProviderOverviewSection(for provider: AppProviderKind) -> some View {
        let _ = runtimeEnvironmentRefreshTick
        let descriptor = SettingsProviderRegistry.providerShellDescriptor(for: provider)
        if let presentation = RuntimeProviderSettingsPresentation.authPresentation(
            for: provider,
            isEnabled: settings.isProviderEnabled(provider)
        ) {
            RuntimeProviderOverviewSectionView(
                settings: settings,
                provider: provider,
                descriptor: descriptor,
                presentation: presentation
            )
        } else {
            RuntimeProviderPanelShell(
                descriptor: descriptor,
                title: descriptor.title,
                detail: descriptor.detail
            ) {
                EmptyView()
            }
        }
    }
}
