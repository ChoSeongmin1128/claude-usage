import Foundation
import XCTest
@testable import ClaudeUsage

@MainActor
final class MenuBarPresetPreservationReviewTests: XCTestCase {
    func testUnsupportedNestedFieldsRemainRawWhenAnotherSourceChanges() throws {
        for field in ["gauges", "selection"] {
            try withDefaults { defaults in
                var raw = try self.record()
                var display = try XCTUnwrap(raw["display"] as? [String: Any])
                var catalog = try XCTUnwrap(display["catalog"] as? [String: Any])
                var value = try XCTUnwrap(catalog["_0"] as? [String: Any])
                if field == "gauges" {
                    value["gauges"] = ["layout": "future", "titles": [:]]
                } else {
                    value["selection"] = [
                        "percentageIDs": ["5h"], "resetIDs": [], "gaugeIDs": [], "titles": [:],
                        "arrangement": ["orderedIDs": ["5h"], "gaugeGroups": [], "gaugeLayout": "future"],
                    ]
                }
                catalog["_0"] = value
                display["catalog"] = catalog
                raw["display"] = display
                try self.seed([raw], defaults: defaults)
                let store = MenuBarPresetStore(defaults: defaults)
                XCTAssertTrue(store.presets.isEmpty)
                try store.record(.builtin(.number), for: .codex)
                XCTAssertEqual(try self.rows(defaults).first as? NSDictionary, raw as NSDictionary)
            }
        }
    }

    func testExplicitDeletionRemovesDuplicateRawUUIDsWithoutRevivingThePreset() throws {
        try withDefaults { defaults in
            let raw = try self.record()
            try self.seed([raw, raw, 17], defaults: defaults)
            let store = MenuBarPresetStore(defaults: defaults)
            let preset = try XCTUnwrap(store.presets.first)
            XCTAssertEqual(store.presets.count, 1)
            try store.delete(preset.id)
            XCTAssertTrue(store.presets.isEmpty)
            XCTAssertEqual(try self.rows(defaults).count, 1)
            XCTAssertEqual(try self.rows(defaults).first as? Int, 17)
        }
    }

    func testUpdatingKnownAppearanceRetainsUnknownFieldsAndCanClearOptionalFields() throws {
        try withDefaults { defaults in
            var raw = try self.record()
            raw["futureRoot"] = true
            var display = try XCTUnwrap(raw["display"] as? [String: Any])
            var catalog = try XCTUnwrap(display["catalog"] as? [String: Any])
            var value = try XCTUnwrap(catalog["_0"] as? [String: Any])
            value["futureAppearance"] = 17
            value["gauges"] = ["layout": "horizontal", "titles": [:]]
            catalog["_0"] = value
            display["catalog"] = catalog
            raw["display"] = display
            try self.seed([raw], defaults: defaults)
            let store = MenuBarPresetStore(defaults: defaults)
            let preset = try XCTUnwrap(store.presets.first)
            guard case .catalog(var appearance) = preset.display else { return XCTFail("Catalog preset required") }
            appearance.showsLogo.toggle()
            appearance.gauges = nil
            try store.update(preset.id, display: .catalog(appearance))
            try store.rename(preset.id, name: "연구")
            let row = try XCTUnwrap(try self.rows(defaults).first as? [String: Any])
            XCTAssertEqual(row["futureRoot"] as? Bool, true)
            XCTAssertEqual(row["name"] as? String, "연구")
            let storedDisplay = try XCTUnwrap(row["display"] as? [String: Any])
            let storedCatalog = try XCTUnwrap(storedDisplay["catalog"] as? [String: Any])
            let storedValue = try XCTUnwrap(storedCatalog["_0"] as? [String: Any])
            XCTAssertEqual(storedValue["futureAppearance"] as? Int, 17)
            XCTAssertNil(storedValue["gauges"])
            XCTAssertEqual(store.presets.first?.display, .catalog(appearance))
        }
    }

    private func record() throws -> [String: Any] {
        let preset = MenuBarUserPreset(
            id: UUID(), provider: .claude, name: "집중",
            display: .catalog(MenuBarPresetCatalog.catalogDisplay(.number, provider: .claude)))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(preset)) as? [String: Any])
    }

    private func seed(_ rows: [Any], defaults: UserDefaults) throws {
        defaults.set(
            try JSONSerialization.data(withJSONObject: ["version": 1, "presets": rows, "applied": [:]]),
            forKey: MenuBarPresetStore.key)
    }

    private func rows(_ defaults: UserDefaults) throws -> [Any] {
        let data = try XCTUnwrap(defaults.data(forKey: MenuBarPresetStore.key))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["presets"] as? [Any])
    }

    private func withDefaults(_ action: (UserDefaults) throws -> Void) throws {
        let suite = "PresetPreservationReviewTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try action(defaults)
    }
}
