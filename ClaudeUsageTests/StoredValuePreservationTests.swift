import Foundation
import XCTest
@testable import ClaudeUsage

/// 이전 버전으로 되돌려 실행해도 새 버전이 저장한 설정이 지워지지 않는지 본다.
@MainActor
final class StoredValuePreservationTests: XCTestCase {
    func testPreservingJSONArrayKeepsUnreadableElementsInOrder() throws {
        let data = Data(#"[{"value":1},{"value":"future"},2,{"value":3}]"#.utf8)
        let decoded = try XCTUnwrap(PreservingJSONArray.decode(Item.self, from: data))
        XCTAssertEqual(decoded.elements, [Item(value: 1), Item(value: 3)])
        XCTAssertEqual(decoded.unreadable.count, 2)

        let encoded = try XCTUnwrap(PreservingJSONArray.encode([Item(value: 4)], preserving: decoded.unreadable))
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [Any])
        XCTAssertEqual(raw.count, 3)
        XCTAssertEqual((raw[0] as? [String: Any])?["value"] as? Int, 4)
        XCTAssertEqual((raw[1] as? [String: Any])?["value"] as? String, "future")
        XCTAssertEqual(raw[2] as? Int, 2)
        XCTAssertNil(PreservingJSONArray.decode(Item.self, from: Data(#"{"value":1}"#.utf8)))
    }

    func testProviderCatalogKeepsUnknownProviderAndClearsItsActiveFlag() throws {
        let data = Data(
            #"{"states":{"claude":{"isEnabled":true,"isActive":false},"future":{"isEnabled":true,"isActive":true}}}"#
                .utf8)
        var catalog = try JSONDecoder().decode(AppProviderStateCatalog.self, from: data)
        XCTAssertNil(catalog.activeProviderKind)

        catalog.setEnabled(true, for: .codex)
        let kept = try rawStates(JSONEncoder().encode(catalog))
        XCTAssertEqual(kept["future"]?["isEnabled"], true)
        XCTAssertEqual(kept["future"]?["isActive"], true)
        XCTAssertEqual(kept["codex"]?["isEnabled"], true)

        catalog.setActiveProvider(.claude)
        let switched = try rawStates(JSONEncoder().encode(catalog))
        XCTAssertEqual(switched["future"]?["isEnabled"], true)
        XCTAssertEqual(switched["future"]?["isActive"], false)
        XCTAssertEqual(switched["claude"]?["isActive"], true)
    }

    func testUnreadableProviderStatesAreNotRewrittenOnLaunch() throws {
        try withDefaults { defaults in
            let stored = Data(#"{"states":"future-format"}"#.utf8)
            defaults.set(stored, forKey: "providerStates")
            defaults.set(true, forKey: "claudeEnabled")
            defaults.set(true, forKey: "codexEnabled")

            let store = ProviderSelectionPreferencesStore(defaults: defaults)
            XCTAssertTrue(store.providerStates.state(for: .codex).isEnabled)
            XCTAssertEqual(defaults.data(forKey: "providerStates"), stored)
        }
    }

    func testMissingProviderStatesAreImportedFromLegacyKeysOnce() throws {
        try withDefaults { defaults in
            defaults.set(false, forKey: "claudeEnabled")
            defaults.set(true, forKey: "codexEnabled")
            defaults.set("codex", forKey: "menuBarActiveService")

            let store = ProviderSelectionPreferencesStore(defaults: defaults)
            XCTAssertEqual(store.providerStates.activeProviderKind, .codex)
            let saved = try XCTUnwrap(defaults.data(forKey: "providerStates"))
            let decoded = try JSONDecoder().decode(AppProviderStateCatalog.self, from: saved)
            XCTAssertEqual(decoded, store.providerStates)
        }
    }

    func testNewerNotificationRulesAreNotOverwrittenOnLaunch() throws {
        try withDefaults { defaults in
            let stored = Data(#"{"schemaVersion":3,"presets":[],"rules":[{"id":"future"}]}"#.utf8)
            defaults.set(stored, forKey: NotificationThresholdStorage.key)

            let settings = makeSettings(defaults)
            XCTAssertFalse(settings.notificationPresets.isEmpty)
            XCTAssertEqual(defaults.data(forKey: NotificationThresholdStorage.key), stored)

            settings.notificationPresets = [NotificationPreset(id: "user", threshold: 80)]
            guard case .presets(let saved) = NotificationThresholdStorage.load(from: defaults) else {
                return XCTFail("A user edit must save the current format")
            }
            XCTAssertEqual(saved.map(\.id), ["user"])
        }
    }

    func testMissingNotificationRulesAreImportedAndSaved() throws {
        try withDefaults { defaults in
            XCTAssertEqual(NotificationThresholdStorage.load(from: defaults), .missing)
            let settings = makeSettings(defaults)
            XCTAssertEqual(NotificationThresholdStorage.load(from: defaults), .presets(settings.notificationPresets))
        }
    }

    func testUnknownGaugeLayoutKeepsOtherMenuBarSelections() throws {
        try withDefaults { defaults in
            let data = Data(
                #"""
                {"version":1,
                 "providers":{"claude":{"percentageIDs":["weekly"],"resetIDs":[],"gaugeIDs":["weekly"],"titles":{}}},
                 "gauges":{"claude":{"ids":["weekly"],"titles":{"weekly":"주간"},"layout":"future","showsLabels":true},
                           "codex":{"ids":["session"],"titles":{},"layout":"stacked"}}}
                """#.utf8)
            defaults.set(data, forKey: MenuBarQuotaPreferences.key)

            let loaded = MenuBarQuotaPreferences.load(from: defaults)
            XCTAssertEqual(loaded.providers["claude"]?.percentageIDs, ["weekly"])
            XCTAssertEqual(
                loaded.gauges?["claude"],
                MenuBarGaugeSelection(ids: ["weekly"], titles: ["weekly": "주간"], layout: .horizontal, showsLabels: true)
            )
            XCTAssertEqual(loaded.gauges?["codex"]?.layout, .stacked)
        }
    }

    private struct Item: Codable, Equatable {
        let value: Int
    }

    private func rawStates(_ data: Data) throws -> [String: [String: Bool]] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["states"] as? [String: [String: Bool]])
    }

    private func makeSettings(_ defaults: UserDefaults) -> AppSettings {
        AppSettings(
            defaults: defaults, hasExistingAccountStorage: false,
            launchAtLoginController: LaunchAtLoginController(service: PreservationLoginItemService()))
    }

    private func withDefaults(_ operation: (UserDefaults) throws -> Void) throws {
        let suite = "StoredValuePreservationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try operation(defaults)
    }
}

private struct PreservationLoginItemService: LoginItemManaging {
    var status: LoginItemStatus { .notRegistered }
    func register() throws { XCTFail("Storage fixture must not register login items") }
    func unregister() throws { XCTFail("Storage fixture must not unregister login items") }
    func openSystemSettings() { XCTFail("Storage fixture must not open system settings") }
}
