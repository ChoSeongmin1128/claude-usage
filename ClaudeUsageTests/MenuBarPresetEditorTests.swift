import Foundation
import XCTest
@testable import ClaudeUsage

@MainActor
final class MenuBarPresetEditorTests: XCTestCase {
    func testBuiltinEditClearsCheckAndUserSaveKeepsCommonPreferencesIndependent() async throws {
        let fixture = try Fixture(provider: .claude)
        defer { fixture.clean() }
        await fixture.model.applyBuiltin(.battery)
        XCTAssertEqual(fixture.model.selection(limits: [], codexUsage: nil).checked, .builtin(.battery))
        fixture.settings.setProviderShowIcon(false, for: .claude)
        let modified = fixture.model.selection(limits: [], codexUsage: nil)
        XCTAssertNil(modified.checked)
        XCTAssertEqual(modified.sourceName, "배터리")
        XCTAssertTrue(modified.isModified)
        XCTAssertFalse(modified.canUpdate)
        fixture.model.beginNaming(.new)
        fixture.model.name = "집중"
        fixture.model.saveName()
        let preset = try XCTUnwrap(fixture.model.store.presets.first)
        XCTAssertEqual(fixture.model.selection(limits: [], codexUsage: nil).checked, .user(preset))
        fixture.settings.timeFormat = .remaining
        fixture.settings.usageDisplayMode = .used
        fixture.settings.menuBarColorMode = .monochrome
        XCTAssertEqual(fixture.model.selection(limits: [], codexUsage: nil).checked, .user(preset))
        XCTAssertEqual(fixture.model.store.presets.first, preset)
    }

    func testUserEditDoesNotChangeSavedPresetUntilExplicitSaveAndRenameDeletePreserveDisplay() async throws {
        let fixture = try Fixture(provider: .codex)
        defer { fixture.clean() }
        fixture.model.beginNaming(.new)
        fixture.model.name = "업무"
        fixture.model.saveName()
        let original = try XCTUnwrap(fixture.model.store.presets.first)
        await fixture.model.applyBuiltin(.circle)
        await fixture.model.applyUser(original.id)
        fixture.settings.setProviderPercentageDisplay(.weekly, for: .codex)
        XCTAssertEqual(fixture.model.store.presets.first, original)
        XCTAssertTrue(fixture.model.selection(limits: [], codexUsage: nil).canUpdate)
        fixture.model.saveChanges()
        let updated = try XCTUnwrap(fixture.model.store.presets.first)
        XCTAssertNotEqual(updated.display, original.display)
        XCTAssertEqual(fixture.model.selection(limits: [], codexUsage: nil).checked, .user(updated))
        let current = fixture.settings.menuBarDisplayConfig(for: .codex)
        fixture.model.beginNaming(.rename(updated.id))
        fixture.model.name = "연구"
        fixture.model.saveName()
        XCTAssertEqual(fixture.settings.menuBarDisplayConfig(for: .codex), current)
        fixture.model.pendingDelete = updated.id
        fixture.model.deleteConfirmed()
        XCTAssertEqual(fixture.settings.menuBarDisplayConfig(for: .codex), current)
        XCTAssertTrue(fixture.model.store.presets.isEmpty)
        await fixture.model.applyUser(updated.id)
        XCTAssertNotNil(fixture.model.errorMessage)
        XCTAssertEqual(fixture.settings.menuBarDisplayConfig(for: .codex), current)
    }

    func testNameFailureKeepsEditorOpenAndAntigravityChooserCancelDoesNotApply() async throws {
        let fixture = try Fixture(provider: .antigravity)
        defer { fixture.clean() }
        let before = fixture.defaults.dictionaryRepresentation() as NSDictionary
        await fixture.model.applyBuiltin(.concentric)
        XCTAssertEqual(fixture.model.choosingQuotaIDs, [])
        fixture.model.cancel()
        XCTAssertNil(fixture.model.choosingQuotaIDs)
        XCTAssertEqual(fixture.defaults.dictionaryRepresentation() as NSDictionary, before)
        let other = try Fixture(provider: .claude)
        defer { other.clean() }
        other.model.beginNaming(.new)
        other.model.name = "숫자"
        other.model.saveName()
        XCTAssertEqual(other.model.naming, .new)
        XCTAssertNotNil(other.model.errorMessage)
        XCTAssertTrue(other.model.store.presets.isEmpty)
    }

    func testCorruptPresetStorageBlocksApplicationWithoutChangingCurrentDisplay() async throws {
        let fixture = try Fixture(provider: .claude)
        defer { fixture.clean() }
        let data = Data("not-json".utf8)
        fixture.defaults.set(data, forKey: MenuBarPresetStore.key)
        fixture.model.store.reload()
        let current = fixture.settings.menuBarDisplayConfig(for: .claude)
        await fixture.model.applyBuiltin(.concentric)
        XCTAssertNotNil(fixture.model.errorMessage)
        XCTAssertEqual(fixture.settings.menuBarDisplayConfig(for: .claude), current)
        XCTAssertEqual(fixture.defaults.data(forKey: MenuBarPresetStore.key), data)
    }

    @MainActor private struct Fixture {
        let suite = "MenuBarPresetEditorTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let settings: AppSettings
        let model: MenuBarPresetEditorModel

        init(provider: AppProviderKind) throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            settings = AppSettings(
                defaults: defaults, hasExistingAccountStorage: false,
                launchAtLoginController: LaunchAtLoginController(service: PresetEditorLoginService()))
            model = MenuBarPresetEditorModel(
                provider: provider, store: settings.menuBarPresets,
                application: MenuBarPresetApplication(settings: settings))
        }

        func clean() { defaults.removePersistentDomain(forName: suite) }
    }
}

private struct PresetEditorLoginService: LoginItemManaging {
    var status: LoginItemStatus { .notRegistered }
    func register() throws { XCTFail("Preset fixture must not register login items") }
    func unregister() throws { XCTFail("Preset fixture must not unregister login items") }
    func openSystemSettings() { XCTFail("Preset fixture must not open settings") }
}
