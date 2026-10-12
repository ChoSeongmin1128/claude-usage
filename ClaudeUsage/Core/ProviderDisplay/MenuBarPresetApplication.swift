import Foundation

@MainActor
final class MenuBarPresetApplication {
    private let settings: AppSettings
    private let antigravity: AntigravitySettingsViewModel?

    init(settings: AppSettings, antigravity: AntigravitySettingsViewModel? = nil) {
        self.settings = settings
        self.antigravity = antigravity
    }

    func currentDisplay(for provider: AppProviderKind) -> MenuBarPresetDisplay? {
        if provider == .antigravity {
            return antigravity?.state.display.map { .antigravity(AntigravityMenuBarPresetDisplay($0.menuBar)) }
        }
        return settings.menuBarDisplayConfig(for: provider).map {
            .catalog(
                CatalogMenuBarPresetDisplay(config: $0, resetCredits: settings.resetCreditMenuBarMode(for: provider)))
        }
    }

    func selectedAntigravityQuotaIDs() -> [String] {
        guard let menuBar = antigravity?.state.display?.menuBar else { return [] }
        let fixed: [AntigravityQuotaLaneID]
        if case .fixed(let id) = menuBar.laneSelection { fixed = [id] } else { fixed = [] }
        let selected = Set(
            (menuBar.gaugeLaneIDs ?? []) + (menuBar.percentageLaneIDs ?? []) + (menuBar.resetLaneIDs ?? [])
                + (menuBar.additionalLaneIDs ?? []) + fixed)
        let ordered =
            (menuBar.arrangement?.orderedIDs ?? [])
            + (menuBar.gaugeLaneIDs ?? []).map(\.rawValue)
            + (menuBar.percentageLaneIDs ?? []).map(\.rawValue)
            + (menuBar.additionalLaneIDs ?? []).map(\.rawValue) + fixed.map(\.rawValue)
        var seen = Set<String>()
        return ordered.filter { selected.contains(AntigravityQuotaLaneID(rawValue: $0)) && seen.insert($0).inserted }
    }

    func display(for reference: MenuBarPresetReference, provider: AppProviderKind) -> MenuBarPresetDisplay? {
        switch reference.origin {
        case .builtin:
            guard let preset = MenuBarBuiltinPreset(rawValue: reference.id), preset.supports(provider) else {
                return nil
            }
            if provider == .antigravity {
                return MenuBarPresetCatalog.antigravityDisplay(preset, quotaIDs: reference.selectedQuotaIDs ?? []).map {
                    .antigravity($0)
                }
            }
            return .catalog(MenuBarPresetCatalog.catalogDisplay(preset, provider: provider))
        case .user:
            return settings.menuBarPresets.presets.first {
                $0.id.uuidString == reference.id && $0.provider == provider
            }?.display
        }
    }

    func matches(
        _ display: MenuBarPresetDisplay, provider: AppProviderKind, limits: [UsageLimit],
        codexUsage: CodexUsageResponse?
    ) -> Bool {
        guard let current = currentDisplay(for: provider) else { return false }
        switch (current, display) {
        case let (.catalog(lhs), .catalog(rhs)):
            guard let config = settings.menuBarDisplayConfig(for: provider) else { return false }
            return MenuBarPresetCatalog.matches(lhs, rhs, config: config, limits: limits, codexUsage: codexUsage)
        case let (.antigravity(lhs), .antigravity(rhs)):
            return MenuBarPresetCatalog.matches(lhs, rhs)
        default: return false
        }
    }

    func apply(_ display: MenuBarPresetDisplay, reference: MenuBarPresetReference, provider: AppProviderKind)
        async throws
    {
        guard display.isValid(for: provider) else { throw MenuBarPresetStoreError.invalidDisplay }
        try settings.menuBarPresets.validateWrite()
        let previousReference = settings.menuBarPresets.references[provider]
        switch display {
        case .catalog(let value):
            try settings.menuBarPresets.record(reference, for: provider)
            settings.applyMenuBarPresetDisplay(value, for: provider)
        case .antigravity(let value):
            guard let antigravity, let expected = antigravity.state.display else {
                throw MenuBarPresetApplicationError.settingsNotReady
            }
            let updated = value.applying(to: expected)
            if updated != expected {
                guard await antigravity.updateDisplay(updated, replacing: expected) else {
                    throw MenuBarPresetApplicationError.applicationRejected
                }
            }
            guard let actual = antigravity.state.display,
                MenuBarPresetCatalog.matches(AntigravityMenuBarPresetDisplay(actual.menuBar), value),
                settings.menuBarPresets.references[provider] == previousReference
            else { throw MenuBarPresetApplicationError.applicationRejected }
            do { try settings.menuBarPresets.record(reference, for: provider) } catch {
                throw MenuBarPresetApplicationError.sourceNotSaved
            }
        }
    }
}

nonisolated enum MenuBarPresetApplicationError: Error {
    case settingsNotReady, applicationRejected, sourceNotSaved

    var message: String {
        switch self {
        case .settingsNotReady: "설정을 불러온 뒤 다시 시도해 주세요."
        case .applicationRejected: "설정이 변경되어 적용하지 못했습니다. 현재 설정을 확인해 주세요."
        case .sourceNotSaved: "표시는 적용했지만 프리셋 출처를 저장하지 못했습니다."
        }
    }
}
