import Foundation
import XCTest
@testable import ClaudeUsage

@MainActor
final class HoverDisplayPreferencesTests: XCTestCase {
    func testMissingIsReadOnlyAndEmptyIsAnIndependentSelection() throws {
        try withDefaults { defaults in
            let store = PopoverDisplayPreferencesStore(defaults: defaults)
            XCTAssertNil(defaults.object(forKey: PopoverHoverPreferences.key))
            XCTAssertEqual(
                store.items(for: .claude, surface: .hover).filter(\.visible).map(\.id),
                ["currentSession", "weeklyLimit"])
            try store.setItems([], for: .claude, surface: .hover)
            XCTAssertTrue(store.items(for: .claude, surface: .hover).allSatisfy { !$0.visible })
            XCTAssertTrue(store.items(for: .codex, surface: .hover).filter(\.visible).count == 2)
            XCTAssertTrue(store.items(for: .claude, surface: .standard).allSatisfy(\.visible))
            XCTAssertTrue(
                PopoverDisplayPreferencesStore(defaults: defaults).items(for: .claude, surface: .hover).allSatisfy {
                    !$0.visible
                })
        }
    }

    func testHoverPreservesUnknownRecordsAndProvidersAndBlocksFutureVersions() throws {
        try withDefaults { defaults in
            let raw: [String: Any] = [
                "version": 1,
                "providers": [
                    "claude": [
                        ["id": "future", "visible": true], ["id": "weeklyLimit", "visible": false, "future": 42], 17,
                    ], "future": ["keep": true],
                ], "extra": 23,
            ]
            defaults.set(try JSONSerialization.data(withJSONObject: raw), forKey: PopoverHoverPreferences.key)
            let hover = PopoverHoverPreferences(defaults: defaults)
            try hover.setItems([.init(id: "weeklyLimit", visible: true)], for: ClaudeItemCatalog())
            let data = try XCTUnwrap(defaults.data(forKey: PopoverHoverPreferences.key))
            let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let providers = try XCTUnwrap(saved["providers"] as? [String: Any])
            XCTAssertEqual(saved["extra"] as? Int, 23)
            XCTAssertEqual(providers["future"] as? [String: Bool], ["keep": true])
            let items = try XCTUnwrap(providers["claude"] as? [Any])
            XCTAssertEqual(items.last as? Int, 17)
            let weekly = items.compactMap { $0 as? [String: Any] }.first { $0["id"] as? String == "weeklyLimit" }
            XCTAssertEqual(weekly?["future"] as? Int, 42)
            XCTAssertEqual(weekly?["visible"] as? Bool, true)
            XCTAssertTrue(items.contains { ($0 as? [String: Any])?["id"] as? String == "future" })
        }
        for object: Any in [
            Data("broken".utf8), "wrong-type", Data(#"{"version":2,"providers":{}}"#.utf8),
            Data(#"{"version":true,"providers":{}}"#.utf8),
        ] {
            try withDefaults { defaults in
                defaults.set(object, forKey: PopoverHoverPreferences.key)
                let hover = PopoverHoverPreferences(defaults: defaults)
                XCTAssertThrowsError(try hover.setItems([], for: ClaudeItemCatalog()))
                hover.restoreDefaults()
                XCTAssertEqual(defaults.object(forKey: PopoverHoverPreferences.key) as? NSObject, object as? NSObject)
            }
        }
    }

    func testConflictAndSnapshotPreserveTheActualStoredObject() throws {
        try withDefaults { defaults in
            let hover = PopoverHoverPreferences(defaults: defaults)
            let snapshot = hover.snapshot()
            try hover.setItems([], for: ClaudeItemCatalog())
            hover.restore(snapshot)
            XCTAssertNil(defaults.object(forKey: PopoverHoverPreferences.key))
            let external = Data(#"{"version":1,"providers":{},"other":true}"#.utf8)
            defaults.set(external, forKey: PopoverHoverPreferences.key)
            XCTAssertThrowsError(try hover.setItems([], for: ClaudeItemCatalog()))
            XCTAssertEqual(defaults.data(forKey: PopoverHoverPreferences.key), external)
        }
    }

    func testAntigravityInheritanceEmptyIntentAndUnknownFields() throws {
        let inherited = AntigravityHoverDisplayPreferences.inherited
        let compact = AntigravityDisplaySettings.default.compact
        XCTAssertEqual(inherited.effectiveSelection(compact: compact), compact)
        let empty = AntigravityDisplaySettings.LaneListPresentationIntent(
            orderedLaneIDs: [], hiddenLaneIDs: Set(AntigravityDisplaySettings.builtInLaneIDs), orderingPolicy: .manual)
        let saved = AntigravityHoverDisplayPreferences(stored: .data(try inherited.encoding(empty)))
        XCTAssertEqual(saved.selection, empty)
        XCTAssertEqual(saved.effectiveSelection(compact: compact), empty)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: inherited.encoding(empty)) as? [String: Any])
        root["extra"] = 17
        var selection = try XCTUnwrap(root["selection"] as? [String: Any])
        selection["future"] = true
        root["selection"] = selection
        let withExtra = AntigravityHoverDisplayPreferences(
            stored: .data(try JSONSerialization.data(withJSONObject: root)))
        let updated = try XCTUnwrap(JSONSerialization.jsonObject(with: withExtra.encoding(compact)) as? [String: Any])
        XCTAssertEqual(updated["extra"] as? Int, 17)
        XCTAssertEqual((updated["selection"] as? [String: Any])?["future"] as? Bool, true)
        let future = AntigravityHoverDisplayPreferences(stored: .data(Data(#"{"version":2,"selection":{}}"#.utf8)))
        XCTAssertFalse(future.isWritable)
        XCTAssertEqual(future.effectiveSelection(compact: compact), compact)
        XCTAssertThrowsError(try future.encoding(empty))
    }

    private func withDefaults(_ action: (UserDefaults) throws -> Void) throws {
        let suite = "HoverDisplayPreferencesTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try action(defaults)
    }
}
