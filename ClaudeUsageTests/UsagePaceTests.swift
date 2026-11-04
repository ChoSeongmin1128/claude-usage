import SwiftUI
import XCTest
@testable import ClaudeUsage

@MainActor
final class UsagePaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(remaining: TimeInterval, length: Int = UsageWindowLength.fiveHour) -> UsagePaceWindow? {
        UsagePaceWindow(resetAt: now.addingTimeInterval(remaining), lengthSeconds: length)
    }

    func testElapsedFractionCoversTheWholeWindowInclusively() throws {
        XCTAssertEqual(try XCTUnwrap(window(remaining: 18_000)).elapsedFraction(now: now), 0)
        XCTAssertEqual(try XCTUnwrap(window(remaining: 3 * 3600)).elapsedFraction(now: now) ?? -1, 0.4, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(window(remaining: 0)).elapsedFraction(now: now), 1)
    }

    func testOutsideTheWindowIsHiddenInsteadOfPinnedToAnEnd() throws {
        XCTAssertNil(try XCTUnwrap(window(remaining: -1)).elapsedFraction(now: now))
        XCTAssertNil(try XCTUnwrap(window(remaining: 18_001)).elapsedFraction(now: now))
    }

    func testUnknownResetOrLengthHasNoWindow() {
        XCTAssertNil(UsagePaceWindow(resetAt: nil, lengthSeconds: 18_000))
        XCTAssertNil(UsagePaceWindow(resetAt: now, lengthSeconds: nil))
        XCTAssertNil(UsagePaceWindow(resetAt: now, lengthSeconds: 0))
        XCTAssertNil(UsagePaceWindow(resetAt: now, lengthSeconds: -60))
        XCTAssertNil(UsagePaceWindow(resetAtISO: "not-a-date", lengthSeconds: 18_000))
        XCTAssertNil(UsagePaceWindow(resetAtISO: nil, lengthSeconds: 18_000))
        XCTAssertEqual(
            UsagePaceWindow(resetAtISO: "2027-01-15T08:00:00Z", lengthSeconds: 18_000)?.resetAt,
            ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
    }

    func testMarkerFollowsTheDisplayBasisLikeTheFill() throws {
        let window = try XCTUnwrap(window(remaining: 3 * 3600))
        let used = try XCTUnwrap(window.marker(basis: .used, now: now))
        let remaining = try XCTUnwrap(window.marker(basis: .remaining, now: now))
        XCTAssertEqual(used.elapsedPercentage, 40, accuracy: 1e-9)
        XCTAssertEqual(remaining.elapsedPercentage, 40, accuracy: 1e-9)
        XCTAssertEqual(used.displayPercentage, UsageValueBasis.used.percentage(fromUsed: 40) ?? -1, accuracy: 1e-9)
        XCTAssertEqual(remaining.displayPercentage, 60, accuracy: 1e-9)
        XCTAssertEqual(used.text, "경과 시간 40%")
        XCTAssertEqual(remaining.text, "남은 시간 60%")
        XCTAssertEqual(used.spokenText, "경과 시간 40퍼센트")
        XCTAssertEqual(remaining.spokenText, "남은 시간 60퍼센트")
    }

    func testMarkerTextNeverRoundsALiveWindowToItsEnds() throws {
        let almostOver = try XCTUnwrap(window(remaining: 30).flatMap { $0.marker(basis: .used, now: now) })
        XCTAssertEqual(almostOver.text, "경과 시간 99%")
        let justStarted = try XCTUnwrap(
            window(remaining: 18_000 - 30).flatMap { $0.marker(basis: .remaining, now: now) })
        XCTAssertEqual(justStarted.text, "남은 시간 99%")
    }

    func testDisabledSurfaceHasNoMarkerAndKeepsItsText() throws {
        let window = try XCTUnwrap(window(remaining: 3 * 3600))
        XCTAssertNil(window.visibleMarker(isEnabled: false, basis: .used, now: now))
        let marker = window.visibleMarker(isEnabled: true, basis: .used, now: now)
        XCTAssertEqual(marker.appending(toTooltip: "5시간 한도"), "5시간 한도\n경과 시간 40%")
        XCTAssertEqual(marker.appending(toAccessibilityValue: "40퍼센트 사용"), "40퍼센트 사용, 경과 시간 40퍼센트")
        let none: UsagePaceMarker? = nil
        XCTAssertEqual(none.appending(toTooltip: "5시간 한도"), "5시간 한도")
        XCTAssertEqual(none.appending(toAccessibilityValue: "40퍼센트 사용"), "40퍼센트 사용")
        XCTAssertFalse(EnvironmentValues().usagePaceMarkerVisible)
    }

    // MARK: - Provider window lengths

    func testClaudeRowsUseTheirFixedWindowLengths() throws {
        let (settings, cleanup) = try isolatedSettings()
        defer { cleanup() }
        let fiveHourReset = "2027-01-15T08:00:00Z"
        let weeklyReset = "2027-01-20T08:00:00Z"
        let usage = ClaudeUsageResponse(
            fiveHour: UsageWindow(utilization: 30, resetsAt: fiveHourReset),
            sevenDay: UsageWindow(utilization: 50, resetsAt: weeklyReset),
            sevenDaySonnet: UsageWindow(utilization: 10, resetsAt: weeklyReset),
            sevenDayOpus: nil)
        let context = UsageItemContext(
            density: .standard, settings: settings, claudeUsage: usage, claudeOverage: nil,
            codexUsage: nil, codexError: nil)
        let catalog = ClaudeItemCatalog()
        let paces = Dictionary(
            uniqueKeysWithValues: catalog.sections(from: catalog.defaultItems, context: context).compactMap {
                section -> (String, UsagePaceWindow?)? in
                guard case .usage(let data) = section.payload else { return nil }
                return (section.id, data.pace)
            })
        XCTAssertEqual(paces["currentSession"]??.lengthSeconds, 18_000)
        XCTAssertEqual(paces["currentSession"]??.resetAt, ISO8601DateFormatter().date(from: fiveHourReset))
        XCTAssertEqual(paces["weeklyLimit"]??.lengthSeconds, 604_800)
        let modelPaces = paces.filter { $0.key.hasPrefix("quota") }.values.compactMap { $0 }
        XCTAssertEqual(modelPaces.map(\.lengthSeconds), [604_800])
    }

    func testClaudeSessionThatHasNotStartedHasNoMarker() throws {
        let (settings, cleanup) = try isolatedSettings()
        defer { cleanup() }
        let usage = ClaudeUsageResponse(
            fiveHour: UsageWindow(utilization: 0, resetsAt: nil), sevenDay: nil, sevenDaySonnet: nil,
            sevenDayOpus: nil)
        let context = UsageItemContext(
            density: .standard, settings: settings, claudeUsage: usage, claudeOverage: nil,
            codexUsage: nil, codexError: nil)
        guard case .usage(let data) = ClaudeItemCatalog().section(for: "currentSession", context: context)?.payload
        else { return XCTFail("missing session row") }
        XCTAssertNil(data.pace)
    }

    func testCodexRowsUseOnlyTheReportedWindowLength() throws {
        let (settings, cleanup) = try isolatedSettings()
        defer { cleanup() }
        let usage = try JSONDecoder().decode(
            CodexUsageResponse.self,
            from: Data(
                """
                {
                  "rate_limit": {
                    "primary_window": { "used_percent": 4, "limit_window_seconds": 18000, "reset_at": 1800003600 },
                    "secondary_window": { "used_percent": 63, "reset_at": 1800300000 }
                  },
                  "additional_rate_limits": [
                    {
                      "metered_feature": "fixturemodel",
                      "rate_limit": {
                        "primary_window": { "used_percent": 7, "limit_window_seconds": 604800, "reset_at": 1800300000 }
                      }
                    }
                  ]
                }
                """.utf8))
        let context = UsageItemContext(
            density: .standard, settings: settings, claudeUsage: nil, claudeOverage: nil,
            codexUsage: usage, codexError: nil)
        let catalog = CodexItemCatalog()
        let sections = catalog.sections(from: catalog.defaultItems, context: context)
        func pace(_ id: String) -> UsagePaceWindow?? {
            sections.first { $0.id == id }.flatMap { section in
                guard case .usage(let data) = section.payload else { return nil }
                return .some(data.pace)
            }
        }
        XCTAssertEqual(pace("codexPrimary")??.lengthSeconds, 18_000)
        XCTAssertEqual(pace("codexPrimary")??.resetAt, Date(timeIntervalSince1970: 1_800_003_600))
        // The legacy secondary slot is still shown as weekly, but its length is not reported.
        XCTAssertNotNil(pace("codexSecondary"))
        XCTAssertNil(pace("codexSecondary")!)
        let model = try XCTUnwrap(sections.first { $0.id.contains("fixturemodel") })
        guard case .usage(let modelData) = model.payload else { return XCTFail("model row is not usage") }
        XCTAssertEqual(modelData.pace?.lengthSeconds, 604_800)
    }

    func testAntigravityLanesUseTheirCadenceAndCompactRowsShareIt() throws {
        let reset = now.addingTimeInterval(3600)
        func lane(_ id: String, _ cadence: AntigravityQuotaCadence) -> AntigravityQuotaLane {
            AntigravityQuotaLane(
                id: AntigravityQuotaLaneID(rawValue: id), upstreamGroupID: "group", upstreamBucketID: "bucket-\(id)",
                scope: .gemini, cadence: cadence, remainingFraction: 0.5, resetAt: reset, resetDescription: nil,
                availability: .available)
        }
        let snapshot = AntigravityQuotaSnapshot(
            identity: nil, plan: "test",
            lanes: [
                lane(AntigravityQuotaLaneID.geminiFiveHour.rawValue, .fiveHour),
                lane(AntigravityQuotaLaneID.geminiWeekly.rawValue, .weekly),
                lane("gemini-daily", .unknown(rawValue: "daily")),
            ],
            decodeIssues: [], provenance: AntigravityQuotaProvenance(transport: .cliUsageReport, accountIdentity: nil),
            fetchedAt: now)
        let presentation = AntigravityQuotaPresentationMapper.map(
            snapshot: snapshot, settings: .default, now: now)
        let lanes = Dictionary(
            uniqueKeysWithValues: presentation.allGroups.flatMap(\.lanes).map { ($0.id.rawValue, $0) })
        XCTAssertEqual(lanes[AntigravityQuotaLaneID.geminiFiveHour.rawValue]?.pace?.lengthSeconds, 18_000)
        XCTAssertEqual(lanes[AntigravityQuotaLaneID.geminiWeekly.rawValue]?.pace?.lengthSeconds, 604_800)
        XCTAssertEqual(lanes[AntigravityQuotaLaneID.geminiFiveHour.rawValue]?.pace?.resetAt, reset)
        XCTAssertNotNil(lanes["gemini-daily"])
        XCTAssertNil(lanes["gemini-daily"]?.pace)
        XCTAssertFalse(presentation.compact.metrics.isEmpty)
        for metric in presentation.compact.metrics {
            XCTAssertEqual(metric.pace, lanes[metric.laneID.rawValue]?.pace)
        }
    }

    // MARK: - Preference

    func testPreferenceDefaultsOnAndIsWrittenOnlyByTheUser() throws {
        let (settings, cleanup) = try isolatedSettings()
        defer { cleanup() }
        let defaults = try XCTUnwrap(settingsDefaults)
        XCTAssertTrue(settings.usagePaceMarkerVisible)
        XCTAssertNil(defaults.object(forKey: UsagePaceMarkerPreference.key))

        settings.setUsagePaceMarkerVisible(false)
        XCTAssertFalse(AppSettings(defaults: defaults).usagePaceMarkerVisible)

        let snapshot = settings.createSnapshot()
        settings.setUsagePaceMarkerVisible(true)
        settings.restore(from: snapshot)
        XCTAssertFalse(settings.usagePaceMarkerVisible)
        XCTAssertEqual(defaults.object(forKey: UsagePaceMarkerPreference.key) as? Bool, false)

        settings.resetToDefaults()
        XCTAssertTrue(settings.usagePaceMarkerVisible)
        XCTAssertNil(defaults.object(forKey: UsagePaceMarkerPreference.key))
    }

    func testSnapshotRestoresAnUnsetPreferenceAsUnset() throws {
        let (settings, cleanup) = try isolatedSettings()
        defer { cleanup() }
        let defaults = try XCTUnwrap(settingsDefaults)
        let snapshot = settings.createSnapshot()
        settings.setUsagePaceMarkerVisible(false)
        settings.restore(from: snapshot)
        XCTAssertTrue(settings.usagePaceMarkerVisible)
        XCTAssertNil(defaults.object(forKey: UsagePaceMarkerPreference.key))
    }

    func testUnreadablePreferenceShowsTheDefaultWithoutOverwritingIt() throws {
        let suite = "UsagePaceTests.unreadable.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for value: Any in ["off", 0, ["visible": false]] {
            defaults.set(value, forKey: UsagePaceMarkerPreference.key)
            let original = try XCTUnwrap(defaults.object(forKey: UsagePaceMarkerPreference.key) as? NSObject)
            let settings = AppSettings(defaults: defaults)
            XCTAssertTrue(settings.usagePaceMarkerVisible, "\(value)")
            XCTAssertEqual(defaults.object(forKey: UsagePaceMarkerPreference.key) as? NSObject, original)
        }
    }

    func testChangedPreferenceMarksAnExistingInstall() throws {
        let suite = "UsagePaceTests.install.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(AppExperiencePreferences.load(from: defaults, hasAccountStorage: false).isExistingInstall)
        defaults.removePersistentDomain(forName: suite)
        defaults.set(false, forKey: UsagePaceMarkerPreference.key)
        XCTAssertTrue(AppExperiencePreferences.load(from: defaults, hasAccountStorage: false).isExistingInstall)
    }

    // MARK: - Rendering

    func testMarkerOffsetUsesTheFillTransformAndSnapsToPixels() {
        let used = ProgressBarView.paceMarkerOffset(
            elapsedPercentage: 40, basis: .used, trackWidth: 200, markerWidth: 2.5, scale: 2)
        let remaining = ProgressBarView.paceMarkerOffset(
            elapsedPercentage: 40, basis: .remaining, trackWidth: 200, markerWidth: 2.5, scale: 2)
        XCTAssertEqual(used, 79)
        XCTAssertEqual(remaining, 118.5)
        XCTAssertEqual(
            ProgressBarView.paceMarkerOffset(
                elapsedPercentage: 100, basis: .used, trackWidth: 200, markerWidth: 2.5, scale: 2), 197.5)
        XCTAssertNil(
            ProgressBarView.paceMarkerOffset(
                elapsedPercentage: nil, basis: .used, trackWidth: 200, markerWidth: 2.5, scale: 2))
        XCTAssertNil(
            ProgressBarView.paceMarkerOffset(
                elapsedPercentage: 40, basis: .used, trackWidth: 2, markerWidth: 2.5, scale: 2))
        XCTAssertEqual(ProgressBarView.paceMarkerWidth(barHeight: PopoverLayoutMetrics.standardUsageRowBarHeight), 2.5)
        XCTAssertEqual(ProgressBarView.paceMarkerWidth(barHeight: PopoverLayoutMetrics.compactProgressBarHeight), 2)
    }

    func testRenderedMarkerSitsAtTheElapsedPositionOnBothBasesAndAppearances() throws {
        for scheme in [ColorScheme.light, .dark] {
            for (basis, centerX) in [(UsageValueBasis.used, 160), (.remaining, 239)] {
                let marked = try renderBar(basis: basis, elapsed: 40, scheme: scheme)
                let plain = try renderBar(basis: basis, elapsed: nil, scheme: scheme)
                // Above the 6pt bar only the marker's 2pt overhang can draw.
                let overhangY = 6
                XCTAssertGreaterThan(pixel(marked, x: centerX, y: overhangY)[3], 0, "\(basis) \(scheme)")
                XCTAssertEqual(pixel(marked, x: 40, y: overhangY)[3], 0, "\(basis) \(scheme)")
                XCTAssertEqual(pixel(plain, x: centerX, y: overhangY)[3], 0, "\(basis) \(scheme)")
            }
        }
    }

    func testMarkerIsDrawnOverTheFill() throws {
        for scheme in [ColorScheme.light, .dark] {
            let marked = try renderBar(basis: .used, elapsed: 40, scheme: scheme, percentage: 80)
            let plain = try renderBar(basis: .used, elapsed: nil, scheme: scheme, percentage: 80)
            let barMiddleY = 14
            XCTAssertNotEqual(pixel(marked, x: 160, y: barMiddleY), pixel(plain, x: 160, y: barMiddleY), "\(scheme)")
            XCTAssertEqual(pixel(marked, x: 60, y: barMiddleY), pixel(plain, x: 60, y: barMiddleY), "\(scheme)")
        }
    }

    func testRowsPlaceTheMarkerOnTheirOwnBasisOnlyWhenEnabled() throws {
        func center(_ band: ClosedRange<Int>) -> Double { Double(band.lowerBound + band.upperBound) / 2 }
        for compact in [false, true] {
            let label = compact ? "compact" : "standard"
            let usedPlain = try rowImage(compact: compact, basis: .used, elapsed: nil, visible: true)
            let remainingPlain = try rowImage(compact: compact, basis: .remaining, elapsed: nil, visible: true)
            let start = try XCTUnwrap(
                differingColumns(
                    try rowImage(compact: compact, basis: .used, elapsed: 0.0005, visible: true), usedPlain), label)
            let end = try XCTUnwrap(
                differingColumns(
                    try rowImage(compact: compact, basis: .used, elapsed: 0.9995, visible: true), usedPlain), label)
            let marked = try XCTUnwrap(
                differingColumns(
                    try rowImage(compact: compact, basis: .remaining, elapsed: 0.4, visible: true), remainingPlain),
                label)
            XCTAssertEqual(center(marked), center(start) + 0.6 * (center(end) - center(start)), accuracy: 2, label)
            XCTAssertLessThanOrEqual(marked.count, 10, label)
            let hidden = try rowImage(compact: compact, basis: .remaining, elapsed: 0.4, visible: false)
            XCTAssertNil(differingColumns(hidden, remainingPlain), label)
        }
    }

    func testPopoverRootPassesTheSettingToItsRows() throws {
        let (settings, cleanup) = try isolatedSettings()
        defer { cleanup() }
        settings.menuBarDesignIntroductionDismissed = true
        let now = Date()
        let reset = ISO8601DateFormatter().string(from: now.addingTimeInterval(3 * 3600))
        let claude = ClaudeUsageResponse(
            fiveHour: .init(utilization: 10, resetsAt: reset), sevenDay: nil, sevenDaySonnet: nil, sevenDayOpus: nil)
        let model = PopoverViewModel(updateRuntimeState: UpdateRuntimeState(settings: settings))
        model.update(snapshots: [
            .init(
                service: .claude, payload: .claude(claude), lastUpdated: now, credentialState: .usable,
                isDetected: true, canAttemptRefresh: true, hasAuthError: false)
        ])
        model.selectService(.claude)
        for compact in [false, true] {
            settings.popoverCompact = compact
            settings.setUsagePaceMarkerVisible(true)
            let shown = try renderHosted(PopoverView(viewModel: model, settings: settings))
            settings.setUsagePaceMarkerVisible(false)
            let hidden = try renderHosted(PopoverView(viewModel: model, settings: settings))
            XCTAssertEqual(shown.width, hidden.width)
            XCTAssertEqual(shown.height, hidden.height)
            let band = try XCTUnwrap(differingColumns(shown, hidden), "compact=\(compact)")
            XCTAssertLessThanOrEqual(band.count, 12, "compact=\(compact)")
        }
    }

    func testAntigravityQuotaIDsKeepTheirPersistedLengths() {
        func lane(_ id: String, _ cadence: AntigravityQuotaCadence) -> AntigravityQuotaLane {
            AntigravityQuotaLane(
                id: AntigravityQuotaLaneID(rawValue: id), upstreamGroupID: "group", upstreamBucketID: "bucket-\(id)",
                scope: .gemini, cadence: cadence, remainingFraction: 0.5, resetAt: nil, resetDescription: nil,
                availability: .available)
        }
        let snapshot = AntigravityQuotaSnapshot(
            identity: nil, plan: "test",
            lanes: [
                lane("fixturefive", .fiveHour), lane("fixtureweek", .weekly),
                lane("fixtureday", .unknown(rawValue: "daily")),
            ],
            decodeIssues: [], provenance: AntigravityQuotaProvenance(transport: .cliUsageReport, accountIdentity: nil),
            fetchedAt: now)
        XCTAssertEqual(
            UsageLimitCatalog.antigravity(snapshot).map(\.id),
            [
                "quota%2Dv1/antigravity/fixturefive/18000",
                "quota%2Dv1/antigravity/fixtureweek/604800",
                "quota%2Dv1/antigravity/fixtureday/unknown",
            ])
    }

    private func renderBar(
        basis: UsageValueBasis, elapsed: Double?, scheme: ColorScheme, percentage: Double = 30
    ) throws -> CGImage {
        let content = ProgressBarView(
            percentage: percentage, height: PopoverLayoutMetrics.standardUsageRowBarHeight, color: .green,
            basis: basis, elapsedPercentage: elapsed
        )
        .frame(width: 200)
        .padding(.vertical, 4)
        .environment(\.displayScale, 2)
        .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return try XCTUnwrap(renderer.cgImage)
    }

    private func rowImage(compact: Bool, basis: UsageValueBasis, elapsed: Double?, visible: Bool) throws -> CGImage {
        let length = UsageWindowLength.fiveHour
        let pace = elapsed.flatMap {
            UsagePaceWindow(resetAt: Date().addingTimeInterval(TimeInterval(length) * (1 - $0)), lengthSeconds: length)
        }
        let row =
            compact
            ? AnyView(
                CompactUsageRow(
                    label: "5시간", percentage: 0, showsResetDetail: false, color: .green, basis: basis, pace: pace
                )
                .frame(width: 296))
            : AnyView(
                StandardUsageRow(
                    title: "5시간 한도", percentage: 0, detailText: nil, color: .green, basis: basis, pace: pace
                )
                .frame(width: 312))
        let content =
            row
            .padding(4)
            .environment(\.usagePaceMarkerVisible, visible)
            .environment(\.displayScale, 2)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return try XCTUnwrap(renderer.cgImage)
    }

    private func renderHosted<V: View>(_ content: V) throws -> CGImage {
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = []
        let size = controller.sizeThatFits(in: CGSize(width: 2000, height: 2000))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = controller
        controller.view.frame = NSRect(origin: .zero, size: size)
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        controller.view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        window.close()
        return try XCTUnwrap(bitmap.cgImage)
    }

    private func rgba(_ image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return data
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        let index = (y * image.width + x) * 4
        return Array(rgba(image)[index..<index + 4])
    }

    private func differingColumns(_ lhs: CGImage, _ rhs: CGImage) -> ClosedRange<Int>? {
        guard lhs.width == rhs.width, lhs.height == rhs.height else { return 0...Int.max - 1 }
        let left = rgba(lhs)
        let right = rgba(rhs)
        var columns: ClosedRange<Int>?
        for y in 0..<lhs.height {
            for x in 0..<lhs.width {
                let index = (y * lhs.width + x) * 4
                guard left[index..<index + 4] != right[index..<index + 4] else { continue }
                columns = columns.map { min($0.lowerBound, x)...max($0.upperBound, x) } ?? x...x
            }
        }
        return columns
    }

    // MARK: - Helpers

    private var settingsDefaults: UserDefaults?
    private var settingsSuite: String?

    private func isolatedSettings() throws -> (AppSettings, () -> Void) {
        let suite = "UsagePaceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        settingsDefaults = defaults
        settingsSuite = suite
        return (AppSettings(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
    }
}
