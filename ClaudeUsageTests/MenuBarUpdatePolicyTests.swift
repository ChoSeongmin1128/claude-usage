import AppKit
import XCTest
@testable import ClaudeUsage

@MainActor
final class MenuBarUpdatePolicyTests: XCTestCase {
    func testRepeatedAppearanceDoesNotRequestUpdate() {
        var state = MenuBarAppearanceChangeState(
            initialKey: .dark
        )

        XCTAssertFalse(
            state.shouldRequestUpdate(for: .dark)
        )
        XCTAssertFalse(
            state.shouldRequestUpdate(for: .dark)
        )
    }

    func testAppearanceTransitionsRequestExactlyOnce() {
        var state = MenuBarAppearanceChangeState(
            initialKey: .light
        )

        XCTAssertTrue(
            state.shouldRequestUpdate(for: .dark)
        )
        XCTAssertFalse(
            state.shouldRequestUpdate(for: .dark)
        )
        XCTAssertTrue(
            state.shouldRequestUpdate(
                for: .highContrastDark
            )
        )
        XCTAssertFalse(
            state.shouldRequestUpdate(
                for: .highContrastDark
            )
        )
    }

    func testAppearanceKeyDistinguishesLightAndDark() throws {
        let light = try XCTUnwrap(
            NSAppearance(named: .aqua)
        )
        let dark = try XCTUnwrap(
            NSAppearance(named: .darkAqua)
        )

        XCTAssertEqual(
            MenuBarAppearanceKey(light),
            .light
        )
        XCTAssertEqual(
            MenuBarAppearanceKey(dark),
            .dark
        )
        XCTAssertEqual(
            MenuBarAppearanceKey(
                dark,
                highContrast: true
            ),
            .highContrastDark
        )
    }

    func testSameRunLoopRequestsAreCoalesced() {
        var state = MenuBarUpdateRequestState()

        XCTAssertTrue(state.request(force: false))
        XCTAssertFalse(state.request(force: false))
        XCTAssertFalse(state.request(force: false))
        XCTAssertEqual(state.consume(), false)
        XCTAssertNil(state.consume())
    }

    func testForcedRequestIsPreservedWhileCoalescing() {
        var state = MenuBarUpdateRequestState()

        XCTAssertTrue(state.request(force: false))
        XCTAssertFalse(state.request(force: true))
        XCTAssertFalse(state.request(force: false))
        XCTAssertEqual(state.consume(), true)
    }

    func testIdenticalRenderKeyIsNotAppliedTwice() {
        var state = MenuBarContentApplicationState()
        let key = renderKey()

        XCTAssertTrue(
            state.shouldApply(key, force: false)
        )
        XCTAssertFalse(
            state.shouldApply(key, force: false)
        )
        XCTAssertTrue(
            state.shouldApply(key, force: true)
        )
    }

    func testUsageAndAppearanceChangesInvalidateRenderKey() {
        var state = MenuBarContentApplicationState()
        let initial = renderKey(
            appearance: .light,
            percentage: 25
        )
        let changedUsage = renderKey(
            appearance: .light,
            percentage: 26
        )
        let changedAppearance = renderKey(
            appearance: .dark,
            percentage: 26
        )

        XCTAssertTrue(
            state.shouldApply(initial, force: false)
        )
        XCTAssertTrue(
            state.shouldApply(
                changedUsage,
                force: false
            )
        )
        XCTAssertTrue(
            state.shouldApply(
                changedAppearance,
                force: false
            )
        )
    }

    func testProviderOrderIsPartOfRenderKey() {
        let claude = providerKey(
            kind: .claude,
            percentage: 20
        )
        let codex = providerKey(
            kind: .codex,
            percentage: 30
        )
        let first = MenuBarRenderKey(
            appearance: .dark,
            usesHighContrastText: false,
            layout: .multiple([claude, codex])
        )
        let reversed = MenuBarRenderKey(
            appearance: .dark,
            usesHighContrastText: false,
            layout: .multiple([codex, claude])
        )

        XCTAssertNotEqual(first, reversed)
    }

    func testProviderStateAndDisplayChangesInvalidateRenderKey() {
        let initial = providerKey(
            kind: .claude,
            percentage: 20
        )
        let authError = providerKey(
            kind: .claude,
            percentage: 20,
            regularText: "로그인",
            statusIndicator: .critical
        )
        let stale = providerKey(
            kind: .claude,
            percentage: 20,
            isStale: true
        )
        let changedDisplay = providerKey(
            kind: .claude,
            percentage: 20,
            visualConfiguration: ["battery"]
        )

        XCTAssertNotEqual(initial, authError)
        XCTAssertNotEqual(initial, stale)
        XCTAssertNotEqual(initial, changedDisplay)
    }

    func testSingleAndMultipleProviderLayoutsDiffer() {
        let claude = providerKey(
            kind: .claude,
            percentage: 20
        )
        let single = MenuBarRenderKey(
            appearance: .dark,
            usesHighContrastText: false,
            layout: .single(claude)
        )
        let multiple = MenuBarRenderKey(
            appearance: .dark,
            usesHighContrastText: false,
            layout: .multiple([claude])
        )

        XCTAssertNotEqual(single, multiple)
    }

    func testProviderIconIsCachedBySemanticAppearance()
        throws
    {
        MenuBarIconFactory
            .resetProviderIconCacheForTesting()
        let appearance = try XCTUnwrap(
            NSAppearance(named: .aqua)
        )
        let first = try XCTUnwrap(
            MenuBarIconFactory.providerMenuBarIcon(
                for: .claude,
                size: NSSize(width: 14, height: 14),
                appearance: appearance
            )
        )
        let second = try XCTUnwrap(
            MenuBarIconFactory.providerMenuBarIcon(
                for: .claude,
                size: NSSize(width: 14, height: 14),
                appearance: appearance
            )
        )

        XCTAssertTrue(first === second)
    }

    private func renderKey(
        appearance: MenuBarAppearanceKey = .dark,
        percentage: Double = 25
    ) -> MenuBarRenderKey {
        MenuBarRenderKey(
            appearance: appearance,
            usesHighContrastText: false,
            layout: .single(
                providerKey(
                    kind: .claude,
                    percentage: percentage
                )
            )
        )
    }

    private func providerKey(
        kind: AppProviderKind,
        percentage: Double,
        regularText: String? = nil,
        statusIndicator: StatusIndicator? = nil,
        isStale: Bool = false,
        visualConfiguration: [String] = ["circular"]
    ) -> MenuBarProviderRenderKey {
        let text = regularText
            ?? "\(Int(percentage))%"
        return MenuBarProviderRenderKey(
            kind: kind,
            regularText: text,
            condensedText: text,
            tooltip: regularText
                ?? "현재 \(Int(percentage))%",
            resetText: nil,
            showsProviderIcon: true,
            visualConfiguration: visualConfiguration,
            visualValues: [percentage],
            statusIndicator: statusIndicator,
            systemStatusSummary: nil,
            accessibilityLabel: kind.displayName,
            accessibilityValue:
                "현재 \(Int(percentage))%",
            isStale: isStale
        )
    }
}
