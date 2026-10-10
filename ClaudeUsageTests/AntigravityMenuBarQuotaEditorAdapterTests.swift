import AppKit
import XCTest

@testable import ClaudeUsage

@MainActor
final class AntigravityMenuBarQuotaEditorAdapterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let first = AntigravityQuotaLaneID.geminiFiveHour.rawValue
    private let second = AntigravityQuotaLaneID.geminiWeekly.rawValue
    private let third = AntigravityQuotaLaneID.thirdPartyWeekly.rawValue

    func testOpeningAutomaticSelectionDoesNotPinItsRepresentativeOrCreateArrangement() throws {
        let settings = AntigravityDisplaySettings.default
        let presented = presentation(settings: settings)
        let model = AntigravityMenuBarQuotaEditorAdapter.editorModel(settings: settings, presentation: presented)
        XCTAssertEqual(model.selection.percentageIDs, [second])
        XCTAssertTrue(model.selection.gaugeIDs.isEmpty)
        XCTAssertNil(settings.menuBar.arrangement)
        XCTAssertEqual(settings.menuBar.laneSelection, .automaticMostConstrained)
        XCTAssertNil(
            AntigravityMenuBarQuotaEditorAdapter.renderedUnits(
                settings: settings, presentation: presented, design: .modern, colorMode: .always,
                appearance: try XCTUnwrap(NSAppearance(named: .aqua))))
        XCTAssertEqual(
            AntigravityMenuBarQuotaEditorAdapter.applying(
                .reorderQuotas([second]), settings: settings, presentation: presented), settings)
    }

    func testExplicitEditorOrderUsesRawLaneIDsAndKeepsLegacySurfaceMirrors() throws {
        var settings = AntigravityDisplaySettings.default
        settings.menuBar.style = .circular
        settings.menuBar.gaugeLaneIDs = [.geminiFiveHour, .geminiWeekly, .thirdPartyWeekly]
        settings.menuBar.percentageLaneIDs = [.geminiWeekly]
        settings.menuBar.resetLaneIDs = [.geminiFiveHour]
        let presented = presentation(settings: settings)
        let concentric = AntigravityMenuBarQuotaEditorAdapter.settingLayout(
            .concentric, settings: settings, presentation: presented)
        let updated = AntigravityMenuBarQuotaEditorAdapter.applying(
            .reorderQuotas([second, first, third]), settings: concentric, presentation: presented)
        let model = AntigravityMenuBarQuotaEditorAdapter.editorModel(settings: updated, presentation: presented)
        XCTAssertEqual(model.arrangement.gaugeGroups, [[second, first], [third]])
        XCTAssertEqual(model.role(for: second), .outer)
        XCTAssertEqual(model.role(for: first), .inner)
        XCTAssertEqual(updated.menuBar.gaugeLaneIDs?.map(\.rawValue), [second, first, third])
        XCTAssertEqual(updated.menuBar.percentageLaneIDs, [.geminiWeekly])
        XCTAssertEqual(updated.menuBar.resetLaneIDs, [.geminiFiveHour])
        XCTAssertEqual(updated.menuBar.laneSelection, .automaticMostConstrained)
        XCTAssertEqual(updated.standard, settings.standard)
        XCTAssertEqual(updated.compact, settings.compact)
        XCTAssertEqual(updated.notifications, settings.notifications)
        let reloaded = try JSONDecoder().decode(AntigravityDisplaySettings.self, from: JSONEncoder().encode(updated))
        XCTAssertEqual(reloaded, updated)
        XCTAssertTrue(reloaded.isCurrentAndValid)
    }

    func testTurningShapeOffPreservesSelectedNumbersAndResetTimes() {
        var settings = AntigravityDisplaySettings.default
        settings.menuBar.style = .circular
        settings.menuBar.gaugeLaneIDs = [.geminiFiveHour, .geminiWeekly]
        settings.menuBar.percentageLaneIDs = [.geminiWeekly]
        settings.menuBar.resetLaneIDs = [.geminiFiveHour]
        let presented = presentation(settings: settings)
        let updated = AntigravityMenuBarQuotaEditorAdapter.settingShape(
            .none, settings: settings, presentation: presented)
        XCTAssertEqual(updated.menuBar.style, .none)
        XCTAssertEqual(updated.menuBar.gaugeLaneIDs, [])
        XCTAssertEqual(updated.menuBar.percentageLaneIDs, [.geminiWeekly])
        XCTAssertEqual(updated.menuBar.resetLaneIDs, [.geminiFiveHour])
        XCTAssertEqual(updated.menuBar.arrangement?.orderedIDs, [first, second])
        XCTAssertTrue(updated.menuBar.arrangement?.gaugeGroups.isEmpty == true)
    }

    func testShapeChangesTranslatePairLayoutAndKeepLaneMembershipAndOrder() {
        var settings = AntigravityDisplaySettings.default
        settings.menuBar.style = .circular
        settings.menuBar.gaugeLaneIDs = [.geminiFiveHour, .geminiWeekly, .thirdPartyWeekly]
        settings.menuBar.percentageLaneIDs = []
        settings.menuBar.resetLaneIDs = []
        let presented = presentation(settings: settings)
        settings = AntigravityMenuBarQuotaEditorAdapter.settingLayout(
            .concentric, settings: settings, presentation: presented)
        let battery = AntigravityMenuBarQuotaEditorAdapter.settingShape(
            .batteryBar, settings: settings, presentation: presented)
        XCTAssertEqual(battery.menuBar.style, .batteryBar)
        XCTAssertEqual(battery.menuBar.arrangement?.gaugeLayout, .stacked)
        XCTAssertEqual(battery.menuBar.arrangement?.gaugeGroups, [[first, second], [third]])
        let circular = AntigravityMenuBarQuotaEditorAdapter.settingShape(
            .circular, settings: battery, presentation: presented)
        XCTAssertEqual(circular.menuBar.style, .circular)
        XCTAssertEqual(circular.menuBar.arrangement?.gaugeLayout, .concentric)
        XCTAssertEqual(circular.menuBar.arrangement?.gaugeGroups, [[first, second], [third]])
        XCTAssertEqual(circular.menuBar.gaugeLaneIDs, settings.menuBar.gaugeLaneIDs)
    }

    func testLegacyTextOnlyShapeChangeAddsOneChosenGaugeWithoutDroppingText() {
        let settings = AntigravityDisplaySettings.default
        let presented = presentation(settings: settings)
        let updated = AntigravityMenuBarQuotaEditorAdapter.settingShape(
            .batteryBar, settings: settings, presentation: presented)
        XCTAssertEqual(updated.menuBar.style, .batteryBar)
        XCTAssertEqual(updated.menuBar.gaugeLaneIDs, [.geminiWeekly])
        XCTAssertEqual(updated.menuBar.percentageLaneIDs, [.geminiWeekly])
        XCTAssertNil(updated.menuBar.resetLaneIDs)
        XCTAssertEqual(updated.menuBar.showsSelectedLaneResetTime, settings.menuBar.showsSelectedLaneResetTime)
        XCTAssertEqual(updated.menuBar.arrangement?.orderedIDs, [second])
        XCTAssertEqual(updated.menuBar.laneSelection, .automaticMostConstrained)
        XCTAssertEqual(updated.menuBar.circularValue, settings.menuBar.circularValue)
    }

    func testShapeChangeDoesNotAddAnUnselectedRepresentative() {
        var settings = AntigravityDisplaySettings.default
        settings.menuBar.percentageLaneIDs = []
        settings.menuBar.resetLaneIDs = []
        settings.menuBar.gaugeLaneIDs = []
        let presented = presentation(settings: settings)
        XCTAssertNotNil(presented.menuBar.selectedLaneID)
        let updated = AntigravityMenuBarQuotaEditorAdapter.settingShape(
            .batteryBar, settings: settings, presentation: presented)
        XCTAssertEqual(updated.menuBar.style, .batteryBar)
        XCTAssertEqual(updated.menuBar.gaugeLaneIDs, [])
        XCTAssertEqual(updated.menuBar.arrangement?.orderedIDs, [])
    }

    func testShapeChangeBeforeFirstReportPreservesAutomaticSelectionAndTextDefaults() {
        let settings = AntigravityDisplaySettings.default
        let updated = AntigravityMenuBarQuotaEditorAdapter.settingShape(
            .batteryBar, settings: settings, presentation: nil)
        XCTAssertEqual(updated.menuBar.style, .batteryBar)
        XCTAssertNil(updated.menuBar.arrangement)
        XCTAssertNil(updated.menuBar.gaugeLaneIDs)
        XCTAssertNil(updated.menuBar.percentageLaneIDs)
        XCTAssertNil(updated.menuBar.resetLaneIDs)
        XCTAssertEqual(updated.menuBar.showsSelectedLanePercentage, settings.menuBar.showsSelectedLanePercentage)
        XCTAssertEqual(updated.menuBar.showsSelectedLaneResetTime, settings.menuBar.showsSelectedLaneResetTime)
        let reported = presentation(settings: updated)
        let model = AntigravityMenuBarQuotaEditorAdapter.editorModel(settings: updated, presentation: reported)
        XCTAssertEqual(model.selection.gaugeIDs, [second])
        XCTAssertEqual(model.selection.percentageIDs, [second])
    }

    func testUnavailableSelectionKeepsOriginalPositionTitleAndUnknownValue() {
        var settings = AntigravityDisplaySettings.default
        let missing = "removed.weekly"
        settings.menuBar.style = .circular
        settings.menuBar.gaugeLaneIDs = [AntigravityQuotaLaneID(rawValue: missing), .geminiFiveHour]
        settings.menuBar.percentageLaneIDs = []
        settings.menuBar.resetLaneIDs = []
        settings.menuBar.gaugeTitles = [missing: "Removed model / 주간"]
        let presented = presentation(settings: settings)
        let model = AntigravityMenuBarQuotaEditorAdapter.editorModel(settings: settings, presentation: presented)
        XCTAssertEqual(model.selectedItems.map(\.id), [missing, first])
        XCTAssertEqual(model.selectedItems.first?.title, "Removed model / 주간")
        XCTAssertNil(model.selectedItems.first?.usedPercentage)
        XCTAssertEqual(model.selectedItems.first?.canSelect, false)
        let items = AntigravityMenuBarQuotaEditorAdapter.renderItems(
            model: model, settings: settings, presentation: presented, colorMode: .always, now: now, timeZone: utc)
        XCTAssertNil(items[0].gauge.value.percentage)
        XCTAssertEqual(items[0].gauge.color, NSColor.secondaryLabelColor)
        let removed = AntigravityMenuBarQuotaEditorAdapter.applying(
            .remove(missing), settings: settings, presentation: presented)
        XCTAssertEqual(removed.menuBar.gaugeLaneIDs, [.geminiFiveHour])
    }

    func testTimeOnlyLaneCanBeAddedWithoutInventingNumericQuota() {
        var settings = AntigravityDisplaySettings.default
        settings.menuBar.percentageLaneIDs = []
        settings.menuBar.resetLaneIDs = []
        settings.menuBar.gaugeLaneIDs = []
        let timeOnly = lane(.thirdPartyWeekly, scope: .thirdPartyModels, cadence: .weekly, remaining: nil)
        let presented = presentation(settings: settings, lanes: [timeOnly])
        let model = AntigravityMenuBarQuotaEditorAdapter.editorModel(settings: settings, presentation: presented)
        XCTAssertEqual(model.availableItems.first?.selectableSurfaces, [.reset])
        let added = AntigravityMenuBarQuotaEditorAdapter.applying(
            .add(third), settings: settings, presentation: presented)
        XCTAssertEqual(added.menuBar.resetLaneIDs, [.thirdPartyWeekly])
        XCTAssertEqual(added.menuBar.percentageLaneIDs, [])
        XCTAssertEqual(added.menuBar.gaugeLaneIDs, [])
        let unchanged = AntigravityMenuBarQuotaEditorAdapter.applying(
            .setSurface(third, .gauge, true), settings: added, presentation: presented)
        XCTAssertEqual(unchanged, added)
        let addedModel = AntigravityMenuBarQuotaEditorAdapter.editorModel(settings: added, presentation: presented)
        let items = AntigravityMenuBarQuotaEditorAdapter.renderItems(
            model: addedModel, settings: added, presentation: presented, colorMode: .always, now: now, timeZone: utc)
        XCTAssertNil(items[0].percentageText)
        XCTAssertNotNil(items[0].resetText)
        XCTAssertNil(items[0].gauge.value.usedPercentage)
    }

    func testKnownNumericLaneMayShowAnUnknownResetWithoutSubstitutingAnotherLane() {
        var settings = AntigravityDisplaySettings.default
        settings.menuBar.percentageLaneIDs = [.geminiFiveHour]
        settings.menuBar.resetLaneIDs = []
        settings.menuBar.gaugeLaneIDs = []
        let numeric = AntigravityQuotaLane(
            id: .geminiFiveHour, upstreamGroupID: "group", upstreamBucketID: "bucket",
            scope: .gemini, cadence: .fiveHour, remainingFraction: 0.8, resetAt: nil,
            resetDescription: nil, availability: .available)
        let presented = presentation(settings: settings, lanes: [numeric])
        let updated = AntigravityMenuBarQuotaEditorAdapter.applying(
            .setSurface(first, .reset, true), settings: settings, presentation: presented)
        XCTAssertEqual(updated.menuBar.resetLaneIDs, [.geminiFiveHour])
        let model = AntigravityMenuBarQuotaEditorAdapter.editorModel(settings: updated, presentation: presented)
        let items = AntigravityMenuBarQuotaEditorAdapter.renderItems(
            model: model, settings: updated, presentation: presented, colorMode: .always, now: now, timeZone: utc)
        XCTAssertEqual(items[0].resetText, "갱신 시각 알 수 없음")
        XCTAssertEqual(items[0].id, first)
        XCTAssertEqual(items[0].gauge.value.percentage ?? -1, 80, accuracy: 0.001)
    }

    func testDisabledLaneCannotBeAddedButAnExistingSelectionCanBeRemoved() {
        var settings = AntigravityDisplaySettings.default
        settings.menuBar.percentageLaneIDs = []
        let disabled = lane(
            .geminiWeekly, scope: .gemini, cadence: .weekly, remaining: 0.5, availability: .disabled)
        let presented = presentation(settings: settings, lanes: [disabled])
        let model = AntigravityMenuBarQuotaEditorAdapter.editorModel(settings: settings, presentation: presented)
        XCTAssertTrue(model.availableItems.isEmpty)
        XCTAssertEqual(
            AntigravityMenuBarQuotaEditorAdapter.applying(.add(second), settings: settings, presentation: presented),
            settings)
        settings.menuBar.percentageLaneIDs = [.geminiWeekly]
        let updated = AntigravityMenuBarQuotaEditorAdapter.applying(
            .remove(second), settings: settings, presentation: presented)
        XCTAssertEqual(updated.menuBar.percentageLaneIDs, [])
    }

    func testResponsiveTextAndToneUseAntigravitySemanticsWithRemainingBasis() throws {
        var settings = AntigravityDisplaySettings.default
        settings.menuBar.style = .circular
        settings.menuBar.gaugeLaneIDs = [.geminiWeekly]
        settings.menuBar.percentageLaneIDs = [.geminiWeekly]
        settings.menuBar.resetLaneIDs = [.geminiWeekly]
        settings.menuBar.timeFormat = .remaining
        let presented = presentation(settings: settings)
        let model = AntigravityMenuBarQuotaEditorAdapter.editorModel(settings: settings, presentation: presented)
        let items = AntigravityMenuBarQuotaEditorAdapter.renderItems(
            model: model, settings: settings, presentation: presented, colorMode: .always, now: now, timeZone: utc)
        let item = try XCTUnwrap(items.first)
        let mapped = try XCTUnwrap(presented.allGroups.flatMap(\.lanes).first { $0.id.rawValue == second })
        XCTAssertEqual(item.id, second)
        XCTAssertEqual(item.gauge.value.percentage ?? -1, 10, accuracy: 0.001)
        XCTAssertEqual(item.percentageText, "\(mapped.menuLabel) 10%")
        XCTAssertEqual(item.condensedPercentageText, "10%")
        XCTAssertEqual(item.resetText, "1h 00m")
        XCTAssertEqual(item.condensedResetText, "")
        XCTAssertEqual(mapped.tone, .critical)
        XCTAssertEqual(item.gauge.color, NSColor.systemRed)
        let mono = AntigravityMenuBarQuotaEditorAdapter.renderItems(
            model: model, settings: settings, presentation: presented, colorMode: .statusNumber, now: now,
            timeZone: utc)[0]
        XCTAssertEqual(mono.gauge.color, NSColor.labelColor)
        XCTAssertEqual(mono.gauge.textColor, NSColor.systemRed)
        XCTAssertFalse(mono.gauge.monochrome)
    }

    func testPreviewWholePairMovesWithoutSwappingItsInnerAndOuterLane() throws {
        var settings = AntigravityDisplaySettings.default
        settings.menuBar.style = .circular
        settings.menuBar.gaugeLaneIDs = [.geminiFiveHour, .geminiWeekly, .thirdPartyWeekly]
        settings.menuBar.percentageLaneIDs = []
        settings.menuBar.resetLaneIDs = []
        let presented = presentation(settings: settings)
        settings = AntigravityMenuBarQuotaEditorAdapter.settingLayout(
            .concentric, settings: settings, presentation: presented)
        let updated = AntigravityMenuBarQuotaEditorAdapter.applying(
            .reorderUnits([[third], [first, second]]), settings: settings, presentation: presented)
        let model = AntigravityMenuBarQuotaEditorAdapter.editorModel(settings: updated, presentation: presented)
        XCTAssertEqual(model.arrangement.orderedIDs, [third, first, second])
        XCTAssertEqual(model.arrangement.gaugeGroups, [[third], [first, second]])
        let units = AntigravityMenuBarQuotaEditorAdapter.renderedUnits(
            model: model, settings: updated, presentation: presented, design: .modern, colorMode: .always,
            appearance: try XCTUnwrap(NSAppearance(named: .aqua)), now: now, timeZone: utc)
        XCTAssertEqual(units.map(\.ids), [[third], [first, second]])
        XCTAssertEqual(units[1].selectedID(at: CGPoint(x: 10, y: 11)), second)
        XCTAssertEqual(units[1].selectedID(at: CGPoint(x: 17, y: 11)), first)
    }

    func testShapeOnlyChangeAfterTimeOnlyPartialPreservesAutomaticNumericSelectionOnRecovery() {
        let original = AntigravityDisplaySettings.default
        let partial = presentation(
            settings: original, lanes: [lane(.geminiFiveHour, scope: .gemini, cadence: .fiveHour, remaining: nil)])
        let updated = AntigravityMenuBarQuotaEditorAdapter.settingShape(
            .batteryBar, settings: original, presentation: partial)
        XCTAssertEqual(updated.menuBar.style, .batteryBar)
        XCTAssertNil(updated.menuBar.percentageLaneIDs)
        XCTAssertNil(updated.menuBar.resetLaneIDs)
        XCTAssertNil(updated.menuBar.gaugeLaneIDs)
        XCTAssertNil(updated.menuBar.arrangement)
        let recovered = AntigravityMenuBarQuotaEditorAdapter.editorModel(
            settings: updated, presentation: presentation(settings: updated))
        XCTAssertEqual(recovered.selection.percentageIDs, [second])
        XCTAssertEqual(recovered.selection.gaugeIDs, [second])
    }

    func testAddingTimeOnlyQuotaDoesNotTurnUnobservedAutomaticNumbersOff() {
        let original = AntigravityDisplaySettings.default
        let partial = presentation(
            settings: original, lanes: [lane(.geminiFiveHour, scope: .gemini, cadence: .fiveHour, remaining: nil)])
        let updated = AntigravityMenuBarQuotaEditorAdapter.applying(
            .add(first), settings: original, presentation: partial)
        XCTAssertEqual(updated.menuBar.resetLaneIDs, [.geminiFiveHour])
        XCTAssertNil(updated.menuBar.percentageLaneIDs)
        let recovered = AntigravityMenuBarQuotaEditorAdapter.editorModel(
            settings: updated, presentation: presentation(settings: updated))
        XCTAssertEqual(recovered.selection.percentageIDs, [second])
        XCTAssertEqual(recovered.selection.resetIDs, [first])
    }

    func testNumericOnlyNonRepresentativeThresholdChangesKeyWithoutRoundedTextChanging() throws {
        var settings = AntigravityDisplaySettings.default
        settings.menuBar.gaugeLaneIDs = []
        settings.menuBar.percentageLaneIDs = [.geminiFiveHour]
        settings.menuBar.resetLaneIDs = []
        settings.menuBar.arrangement = .init(orderedIDs: [first], gaugeGroups: [], gaugeLayout: .horizontal)
        func mapped(_ used: Double) -> AntigravityQuotaPresentation {
            presentation(
                settings: settings,
                lanes: [
                    lane(.geminiFiveHour, scope: .gemini, cadence: .fiveHour, remaining: 1 - used / 100),
                    lane(.geminiWeekly, scope: .gemini, cadence: .weekly, remaining: 0.1),
                ])
        }
        let before = mapped(74.99)
        let after = mapped(75.01)
        XCTAssertEqual(before.menuBar.regularText, after.menuBar.regularText)
        XCTAssertEqual(before.menuBar.condensedText, after.menuBar.condensedText)
        XCTAssertEqual(before.menuBar.tooltip, after.menuBar.tooltip)
        XCTAssertEqual(before.menuBar.tone, after.menuBar.tone)
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let firstSnapshot = try XCTUnwrap(
            MenuBarStatusComposer.antigravitySnapshot(
                presentation: before.menuBar, icon: nil, renderImages: false, appearance: appearance,
                arrangement: settings.menuBar.arrangement))
        let secondSnapshot = try XCTUnwrap(
            MenuBarStatusComposer.antigravitySnapshot(
                presentation: after.menuBar, icon: nil, renderImages: false, appearance: appearance,
                arrangement: settings.menuBar.arrangement))
        XCTAssertNotEqual(firstSnapshot.renderKey, secondSnapshot.renderKey)
    }

    private func presentation(
        settings: AntigravityDisplaySettings, lanes supplied: [AntigravityQuotaLane]? = nil
    ) -> AntigravityQuotaPresentation {
        let lanes =
            supplied ?? [
                lane(.geminiFiveHour, scope: .gemini, cadence: .fiveHour, remaining: 0.8),
                lane(.geminiWeekly, scope: .gemini, cadence: .weekly, remaining: 0.1),
                lane(.thirdPartyWeekly, scope: .thirdPartyModels, cadence: .weekly, remaining: 0.5),
            ]
        let snapshot = AntigravityQuotaSnapshot(
            identity: nil, plan: "fixture", lanes: lanes, decodeIssues: [],
            provenance: AntigravityQuotaProvenance(
                transport: .cliUsageReport, endpointOwner: .external, accountIdentity: nil,
                capability: .groupedQuotaSummary, processIdentity: nil), fetchedAt: now)
        return AntigravityQuotaPresentationMapper.map(
            snapshot: snapshot, settings: settings, basisOverride: .remaining, now: now, timeZone: utc)
    }

    private func lane(
        _ id: AntigravityQuotaLaneID, scope: AntigravityQuotaScope, cadence: AntigravityQuotaCadence,
        remaining: Double?, availability: AntigravityQuotaAvailability = .available
    ) -> AntigravityQuotaLane {
        AntigravityQuotaLane(
            id: id, upstreamGroupID: "group", upstreamBucketID: id.rawValue,
            scope: scope, cadence: cadence, remainingFraction: remaining, resetAt: now.addingTimeInterval(3600),
            resetDescription: nil, availability: availability)
    }
}
