import Foundation
import XCTest
@testable import ClaudeUsage

@MainActor
final class MenuBarPresetStoreTests: XCTestCase {
    func testReadingMissingStorageDoesNotWriteAndNamesAreValidatedPerProvider() throws {
        try withDefaults { defaults in
            let store = MenuBarPresetStore(defaults: defaults)
            XCTAssertNil(defaults.object(forKey: MenuBarPresetStore.key))
            let display = self.display(.claude)
            let preset = try store.add(name: "  Focus  ", provider: .claude, display: display)
            XCTAssertEqual(preset.name, "Focus")
            XCTAssertEqual(store.references[.claude], .user(preset))
            XCTAssertThrowsError(try store.add(name: "focus", provider: .claude, display: display)) {
                XCTAssertEqual($0 as? MenuBarPresetStoreError, .duplicateName)
            }
            XCTAssertThrowsError(try store.add(name: "숫자", provider: .claude, display: display))
            XCTAssertThrowsError(try store.add(name: "  ", provider: .claude, display: display))
            XCTAssertThrowsError(
                try store.add(name: String(repeating: "가", count: 33), provider: .claude, display: display))
            _ = try store.add(name: String(repeating: "가", count: 32), provider: .claude, display: display)
            _ = try store.add(name: "Focus", provider: .codex, display: self.display(.codex))
            XCTAssertEqual(store.presets.count, 3)
        }
    }

    func testUnknownAndInvalidRecordsAndReferencesArePreservedOnSave() throws {
        try withDefaults { defaults in
            let invalid =
                ["id": "future-id", "provider": "future", "name": "unknown", "display": ["future": 17]] as [String: Any]
            let original: [String: Any] = [
                "version": 1, "presets": [invalid, 17],
                "applied": ["future": ["id": "future", "origin": "future"]], "futureRoot": ["keep": true],
            ]
            defaults.set(try JSONSerialization.data(withJSONObject: original), forKey: MenuBarPresetStore.key)
            let store = MenuBarPresetStore(defaults: defaults)
            XCTAssertTrue(store.isWritable)
            XCTAssertTrue(store.presets.isEmpty)
            _ = try store.add(name: "집중", provider: .claude, display: self.display(.claude))
            let saved = try self.raw(defaults)
            let rows = try XCTUnwrap(saved["presets"] as? [Any])
            XCTAssertEqual(rows.count, 3)
            XCTAssertEqual((rows[1] as? NSDictionary), invalid as NSDictionary)
            XCTAssertEqual(rows[2] as? Int, 17)
            XCTAssertEqual((saved["futureRoot"] as? [String: Bool])?["keep"], true)
            let references = try XCTUnwrap(saved["applied"] as? [String: Any])
            XCTAssertNotNil(references["future"])
            XCTAssertNotNil(references["claude"])
        }
    }

    func testCorruptFutureVersionAndInvalidTypesAreNeverOverwritten() throws {
        for object: Any in [
            Data("broken".utf8), Data(#"{"version":2,"presets":[],"applied":{},"future":1}"#.utf8), "future-type",
            Data(#"{"version":true,"presets":[],"applied":{}}"#.utf8),
        ] {
            try withDefaults { defaults in
                defaults.set(object, forKey: MenuBarPresetStore.key)
                let store = MenuBarPresetStore(defaults: defaults)
                XCTAssertFalse(store.isWritable)
                XCTAssertThrowsError(try store.add(name: "집중", provider: .claude, display: self.display(.claude))) {
                    XCTAssertEqual($0 as? MenuBarPresetStoreError, .unavailableStorage)
                }
                XCTAssertEqual(defaults.object(forKey: MenuBarPresetStore.key) as? NSObject, object as? NSObject)
            }
        }
    }

    func testExternalChangeAndFailedWriteDoNotPublishSuccessfulState() throws {
        try withDefaults { defaults in
            let store = MenuBarPresetStore(defaults: defaults)
            let external = Data(#"{"version":1,"presets":[],"applied":{},"other":true}"#.utf8)
            defaults.set(external, forKey: MenuBarPresetStore.key)
            XCTAssertThrowsError(try store.add(name: "집중", provider: .claude, display: self.display(.claude))) {
                XCTAssertEqual($0 as? MenuBarPresetStoreError, .changedElsewhere)
            }
            XCTAssertTrue(store.presets.isEmpty)
            XCTAssertEqual(defaults.data(forKey: MenuBarPresetStore.key), external)
        }
        let suite = "MenuBarPresetStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(RejectingPresetDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MenuBarPresetStore(defaults: defaults)
        defaults.rejectPresetWrites = true
        XCTAssertThrowsError(try store.add(name: "집중", provider: .claude, display: display(.claude))) {
            XCTAssertEqual($0 as? MenuBarPresetStoreError, .writeFailed)
        }
        XCTAssertTrue(store.presets.isEmpty)
        XCTAssertTrue(store.references.isEmpty)
        XCTAssertNil(defaults.object(forKey: MenuBarPresetStore.key))
    }

    func testPresetsAndSourceRestoreWithoutChangingMenuBarOnRenameOrDelete() throws {
        try withDefaults { defaults in
            let settings = self.settings(defaults)
            let store = settings.menuBarPresets
            let preset = try store.add(name: "집중", provider: .claude, display: self.display(.claude))
            let beforeDisplay = settings.menuBarDisplayConfig(for: .claude)
            let snapshot = settings.createSnapshot()
            try store.rename(preset.id, name: "연구")
            try store.delete(preset.id)
            XCTAssertEqual(settings.menuBarDisplayConfig(for: .claude), beforeDisplay)
            settings.restore(from: snapshot)
            XCTAssertEqual(store.presets, [preset])
            XCTAssertEqual(store.references[.claude], .user(preset))
            XCTAssertEqual(MenuBarPresetStore(defaults: defaults).presets, [preset])
            settings.resetToDefaults()
            XCTAssertEqual(store.presets, [preset])
        }
    }

    func testBuiltinsUseCatalogAndPreserveCommonAndOtherProviderSettings() throws {
        try withDefaults { defaults in
            let settings = self.settings(defaults)
            settings.timeFormat = .remaining
            settings.usageDisplayMode = .used
            settings.circularDisplayMode = .usage
            settings.menuBarColorMode = .monochrome
            settings.setPopoverItems([.init(id: "weeklyLimit", visible: true)], for: .claude)
            let other = settings.menuBarDisplayConfig(for: .codex)
            let items = settings.popoverItems(for: .claude)
            settings.applyMenuBarDisplayPreset(.dual, for: .claude)
            XCTAssertEqual(settings.menuBarStyle, .sideBySideBattery)
            XCTAssertTrue(settings.showBatteryPercent)
            XCTAssertEqual(settings.timeFormat, .remaining)
            XCTAssertEqual(settings.usageDisplayMode, .used)
            XCTAssertEqual(settings.circularDisplayMode, .usage)
            XCTAssertEqual(settings.menuBarColorMode, .monochrome)
            XCTAssertEqual(settings.menuBarDisplayConfig(for: .codex), other)
            XCTAssertEqual(settings.popoverItems(for: .claude), items)
        }
    }

    func testAntigravityConcentricRequiresTwoIDsAndPreservesOwnedNonAppearanceState() throws {
        XCTAssertNil(MenuBarPresetCatalog.antigravityDisplay(.concentric))
        let ids = AntigravityDisplaySettings.builtInLaneIDs.prefix(2).map(\.rawValue)
        let display = try XCTUnwrap(MenuBarPresetCatalog.antigravityDisplay(.concentric, quotaIDs: ids))
        var current = AntigravityDisplaySettings.default
        current.menuBar.timeFormat = .remaining
        current.menuBar.circularValue = .usage
        current.menuBar.isVisible = false
        current.standard.hiddenLaneIDs = [AntigravityDisplaySettings.builtInLaneIDs[0]]
        current.notifications.isEnabled = true
        let applied = display.applying(to: current)
        XCTAssertEqual(applied.menuBar.gaugeLaneIDs?.map(\.rawValue), ids)
        XCTAssertEqual(applied.menuBar.arrangement?.gaugeLayout, .concentric)
        XCTAssertEqual(applied.menuBar.timeFormat, .remaining)
        XCTAssertEqual(applied.menuBar.circularValue, .usage)
        XCTAssertFalse(applied.menuBar.isVisible)
        XCTAssertEqual(applied.standard, current.standard)
        XCTAssertEqual(applied.compact, current.compact)
        XCTAssertEqual(applied.notifications, current.notifications)
    }

    private func display(_ provider: AppProviderKind) -> MenuBarPresetDisplay {
        .catalog(MenuBarPresetCatalog.catalogDisplay(.number, provider: provider))
    }

    private func raw(_ defaults: UserDefaults) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: MenuBarPresetStore.key)))
                as? [String: Any])
    }

    private func settings(_ defaults: UserDefaults) -> AppSettings {
        AppSettings(
            defaults: defaults, hasExistingAccountStorage: false,
            launchAtLoginController: LaunchAtLoginController(service: PresetTestLoginService()))
    }

    private func withDefaults(_ operation: (UserDefaults) throws -> Void) throws {
        let suite = "MenuBarPresetStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try operation(defaults)
    }
}

private struct PresetTestLoginService: LoginItemManaging {
    var status: LoginItemStatus { .notRegistered }
    func register() throws { XCTFail("Preset fixture must not register login items") }
    func unregister() throws { XCTFail("Preset fixture must not unregister login items") }
    func openSystemSettings() { XCTFail("Preset fixture must not open settings") }
}

private final class RejectingPresetDefaults: UserDefaults, @unchecked Sendable {
    nonisolated(unsafe) var rejectPresetWrites = false
    override func set(_ value: Any?, forKey defaultName: String) {
        guard defaultName != MenuBarPresetStore.key || !rejectPresetWrites else { return }
        super.set(value, forKey: defaultName)
    }
}
