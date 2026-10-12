import AppKit

struct MenuBarPresetPreviewImage {
    let image: NSImage
    let accessibilityValue: String?
}

@MainActor
enum MenuBarPresetPreviewRenderer {
    static func render(
        _ display: MenuBarPresetDisplay, provider: AppProviderKind, settings: AppSettings,
        claudeUsage: ClaudeUsageResponse?, codexUsage: CodexUsageResponse?,
        antigravityState: AntigravitySettingsViewState, appearance: NSAppearance, resetCreditsAreNew: Bool
    ) -> MenuBarPresetPreviewImage? {
        let visible = ServiceSelectionHelper.enabledRuntimeProviderKinds(settings: settings).filter { kind in
            kind == .antigravity
                ? antigravityState.display?.menuBar.isVisible == true : settings.isProviderVisibleInMenuBar(kind)
        }
        let compact = visible.count > 1
        let icon = MenuBarIconFactory.providerMenuBarIcon(
            for: provider,
            size: compact ? AppDesign.MenuBar.multipleProviderIconSize : AppDesign.MenuBar.singleProviderIconSize,
            appearance: appearance)
        var snapshot: MenuBarProviderSnapshot
        switch display {
        case .catalog(let value):
            guard let current = settings.menuBarDisplayConfig(for: provider) else { return nil }
            let config = value.config(preserving: current)
            if provider == .claude {
                snapshot = MenuBarStatusComposer.claudeSnapshot(
                    config: config, usage: claudeUsage, error: nil, hasAuthError: false, hasCredential: true,
                    secondaryColor: .secondaryLabelColor, icon: icon, appearance: appearance)
            } else {
                snapshot = MenuBarStatusComposer.codexSnapshot(
                    config: config, usage: codexUsage, error: nil, hasAuthError: false, isAuthenticated: true,
                    secondaryColor: .secondaryLabelColor, icon: icon, appearance: appearance)
            }
            let summary =
                provider == .claude
                ? ResetCreditSummary.claude(claudeUsage?.resetGrants) : ResetCreditSummary.codex(codexUsage)
            snapshot = snapshot.withResetCreditBadge(
                MenuBarResetCreditBadge.resolve(
                    summary: summary, isNew: resetCreditsAreNew,
                    mode: ResetCreditMenuBarMode(rawValue: value.resetCredits) ?? .off))
        case .antigravity(let value):
            guard let current = antigravityState.display else { return nil }
            var display = value.applying(to: current)
            display.menuBar.isVisible = true
            guard
                case .content(let presentation) = AntigravityQuotaPresentationMapper.map(
                    state: antigravityState.presentation, settings: display,
                    basisOverride: settings.usageDisplayMode.basis)
            else { return nil }
            let units = AntigravityMenuBarQuotaEditorAdapter.renderedUnits(
                settings: display, presentation: presentation, design: settings.menuBarDesign,
                colorMode: settings.menuBarColorMode, appearance: appearance)
            guard
                let projected = MenuBarStatusComposer.antigravitySnapshot(
                    presentation: presentation.menuBar, context: presentation.context, icon: icon,
                    appearance: appearance, design: settings.menuBarDesign, colorMode: settings.menuBarColorMode,
                    quotaUnits: units, arrangement: display.menuBar.arrangement)
            else { return nil }
            snapshot = projected
        }
        let content =
            compact
            ? MenuBarStatusComposer.multipleProviderContent(
                snapshots: [snapshot], secondaryColor: .secondaryLabelColor, appearance: appearance)
            : MenuBarStatusComposer.singleProviderContent(
                snapshot: snapshot, secondaryColor: .secondaryLabelColor, appearance: appearance)
        return MenuBarPresetPreviewImage(image: content.image, accessibilityValue: content.accessibilityValue)
    }
}
