import AppKit
import SwiftUI
import XCTest
@testable import ClaudeUsage

@MainActor
final class MenuBarQuotaEditorTests: XCTestCase {
    private let base = MenuBarQuotaSelection(
        percentageIDs: ["weekly"], resetIDs: ["session"], gaugeIDs: ["session", "weekly", "fable"],
        titles: ["fable": "Fable"])

    private var overlap: MenuBarQuotaArrangement {
        MenuBarQuotaArrangement(
            orderedIDs: ["session", "weekly", "fable"], gaugeGroups: [["session", "weekly"], ["fable"]],
            gaugeLayout: .concentric)
    }

    func testOpeningLegacyThreeGaugeSelectionPreservesItsActualHorizontalLayout() {
        let derived = MenuBarQuotaArrangement.baseline(selection: base, layout: .concentric)
        XCTAssertEqual(derived.gaugeLayout, .horizontal)
        XCTAssertEqual(derived.gaugeGroups, [["session"], ["weekly"], ["fable"]])
        XCTAssertEqual(base.percentageIDs, ["weekly"])
        XCTAssertEqual(base.resetIDs, ["session"])
    }

    func testConcentricUnitDragKeepsMembersAndRingOrder() {
        let result = overlap.reorderingUnits([["fable"], ["session", "weekly"]], selection: base)
        XCTAssertEqual(result.orderedIDs, ["fable", "session", "weekly"])
        XCTAssertEqual(result.gaugeGroups, [["fable"], ["session", "weekly"]])
        XCTAssertEqual(result.units(selection: base).map(\.quotaIDs), [["fable"], ["session", "weekly"]])
        XCTAssertTrue(result.isValid)
    }

    func testQuotaDragSwapsOuterAndInnerWithoutChangingSurfaceSelections() {
        let result = overlap.reorderingQuotas(["weekly", "session", "fable"], selection: base)
        XCTAssertEqual(result.gaugeGroups, [["weekly", "session"], ["fable"]])
        let model = editor(selection: base, arrangement: result)
        XCTAssertEqual(model.role(for: "weekly"), .outer)
        XCTAssertEqual(model.role(for: "session"), .inner)
        XCTAssertEqual(model.selection.percentageIDs, ["weekly"])
        XCTAssertEqual(model.selection.resetIDs, ["session"])
    }

    func testTextOnlyQuotaParticipatesInOrderAndDoesNotBecomeAGauge() {
        var selected = base
        selected.percentageIDs.append("credits")
        let result = overlap.reorderingQuotas(["credits", "session", "weekly", "fable"], selection: selected)
        XCTAssertEqual(result.units(selection: selected).first?.quotaIDs, ["credits"])
        XCTAssertTrue(result.units(selection: selected).first?.gaugeIDs.isEmpty == true)
        XCTAssertFalse(selected.gaugeIDs.contains("credits"))
    }

    func testSelectedMissingModelKeepsItsNamePositionAndUnknownValue() {
        let model = editor(selection: base, arrangement: overlap)
        let missing = model.selectedItems.first { $0.id == "fable" }
        XCTAssertEqual(missing?.title, "Fable")
        XCTAssertNil(missing?.usedPercentage)
        XCTAssertFalse(missing?.canSelect == true)
        XCTAssertEqual(model.arrangement.orderedIDs.last, "fable")
    }

    func testStaleDragCannotResurrectRemovedQuotaAndNewQuotaIsRetained() {
        var current = base
        current.gaugeIDs.removeAll { $0 == "fable" }
        XCTAssertEqual(
            overlap.reorderingQuotas(["fable", "session", "weekly"], selection: current),
            overlap.resolved(selection: current))
        current.gaugeIDs.append("opus")
        let result = overlap.reorderingQuotas(["weekly", "session"], selection: current)
        XCTAssertTrue(result.orderedIDs.contains("opus"))
        XCTAssertFalse(result.orderedIDs.contains("fable"))
    }

    func testMalformedArrangementCannotDuplicateOrDropGaugeValues() {
        let malformed = MenuBarQuotaArrangement(
            orderedIDs: ["session", "session", "unknown"],
            gaugeGroups: [["session", "session", "weekly", "fable"], ["unknown"]], gaugeLayout: .concentric)
        XCTAssertFalse(malformed.isValid)
        let resolved = malformed.resolved(selection: base)
        XCTAssertTrue(resolved.isValid)
        XCTAssertEqual(Set(resolved.gaugeGroups.flatMap { $0 }), Set(base.gaugeIDs))
        XCTAssertEqual(resolved.orderedIDs.count, base.selectedIDs.count)
    }

    func testArrangementCodableUsesExistingLayoutNames() throws {
        let encoded = try JSONEncoder().encode(overlap)
        XCTAssertEqual(try JSONDecoder().decode(MenuBarQuotaArrangement.self, from: encoded), overlap)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("concentric"))
    }

    func testPreviewIgnoresVerticalMotionAndKeepsExactUnitMembership() {
        let canvas = MenuBarQuotaPreviewCanvas(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 30),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        defer { window.close() }
        var order: [[String]]?
        var selected: [String]?
        let units = [unit(["session", "weekly"], width: 85), unit(["fable"], width: 30)]
        canvas.update(layout: .init(units: units), onSelect: { selected = $0 }, onReorder: { order = $0 })
        let start = canvas.frames(for: units)[0].midpoint
        canvas.mouseDown(with: event(.leftMouseDown, point: start, canvas: canvas, window: window))
        canvas.mouseDragged(
            with: event(.leftMouseDragged, point: CGPoint(x: start.x, y: start.y + 150), canvas: canvas, window: window)
        )
        canvas.mouseDragged(
            with: event(.leftMouseDragged, point: CGPoint(x: 145, y: start.y - 200), canvas: canvas, window: window))
        canvas.mouseUp(
            with: event(.leftMouseUp, point: CGPoint(x: 145, y: start.y - 200), canvas: canvas, window: window))
        XCTAssertEqual(order, [["fable"], ["session", "weekly"]])
        XCTAssertNil(selected)
    }

    func testSmallHorizontalMovementDoesNotJumpWideUnitPastNarrowUnits() {
        let canvas = MenuBarQuotaPreviewCanvas(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 30),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        defer { window.close() }
        let units = [unit(["session"], width: 100), unit(["weekly"], width: 30), unit(["fable"], width: 30)]
        var order: [[String]]?
        canvas.update(layout: .init(units: units), onSelect: { _ in }, onReorder: { order = $0 })
        let start = canvas.frames(for: units)[0].midpoint
        canvas.mouseDown(with: event(.leftMouseDown, point: start, canvas: canvas, window: window))
        canvas.mouseDragged(
            with: event(
                .leftMouseDragged, point: CGPoint(x: start.x + 4, y: start.y + 100), canvas: canvas, window: window))
        canvas.mouseUp(
            with: event(.leftMouseUp, point: CGPoint(x: start.x + 4, y: start.y + 100), canvas: canvas, window: window))
        XCTAssertNil(order, "An unchanged order must not save a new configuration")
    }

    func testDraggingWideUnitPastNarrowUnitAndBackRestoresOriginalOrder() {
        let canvas = MenuBarQuotaPreviewCanvas(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        let window = NSWindow(contentRect: canvas.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        defer { window.close() }
        let units = [unit(["session", "weekly"], width: 100), unit(["fable"], width: 30)]
        var order: [[String]]?
        canvas.update(layout: .init(units: units), onSelect: { _ in }, onReorder: { order = $0 })
        let start = canvas.frames(for: units)[0].midpoint
        canvas.mouseDown(with: event(.leftMouseDown, point: start, canvas: canvas, window: window))
        canvas.mouseDragged(
            with: event(.leftMouseDragged, point: CGPoint(x: start.x + 100, y: start.y), canvas: canvas, window: window)
        )
        canvas.mouseDragged(with: event(.leftMouseDragged, point: start, canvas: canvas, window: window))
        canvas.mouseUp(with: event(.leftMouseUp, point: start, canvas: canvas, window: window))
        XCTAssertNil(order, "An unchanged order must not save a new configuration")
    }

    func testVerticalOnlyPreviewMotionDoesNotCommitAConfigurationChange() {
        let canvas = MenuBarQuotaPreviewCanvas(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        let window = NSWindow(contentRect: canvas.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        defer { window.close() }
        let units = [unit(["session"], width: 100), unit(["weekly"], width: 30)]
        var commits = 0
        canvas.update(layout: .init(units: units), onSelect: { _ in }, onReorder: { _ in commits += 1 })
        let start = canvas.frames(for: units)[0].midpoint
        let end = CGPoint(x: start.x, y: start.y + 150)
        canvas.mouseDown(with: event(.leftMouseDown, point: start, canvas: canvas, window: window))
        canvas.mouseDragged(with: event(.leftMouseDragged, point: end, canvas: canvas, window: window))
        canvas.mouseUp(with: event(.leftMouseUp, point: end, canvas: canvas, window: window))
        XCTAssertEqual(commits, 0)
    }

    func testZeroAndMissingRingsShowFocusWithoutChangingTheirQuotaValues() throws {
        for used in [Double?(100), nil] {
            let selection = MenuBarQuotaSelection(gaugeIDs: ["session"])
            let limit = UsageLimit(
                id: "session", provider: .claude, title: "5시간", shortTitle: "5시간",
                scope: "session", periodSeconds: 18000, usedPercentage: used, resetAt: nil,
                isIdentifiable: true, legacyKey: nil)
            let projection = MenuBarQuotaProjection(
                selection: selection, limits: [limit], basis: .remaining, timeFormat: .h24)
            let arrangement = MenuBarQuotaArrangement.baseline(selection: selection, layout: .horizontal)
            let appearance = NSAppearance(named: .aqua)!
            let plain = MenuBarStatusComposer.quotaUnits(
                projection: projection, arrangement: arrangement, config: fixtureConfig, appearance: appearance)[0]
                .image
            let focused = MenuBarStatusComposer.quotaUnits(
                projection: projection, arrangement: arrangement, config: fixtureConfig, highlightedID: "session",
                appearance: appearance)[0].image
            func pixels(_ image: NSImage) throws -> Data {
                let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
                return try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
            }
            XCTAssertNotEqual(try pixels(plain), try pixels(focused))
            XCTAssertEqual(projection.limit("session")?.usedPercentage, used)
            XCTAssertEqual(plain.size, focused.size)
        }
    }

    func testPreviewEscapeRestoresOrderAndDoesNotCommit() {
        let canvas = MenuBarQuotaPreviewCanvas(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 30),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        defer { window.close() }
        let units = [unit(["session"], width: 40), unit(["weekly"], width: 40)]
        var commits = 0
        canvas.update(layout: .init(units: units), onSelect: { _ in }, onReorder: { _ in commits += 1 })
        let start = canvas.frames(for: units)[0].midpoint
        canvas.mouseDown(with: event(.leftMouseDown, point: start, canvas: canvas, window: window))
        canvas.mouseDragged(
            with: event(.leftMouseDragged, point: CGPoint(x: 100, y: start.y), canvas: canvas, window: window))
        canvas.cancelDrag()
        canvas.mouseUp(with: event(.leftMouseUp, point: CGPoint(x: 100, y: start.y), canvas: canvas, window: window))
        XCTAssertEqual(commits, 0)
    }

    func testRendererAndComposerKeepWholeUnitsAndTheirAssociatedTextTogether() {
        let appearance = NSAppearance(named: .aqua)!
        let projection = MenuBarQuotaProjection(
            selection: base, limits: fixtureLimits, basis: .remaining, timeFormat: .h24)
        let units = MenuBarStatusComposer.quotaUnits(
            projection: projection, arrangement: overlap, config: fixtureConfig, appearance: appearance)
        XCTAssertEqual(units.map(\.ids), [["session", "weekly"], ["fable"]])
        XCTAssertEqual(units[0].selectedID(at: CGPoint(x: 10, y: 11)), "weekly")
        XCTAssertEqual(units[0].selectedID(at: CGPoint(x: 17, y: 11)), "session")
        let snapshot = MenuBarProviderSnapshot(
            kind: .claude, text: "duplicate legacy text", color: .labelColor, tooltip: "fixture",
            icon: nil, styleIcon: NSImage(size: NSSize(width: 100, height: 20)), resetText: "duplicate reset",
            systemStatus: nil
        ).withQuotaUnits(units)
        let rendered = MenuBarStatusComposer.singleProviderContent(
            snapshot: snapshot, secondaryColor: .secondaryLabelColor, appearance: appearance)
        let preview = MenuBarStatusComposer.quotaPreviewLayout(
            snapshot: snapshot, units: units, secondaryColor: .secondaryLabelColor, appearance: appearance)
        XCTAssertEqual(rendered.image.size.width, preview.width)
        XCTAssertEqual(rendered.image.size.width, units.reduce(0) { $0 + $1.image.size.width } + 4)
        let moved = overlap.reorderingUnits([["fable"], ["session", "weekly"]], selection: base)
        let reordered = MenuBarStatusComposer.quotaUnits(
            projection: projection, arrangement: moved, config: fixtureConfig, appearance: appearance)
        XCTAssertEqual(reordered.map(\.ids), [["fable"], ["session", "weekly"]])
        XCTAssertEqual(reordered[1].image.size, units[0].image.size)
    }

    func testPreviewClickSelectsInnerRingInsteadOfFirstMember() {
        let canvas = MenuBarQuotaPreviewCanvas(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        let window = NSWindow(contentRect: canvas.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        defer { window.close() }
        let units = MenuBarStatusComposer.quotaUnits(
            projection: .init(selection: base, limits: fixtureLimits, basis: .remaining, timeFormat: .h24),
            arrangement: overlap, config: fixtureConfig, appearance: NSAppearance(named: .aqua)!)
        var selected: [String]?
        canvas.update(layout: .init(units: units), onSelect: { selected = $0 }, onReorder: { _ in })
        let frame = canvas.frames(for: units)[0]
        let point = CGPoint(x: frame.minX + 10, y: frame.minY + 11)
        canvas.mouseDown(with: event(.leftMouseDown, point: point, canvas: canvas, window: window))
        canvas.mouseUp(with: event(.leftMouseUp, point: point, canvas: canvas, window: window))
        XCTAssertEqual(selected, ["weekly"])
    }

    func testMissingResetOnlyQuotaRemainsEditableWithoutInventingATimestamp() {
        let selection = MenuBarQuotaSelection(resetIDs: ["missing"], titles: ["missing": "Missing"])
        let units = MenuBarStatusComposer.quotaUnits(
            projection: .init(selection: selection, limits: [], basis: .remaining, timeFormat: .h24),
            arrangement: .baseline(selection: selection, layout: .horizontal), config: fixtureConfig,
            appearance: NSAppearance(named: .aqua)!)
        XCTAssertEqual(units.map(\.ids), [["missing"]])
        XCTAssertGreaterThan(units[0].image.size.width, 0)
        XCTAssertEqual(units[0].selectedID(at: CGPoint(x: 2, y: 11)), "missing")
    }

    func testNativeEditorRendersAtNarrowAndRegularWidthsInBothAppearances() throws {
        for width in [CGFloat(380), 580] {
            for scheme in [ColorScheme.light, .dark] {
                let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
                let projection = MenuBarQuotaProjection(
                    selection: base, limits: fixtureLimits, basis: .remaining, timeFormat: .h24)
                let view = MenuBarQuotaEditor(
                    model: editor(selection: base, arrangement: overlap),
                    renderPreview: { arrangement, highlighted in
                        .init(
                            units: MenuBarStatusComposer.quotaUnits(
                                projection: projection, arrangement: arrangement, config: self.fixtureConfig,
                                highlightedID: highlighted, appearance: appearance))
                    }, onAction: { _ in }
                )
                .padding(24).frame(width: width).background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
                let host = NSHostingView(rootView: view)
                host.appearance = appearance
                host.frame = NSRect(x: 0, y: 0, width: width, height: 580)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let image = NSImage(size: host.bounds.size)
                image.addRepresentation(bitmap)
                let attachment = XCTAttachment(image: image)
                attachment.name = "editor-a-\(Int(width))-\(scheme == .dark ? "dark" : "light")"
                attachment.lifetime = .keepAlways
                add(attachment)
                @MainActor func findCanvas(_ view: NSView) -> MenuBarQuotaPreviewCanvas? {
                    if let canvas = view as? MenuBarQuotaPreviewCanvas { return canvas }
                    return view.subviews.compactMap { findCanvas($0) }.first
                }
                let canvas = try XCTUnwrap(findCanvas(host))
                canvas.onSelect?(["weekly"])
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                host.layoutSubtreeIfNeeded()
                let expanded = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: expanded)
                let expandedImage = NSImage(size: host.bounds.size)
                expandedImage.addRepresentation(expanded)
                let expandedAttachment = XCTAttachment(image: expandedImage)
                expandedAttachment.name = "editor-a-\(Int(width))-\(scheme == .dark ? "dark" : "light")-expanded"
                expandedAttachment.lifetime = .keepAlways
                add(expandedAttachment)
            }
        }
    }

    func testAddingFourthConcentricGaugePairsTheExistingSingleWithoutChangingFirstPair() {
        let items = ["session", "weekly", "fable", "gemini"].map {
            MenuBarQuotaEditorItem(id: $0, title: $0, usedPercentage: 20, canSelect: true)
        }
        let model = MenuBarQuotaEditorModel(
            provider: .claude, items: items, selection: base, arrangement: overlap, shape: .circular)
        let updated = model.applying(.add("gemini"))
        XCTAssertEqual(updated.arrangement.gaugeGroups, [["session", "weekly"], ["fable", "gemini"]])
        XCTAssertEqual(updated.selection.percentageIDs, model.selection.percentageIDs)
        XCTAssertEqual(updated.selection.resetIDs, model.selection.resetIDs)
    }

    func testTimeOnlyQuotaCanBeAddedWithoutInventingAGaugeOrNumber() {
        let model = MenuBarQuotaEditorModel(
            provider: .antigravity,
            items: [
                .init(id: "time", title: "시간 한도", usedPercentage: nil, canSelect: true, selectableSurfaces: [.reset])
            ],
            selection: .init(), arrangement: .baseline(selection: .init(), layout: .horizontal), shape: .circular)
        let updated = model.applying(.add("time"))
        XCTAssertEqual(updated.selection.resetIDs, ["time"])
        XCTAssertTrue(updated.selection.gaugeIDs.isEmpty)
        XCTAssertTrue(updated.selection.percentageIDs.isEmpty)
        XCTAssertEqual(updated.applying(.setSurface("time", .gauge, true)), updated)
        XCTAssertEqual(updated.applying(.setSurface("time", .percentage, true)), updated)
    }

    func testReenteringConcentricLayoutUsesTheUserChangedHorizontalOrder() {
        let horizontal = overlap.settingLayout(.horizontal, selection: base)
            .reorderingQuotas(["weekly", "session", "fable"], selection: base)
        let updated = horizontal.settingLayout(.concentric, selection: base)
        XCTAssertEqual(updated.gaugeGroups, [["weekly", "session"], ["fable"]])
        XCTAssertEqual(updated.orderedIDs, ["weekly", "session", "fable"])
    }

    func testProductionSnapshotUsesStoredWholeUnitsAndInvalidatesGroupingChanges() throws {
        let usage = ClaudeUsageResponse(
            fiveHour: .init(utilization: 8, resetsAt: "2030-01-01T01:00:00Z"),
            sevenDay: .init(utilization: 20, resetsAt: "2030-01-03T04:00:00Z"))
        let limits = UsageLimitCatalog.claude(usage)
        let ids = limits.map(\.id)
        XCTAssertEqual(ids.count, 2)
        var selection = MenuBarQuotaSelection(percentageIDs: ids, resetIDs: [ids[0]], gaugeIDs: ids)
        selection.arrangement = .baseline(selection: selection, layout: .concentric)
        var config = fixtureConfig
        config = config.settingQuotaSelection(selection, gauges: .init(ids: ids, layout: .concentric))
        func snapshot(_ config: ProviderMenuBarDisplayConfig, images: Bool = true) -> MenuBarProviderSnapshot {
            MenuBarStatusComposer.claudeSnapshot(
                config: config, usage: usage, error: nil, hasAuthError: false, hasCredential: true,
                secondaryColor: .secondaryLabelColor, icon: nil, renderImages: images,
                appearance: NSAppearance(named: .aqua))
        }
        let grouped = snapshot(config)
        XCTAssertEqual(grouped.quotaUnits?.map(\.ids), [ids])
        let keyOnly = snapshot(config, images: false)
        XCTAssertEqual(grouped.renderKey, keyOnly.renderKey)
        selection.arrangement = selection.arrangement?.reorderingQuotas(Array(ids.reversed()), selection: selection)
        config = config.settingQuotaSelection(selection)
        let reversed = snapshot(config)
        XCTAssertEqual(reversed.quotaUnits?.map(\.ids), [Array(ids.reversed())])
        XCTAssertNotEqual(reversed.renderKey, grouped.renderKey)
        selection.arrangement = nil
        config = config.settingQuotaSelection(selection)
        XCTAssertNil(snapshot(config).quotaUnits, "Opening legacy settings must not switch their production renderer")
    }

    func testNumericOnlyModelThresholdCrossingChangesRenderKeyEvenWithIdenticalRoundedText() throws {
        func usage(_ percent: Double) -> ClaudeUsageResponse {
            .init(
                fiveHour: .init(utilization: 8, resetsAt: nil), sevenDay: .init(utilization: 20, resetsAt: nil),
                scopedLimits: [.init(kind: "weekly_scoped", percent: percent, modelID: "fable", modelName: "Fable")])
        }
        let first = usage(74.9)
        let second = usage(75.1)
        let id = try XCTUnwrap(UsageLimitCatalog.claude(first).first(where: \.isModelScoped)).id
        var selection = MenuBarQuotaSelection(percentageIDs: [id])
        selection.arrangement = .baseline(selection: selection, layout: .horizontal)
        var config = fixtureConfig
        config = config.settingQuotaSelection(selection, gauges: .init(ids: []))
        func snapshot(_ value: ClaudeUsageResponse) -> MenuBarProviderSnapshot {
            MenuBarStatusComposer.claudeSnapshot(
                config: config, usage: value, error: nil, hasAuthError: false, hasCredential: true,
                secondaryColor: .secondaryLabelColor, icon: nil, renderImages: false)
        }
        let before = snapshot(first)
        let after = snapshot(second)
        XCTAssertEqual(before.regularText, after.regularText)
        XCTAssertEqual(before.tooltip, after.tooltip)
        XCTAssertNotEqual(before.renderKey, after.renderKey)
    }

    func testHighContrastSecondaryTextReachesStoredUnitsInSingleAndMultipleMenuBars() throws {
        let usage = ClaudeUsageResponse(
            fiveHour: .init(utilization: 8, resetsAt: "2030-01-01T01:00:00Z"), sevenDay: nil)
        let id = try XCTUnwrap(UsageLimitCatalog.claude(usage).first).id
        var selected = MenuBarQuotaSelection(resetIDs: [id])
        selected.arrangement = .baseline(selection: selected, layout: .horizontal)
        var config = fixtureConfig
        config = config.settingQuotaSelection(selected, gauges: .init(ids: []))
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        func rendered(_ color: NSColor, multiple: Bool) -> Data? {
            let snapshot = MenuBarStatusComposer.claudeSnapshot(
                config: config, usage: usage, error: nil, hasAuthError: false, hasCredential: true,
                secondaryColor: color, icon: nil, appearance: appearance)
            let content =
                multiple
                ? MenuBarStatusComposer.multipleProviderContent(
                    snapshots: [snapshot], secondaryColor: color, appearance: appearance)
                : MenuBarStatusComposer.singleProviderContent(
                    snapshot: snapshot, secondaryColor: color, appearance: appearance)
            return content.image.tiffRepresentation
        }
        for multiple in [false, true] {
            let normal = try XCTUnwrap(rendered(.secondaryLabelColor, multiple: multiple))
            let contrasted = try XCTUnwrap(rendered(.labelColor, multiple: multiple))
            XCTAssertNotEqual(normal, contrasted)
        }
    }

    func testHiddenGaugeOnlyUnitDoesNotInventAnUnknownResetLabel() {
        let selection = MenuBarQuotaSelection(gaugeIDs: ["session"])
        let config = ProviderMenuBarDisplayConfig(
            kind: .claude, showIcon: false, style: .none, percentageDisplay: .none,
            showBatteryPercent: false, resetTimeDisplay: .none, timeFormat: .h24,
            circularDisplayMode: .remaining, iconMetric: .fiveHour)
        let units = MenuBarStatusComposer.quotaUnits(
            projection: .init(selection: selection, limits: [], basis: .remaining, timeFormat: .h24),
            arrangement: .baseline(selection: selection, layout: .horizontal), config: config,
            appearance: NSAppearance(named: .aqua)!)
        XCTAssertTrue(units.isEmpty)
    }

    private var fixtureConfig: ProviderMenuBarDisplayConfig {
        .init(
            kind: .claude, showIcon: false, style: .circular, percentageDisplay: .none,
            showBatteryPercent: true, resetTimeDisplay: .none, timeFormat: .h24,
            circularDisplayMode: .remaining, iconMetric: .fiveHour, basisOverride: .remaining,
            quotaSelection: base, gaugeSelection: .init(ids: base.gaugeIDs, layout: .concentric))
    }

    private var fixtureLimits: [UsageLimit] {
        [("session", "5시간 한도", 8.0, 18000), ("weekly", "주간 한도", 20.0, 604800)].map { id, title, used, period in
            .init(
                id: id, provider: .claude, title: title, shortTitle: title, scope: id, periodSeconds: period,
                usedPercentage: used, resetAt: Date(timeIntervalSince1970: 2000000000), isIdentifiable: true,
                legacyKey: nil)
        }
    }

    private func editor(selection: MenuBarQuotaSelection, arrangement: MenuBarQuotaArrangement)
        -> MenuBarQuotaEditorModel
    {
        MenuBarQuotaEditorModel(
            provider: .claude,
            items: [
                .init(id: "session", title: "5시간 한도", usedPercentage: 8, canSelect: true),
                .init(id: "weekly", title: "주간 한도", usedPercentage: 20, canSelect: true),
            ], selection: selection, arrangement: arrangement, shape: .circular)
    }

    private func unit(_ ids: [String], width: CGFloat) -> MenuBarQuotaRenderedUnit {
        .init(ids: ids, image: NSImage(size: NSSize(width: width, height: 20)), title: ids.joined(separator: ","))
    }

    private func event(_ type: NSEvent.EventType, point: CGPoint, canvas: NSView, window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
}

private extension CGRect {
    var midpoint: CGPoint { CGPoint(x: midX, y: midY) }
}
