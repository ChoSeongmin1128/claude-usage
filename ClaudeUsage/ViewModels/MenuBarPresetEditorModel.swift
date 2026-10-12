import Combine
import Foundation

@MainActor
final class MenuBarPresetEditorModel: ObservableObject {
    enum Naming: Equatable { case new, rename(UUID) }
    struct Selection {
        let checked: MenuBarPresetReference?
        let sourceName: String?
        let isModified: Bool
        let canUpdate: Bool
    }

    let provider: AppProviderKind
    let store: MenuBarPresetStore
    let application: MenuBarPresetApplication
    @Published var naming: Naming?
    @Published var name = ""
    @Published var pendingDelete: UUID?
    @Published var choosingQuotaIDs: [String]?
    @Published private(set) var isApplying = false
    @Published private(set) var errorMessage: String?

    init(provider: AppProviderKind, store: MenuBarPresetStore, application: MenuBarPresetApplication) {
        self.provider = provider
        self.store = store
        self.application = application
    }

    func selection(limits: [UsageLimit], codexUsage: CodexUsageResponse?) -> Selection {
        if let reference = store.references[provider],
            let display = application.display(for: reference, provider: provider)
        {
            let name =
                reference.origin == .builtin
                ? MenuBarBuiltinPreset(rawValue: reference.id)?.title
                : store.presets.first { $0.id.uuidString == reference.id && $0.provider == provider }?.name
            let matches = application.matches(display, provider: provider, limits: limits, codexUsage: codexUsage)
            return Selection(
                checked: matches ? reference : nil, sourceName: name, isModified: !matches,
                canUpdate: !matches && reference.origin == .user)
        }
        let checked = MenuBarPresetCatalog.presets(for: provider).compactMap { preset -> MenuBarPresetReference? in
            let reference = MenuBarPresetReference.builtin(
                preset,
                selectedQuotaIDs:
                    provider == .antigravity && preset == .concentric
                    ? Array(application.selectedAntigravityQuotaIDs().prefix(2)) : nil)
            guard let display = application.display(for: reference, provider: provider),
                application.matches(display, provider: provider, limits: limits, codexUsage: codexUsage)
            else { return nil }
            return reference
        }.first
        return Selection(checked: checked, sourceName: nil, isModified: false, canUpdate: false)
    }

    func applyBuiltin(_ preset: MenuBarBuiltinPreset, quotaIDs: [String]? = nil) async {
        guard !isApplying else { return }
        let ids = quotaIDs ?? Array(application.selectedAntigravityQuotaIDs().prefix(2))
        if provider == .antigravity, preset == .concentric, ids.count != 2 {
            errorMessage = nil
            choosingQuotaIDs = ids
            return
        }
        let reference = MenuBarPresetReference.builtin(
            preset, selectedQuotaIDs: provider == .antigravity && preset == .concentric ? ids : nil)
        guard let display = application.display(for: reference, provider: provider) else { return }
        isApplying = true
        defer { isApplying = false }
        do {
            try await application.apply(display, reference: reference, provider: provider)
            choosingQuotaIDs = nil
            errorMessage = nil
        } catch { show(error) }
    }

    func applyUser(_ id: UUID) async {
        guard !isApplying else { return }
        guard let preset = store.presets.first(where: { $0.id == id && $0.provider == provider }) else {
            show(MenuBarPresetStoreError.missingPreset)
            return
        }
        isApplying = true
        defer { isApplying = false }
        do {
            try await application.apply(preset.display, reference: .user(preset), provider: provider)
            errorMessage = nil
        } catch { show(error) }
    }

    func beginNaming(_ mode: Naming) {
        errorMessage = nil
        naming = mode
        if case .rename(let id) = mode { name = store.presets.first { $0.id == id }?.name ?? "" } else { name = "" }
    }

    func saveName() {
        do {
            switch naming {
            case .new:
                guard let display = application.currentDisplay(for: provider) else {
                    throw MenuBarPresetApplicationError.settingsNotReady
                }
                _ = try store.add(name: name, provider: provider, display: display)
            case .rename(let id): try store.rename(id, name: name)
            case nil: return
            }
            naming = nil
            errorMessage = nil
        } catch { show(error) }
    }

    func saveChanges() {
        do {
            guard let reference = store.references[provider], reference.origin == .user,
                let id = UUID(uuidString: reference.id), let display = application.currentDisplay(for: provider)
            else { throw MenuBarPresetStoreError.missingPreset }
            try store.update(id, display: display)
            errorMessage = nil
        } catch { show(error) }
    }

    func deleteConfirmed() {
        guard let pendingDelete else { return }
        do {
            try store.delete(pendingDelete)
            self.pendingDelete = nil
            errorMessage = nil
        } catch { show(error) }
    }

    func cancel() {
        naming = nil
        choosingQuotaIDs = nil
        pendingDelete = nil
        errorMessage = nil
    }

    private func show(_ error: Error) {
        if let error = error as? MenuBarPresetStoreError {
            errorMessage = error.message
        } else if let error = error as? MenuBarPresetApplicationError {
            errorMessage = error.message
        } else {
            errorMessage = "프리셋을 변경하지 못했습니다. 다시 시도해 주세요."
        }
    }
}
