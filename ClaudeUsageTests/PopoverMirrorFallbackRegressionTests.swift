import XCTest
@testable import ClaudeUsage

@MainActor
final class PopoverMirrorFallbackRegressionTests: XCTestCase {
    func testHealthyMirrorFillsQuarantinedRootRowWithoutChangingItsStorage() throws {
        let name = "PopoverMirrorFallbackRegressionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(5, forKey: "popoverItemsMigrationVersion")
        let root = Data(
            #"{"claude":[{"id":"currentSession","visible":false}],"codex":[{"id":"codexPrimary","visible":"bad"},{"id":"codexSecondary","visible":false}]}"#
                .utf8)
        let mirror = Data(
            #"[{"id":"codexPrimary","visible":false,"unknown":null},{"id":"codexSecondary","visible":false}]"#.utf8)
        defaults.set(root, forKey: "popoverItemsV2")
        defaults.set(mirror, forKey: "codexPopoverItems")
        let store = PopoverDisplayPreferencesStore(defaults: defaults)
        let displayed = store.items(for: .codex, surface: .standard)
        XCTAssertEqual(displayed.first?.id, "codexPrimary")
        XCTAssertEqual(displayed.first?.visible, false)
        var edited = displayed
        edited[0].visible = true
        XCTAssertThrowsError(try store.setItems(edited, for: .codex, surface: .standard))
        var reordered = displayed
        reordered.swapAt(0, 1)
        XCTAssertThrowsError(try store.setItems(reordered, for: .codex, surface: .standard))
        XCTAssertEqual(defaults.data(forKey: "popoverItemsV2"), root)
        XCTAssertEqual(defaults.data(forKey: "codexPopoverItems"), mirror)
        var claude = store.items(for: .claude, surface: .standard)
        claude[0].visible = true
        try store.setItems(claude, for: .claude, surface: .standard)
        XCTAssertEqual(defaults.data(forKey: "codexPopoverItems"), mirror)
        let after = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(defaults.data(forKey: "popoverItemsV2"))) as? [String: Any]
        )
        let rows = try XCTUnwrap(after["codex"] as? [[String: Any]])
        XCTAssertEqual(rows[0]["visible"] as? String, "bad")
    }
}
