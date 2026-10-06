import AppKit
import CoreFoundation
import ScreenCaptureKit
import SwiftUI
import XCTest

@testable import ClaudeUsage

@MainActor
final class DesignSystemTests: XCTestCase {
    func testDesignComparisonRendersAtNarrowWidths() throws {
        for width: CGFloat in [320, 520] {
            for scheme in [ColorScheme.light, .dark] {
                let view = MenuBarDesignComparison(colorMode: .monochrome, basis: .remaining)
                    .padding(AppDesign.Space.content).frame(width: width)
                    .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(scheme)
                let image = try renderHosted(view, appearance: scheme == .dark ? .darkAqua : .aqua)
                XCTAssertEqual(image.size.width, width, accuracy: 0.5)
                XCTAssertLessThan(image.size.height, 300)
                attach(image, "Five-style comparison \(width) \(scheme)")
            }
        }
    }

    func testDisplayBasisPreservesRiskAndRejectsUnknownValues() {
        XCTAssertEqual(UsageValueBasis.remaining.percentage(fromUsed: 8), 92)
        XCTAssertEqual(UsageValueBasis.used.percentage(fromUsed: 8), 8)
        XCTAssertNil(UsageValueBasis.remaining.percentage(fromUsed: .nan))
        XCTAssertEqual(UsageValueBasis.used.text(fromUsed: .infinity), "—")
        XCTAssertEqual(UsageValueBasis.remaining.spokenValue(fromUsed: 8), "92퍼센트 남음")
        XCTAssertEqual(ColorProvider.nsStatusColor(for: 8), .systemGreen)
    }

    func testCatalogAndMenuBarUseTheSameBasisWithoutMutatingPreferences() throws {
        try withSettings { settings in
            settings.setMenuBarStyle(.batteryBar, for: .claude)
            let context = UsageItemContext(
                density: .compact, settings: settings, claudeUsage: usage,
                claudeOverage: nil, claudeAccounts: [], activeClaudeAccountID: nil,
                codexUsage: nil, codexError: nil
            )
            let section = try XCTUnwrap(ClaudeItemCatalog().section(for: "currentSession", context: context))
            guard case .usage(let row) = section.payload else { return XCTFail("Missing quota row") }
            XCTAssertEqual(row.basis, .remaining)
            XCTAssertEqual(row.basis.text(fromUsed: row.percentage), "92%")
            let snapshot = MenuBarStatusComposer.claudeSnapshot(
                config: try XCTUnwrap(settings.menuBarDisplayConfig(for: .claude)), usage: usage,
                error: nil, hasAuthError: false, hasCredential: true,
                secondaryColor: .secondaryLabelColor, icon: nil, renderImages: false
            )
            XCTAssertTrue(snapshot.regularText?.contains("92%") == true)
            XCTAssertTrue(snapshot.tooltip.contains("남음"))
            XCTAssertEqual(settings.circularDisplayMode, .remaining)
        }
    }

    func testEmptySelectionUsesTheActualInteractivePanelHeight() throws {
        try withSettings { settings in
            settings.popoverCompact = true
            settings.setPopoverItems(
                ClaudeItemCatalog().defaultItems.map { .init(id: $0.id, visible: false) }, for: .claude)
            let model = makeModel(settings: settings)
            let layout = model.layoutWithSections(for: .claude, settings: settings)
            XCTAssertTrue(layout.sections.isEmpty)
            let panel = StatusPanelView(
                density: .compact, icon: "slider.horizontal.3", iconColor: .secondary,
                showsProgress: false, title: "표시할 항목 없음", message: "표시 편집에서 최소 한 항목을 선택해 주세요.",
                actionTitle: "표시 편집", actionStyle: .bordered, action: {}
            ).frame(width: 276)
            let image = try render(panel)
            XCTAssertGreaterThanOrEqual(layout.spec.bodyContentHeight, image.size.height)
            XCTAssertEqual(layout.spec.bodyContentHeight, PopoverLayoutMetrics.compactInteractiveStatusPanelHeight)
        }
    }

    func testMissingWeeklyWindowIsNotDisplayedAsUnusedQuotaOrAnUnstableRenderKey() throws {
        try withSettings { settings in
            settings.setMenuBarStyle(.concentricRings, for: .claude)
            let config = try XCTUnwrap(settings.menuBarDisplayConfig(for: .claude))
            let usage = ClaudeUsageResponse(fiveHour: .init(utilization: 8, resetsAt: nil), sevenDay: nil)
            @MainActor func snapshot() -> MenuBarProviderSnapshot {
                MenuBarStatusComposer.claudeSnapshot(
                    config: config, usage: usage, error: nil, hasAuthError: false, hasCredential: true,
                    secondaryColor: .secondaryLabelColor, icon: nil)
            }
            let first = snapshot()
            XCTAssertFalse(first.tooltip.contains("주간"))
            XCTAssertFalse(first.tooltip.contains("100%"))
            XCTAssertEqual(first.renderKey, snapshot().renderKey)
            XCTAssertNotNil(first.styleIcon?.tiffRepresentation)
        }
    }

    func testTwoLineCompactStatusMessageFitsWithItsAction() throws {
        let panel = StatusPanelView(
            density: .compact, icon: "exclamationmark.triangle", iconColor: .orange, showsProgress: false,
            title: "사용량 갱신 실패", message: "네트워크 연결을 확인한 뒤\n다시 시도해 주세요.",
            actionTitle: "다시 시도", actionStyle: .bordered, action: {}
        ).frame(width: 276)
        let image = try renderHosted(panel, appearance: .darkAqua)
        XCTAssertEqual(image.size.height, PopoverLayoutMetrics.compactInteractiveStatusPanelHeight, accuracy: 0.5)
        attach(image, "Two-line compact failure and retry")
    }

    func testLiveCatalogRowStackMatchesItsViewportBudget() throws {
        try withSettings { settings in
            let model = makeModel(settings: settings)
            let sections = model.displaySections(for: .claude, density: .compact, settings: settings)
            XCTAssertEqual(sections.count, 3)
            let image = try render(PopoverCatalogSectionList(sections: sections, density: .compact).frame(width: 276))
            XCTAssertEqual(
                image.size.height, PopoverLayoutMetrics.compactContentBodyHeight(rowCount: sections.count),
                accuracy: 0.5)
        }
    }

    func testBatteryAppearanceComesFromStatusItemRatherThanApplication() throws {
        let app = NSApplication.shared
        let previous = app.appearance
        defer { app.appearance = previous }
        app.appearance = NSAppearance(named: .darkAqua)
        var light: NSImage?
        var dark: NSImage?
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            light = MenuBarIconRenderer.batteryIcon(percentage: 40, color: .systemYellow)
        }
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            dark = MenuBarIconRenderer.batteryIcon(percentage: 40, color: .systemYellow)
        }
        XCTAssertNotEqual(try XCTUnwrap(light?.tiffRepresentation), try XCTUnwrap(dark?.tiffRepresentation))
        XCTAssertEqual(light?.size, BatteryGeometry.Layout.single.size)
    }

    func testPopoverAndLoginRenderGallery() throws {
        try withSettings { settings in
            settings.setMenuBarStyle(.batteryBar, for: .claude)
            settings.setProviderEnabled(true, for: .codex)
            settings.setProviderEnabled(true, for: .antigravity)
            let model = makeModel(settings: settings)
            for compact in [true, false] {
                settings.popoverCompact = compact
                for scheme in [ColorScheme.light, .dark] {
                    let content = PopoverView(viewModel: model, settings: settings)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .preferredColorScheme(scheme)
                    let image = try renderHosted(content, appearance: scheme == .dark ? .darkAqua : .aqua)
                    XCTAssertEqual(image.size, model.layoutSpec(for: .claude, settings: settings).size)
                    attach(image, "Popover content \(compact ? "compact" : "standard") \(scheme)")
                }
            }
        }
        for scheme in [ColorScheme.light, .dark] {
            let selectorAndValues = VStack(alignment: .leading, spacing: AppDesign.Space.row) {
                HStack(spacing: AppDesign.Space.heading) {
                    ForEach([AppProviderKind.claude, .codex, .antigravity], id: \.self) { provider in
                        ProviderSelectorButtonLabel(
                            provider: provider, isSelected: provider == .codex,
                            showsWarning: false, compact: true)
                    }
                }
                CompactUsageRow(label: "주간", percentage: 69, showsResetDetail: false, basis: .remaining)
                CompactUsageRow(label: "현재", percentage: 100, showsResetDetail: false, basis: .used)
                CompactUsageRow(
                    label: "정밀 수치", percentage: 0.25, showsResetDetail: false,
                    percentageText: "99.75%", basis: .remaining)
            }
            .padding(AppDesign.Space.content).frame(width: PopoverLayoutMetrics.compactPopoverWidth)
            .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(scheme)
            attach(
                try renderHosted(selectorAndValues, appearance: scheme == .dark ? .darkAqua : .aqua),
                "Codex selected and inline percentage basis \(scheme)")
        }
        let login = LoginWindowView(
            onSessionKeyFound: { _, _, _, _ in },
            onActivateCLI: { .init(title: "Fixture", methodLabel: "Fixture") },
            onLoadCLIPreview: { nil }, onOpenAdvancedSettings: {}, onCancel: {}
        ).background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark)
        let image = try renderHosted(login, appearance: .darkAqua)
        XCTAssertEqual(image.size, CGSize(width: 720, height: 600))
        attach(image, "Login method selection")
        let settingsCards = VStack(alignment: .leading, spacing: AppDesign.Space.section) {
            ClaudeOAuthMigrationCard(state: .available, onMigrate: {}, onDefer: {}, onReconnectClaudeCode: {})
            SettingsDisclosureControl(isExpanded: .constant(true), accessibilityLabel: "고급 진단") {
                Text("고급 진단")
            } content: {
                Text("이전 값 · 5분 전").font(AppDesign.Typography.caption)
            }
        }.padding(AppDesign.Space.window).frame(width: 520)
            .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark)
        attach(try renderHosted(settingsCards, appearance: .darkAqua), "Shared settings and authentication panels")
    }

    func testBatteryGalleryCoversBoundaryValuesAndBothAppearances() throws {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            var images: [NSImage] = []
            appearance.performAsCurrentDrawingAppearance {
                for value in [0.0, 1, 8, 40, 75, 90, 99, 100] {
                    images.append(
                        MenuBarIconRenderer.batteryIcon(
                            percentage: value, color: ColorProvider.nsStatusColor(for: 100 - value)))
                }
                images.append(
                    MenuBarIconRenderer.dualBatteryIcon(
                        topPercent: 92, bottomPercent: 63, topColor: .systemGreen, bottomColor: .systemGreen))
                images.append(
                    MenuBarIconRenderer.sideBySideBatteryIcon(
                        leftPercent: 40, rightPercent: 92, leftColor: .systemYellow, rightColor: .systemGreen))
            }
            let gallery = HStack(spacing: AppDesign.Space.row) {
                ForEach(images.indices, id: \.self) { index in Image(nsImage: images[index]) }
            }.padding(AppDesign.Space.content)
                .background(appearanceName == .aqua ? Color.white : Color.black)
            attach(try render(gallery), "Battery values \(appearanceName.rawValue)")
        }
    }

    func testAllGaugeVariantsShareAppearanceAndPreserveTheirValueEncoding() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            for colorMode in MenuBarColorMode.allCases {
                var images: [NSImage] = []
                appearance.performAsCurrentDrawingAppearance {
                    let color: NSColor = colorMode == .always ? .systemGreen : .labelColor
                    let warningColor: NSColor = colorMode == .monochrome ? .labelColor : .systemOrange
                    images = [
                        MenuBarIconRenderer.batteryIcon(percentage: 92, color: color),
                        MenuBarIconRenderer.circularRingIcon(percentage: 92, color: color),
                        MenuBarIconRenderer.concentricRingsIcon(
                            outerPercent: 92, innerPercent: 20, outerColor: color, innerColor: warningColor),
                        MenuBarIconRenderer.dualBatteryIcon(
                            topPercent: 92, bottomPercent: 20, topColor: color, bottomColor: warningColor),
                        MenuBarIconRenderer.sideBySideBatteryIcon(
                            leftPercent: 92, rightPercent: 20, leftColor: color, rightColor: warningColor),
                    ]
                }
                XCTAssertEqual(images[1].size, images[2].size)
                XCTAssertEqual(images[1].size, RingGeometry.size)
                let gallery = HStack(spacing: AppDesign.Space.section) {
                    ForEach(images.indices, id: \.self) { index in Image(nsImage: images[index]) }
                }.padding(AppDesign.Space.content)
                    .background(name == .aqua ? Color.white : Color.black)
                attach(try render(gallery), "All gauge shapes \(colorMode.rawValue) \(name.rawValue)")
            }
        }
        let empty = MenuBarIconRenderer.circularRingIcon(percentage: 0, color: .systemGreen)
        let full = MenuBarIconRenderer.circularRingIcon(percentage: 100, color: .systemGreen)
        XCTAssertNotEqual(empty.tiffRepresentation, full.tiffRepresentation)
    }

    func testSupplementaryUsageGalleryPreservesGeometryAndSelections() throws {
        try withSettings { settings in
            settings.separateCompactConfig = false
            settings.menuBarDesignIntroductionDismissed = true
            settings.setProviderEnabled(true, for: .codex)
            let storedClaude = settings.popoverItems(for: .claude)
            let storedCodex = settings.popoverItems(for: .codex)
            let now = Date()
            let formatter = ISO8601DateFormatter()
            let sessionReset = formatter.string(from: now.addingTimeInterval(2 * 3600))
            let weeklyReset = formatter.string(from: now.addingTimeInterval(3 * 86400))
            let overage = OverageSpendLimitResponse(
                monthlyCreditLimitCents: 5000, usedCreditsCents: 1200,
                isEnabled: true, outOfCredits: false, currency: "USD")

            for stale in [false, true] {
                let grant = ClaudeResetGrants.Grant(
                    id: "supplementary-gallery-reset",
                    label: "Fixture server reset title",
                    resetsLeft: 1, startsAt: nil,
                    endsAt: now.addingTimeInterval(stale ? 12 * 3600 : 22 * 86400),
                    clears: ["five_hour", "seven_day"], paused: false)
                let claude = ClaudeUsageResponse(
                    fiveHour: .init(utilization: 8, resetsAt: sessionReset),
                    sevenDay: .init(utilization: 37, resetsAt: weeklyReset),
                    sevenDaySonnet: .init(utilization: 30, resetsAt: weeklyReset),
                    resetGrants: .init(eligible: true, atLimit: false, grants: [grant]))
                var codex = try JSONDecoder().decode(
                    CodexUsageResponse.self,
                    from: Data(
                        """
                        {"plan_type":"pro","rate_limit":{"primary_window":{
                          "used_percent":24,"limit_window_seconds":604800,"reset_after_seconds":259200}},
                          "credits":{"has_credits":true,"unlimited":false,"balance":"62500"}}
                        """.utf8))
                codex.resetCredits = .init(credits: [], availableCountField: 0)
                let model = PopoverViewModel(updateRuntimeState: UpdateRuntimeState(settings: settings))
                model.update(snapshots: [
                    .init(
                        service: .claude, payload: .claude(claude),
                        error: stale ? .networkError("fixture") : nil,
                        lastUpdated: now, credentialState: .usable,
                        isDetected: true, canAttemptRefresh: true, hasAuthError: false,
                        lastAttemptState: stale ? .temporaryFailure : .idle,
                        claudeOverage: overage, claudeOverageUpdatedAt: now, claudeOverageIsStale: stale),
                    .init(
                        service: .codex, payload: .codex(codex), lastUpdated: now,
                        credentialState: .usable, isDetected: true,
                        canAttemptRefresh: true, hasAuthError: false),
                ])

                for service in stale ? [PopoverService.claude] : [.claude, .codex] {
                    model.selectService(service)
                    for compact in [false, true] {
                        settings.popoverCompact = compact
                        let layout = model.layoutWithSections(for: service, settings: settings)
                        XCTAssertEqual(layout.sections.count, service == .claude ? 5 : 2)
                        if service == .codex {
                            XCTAssertFalse(layout.sections.contains { $0.kind == .resetCredits })
                        }
                        if compact && service == .claude {
                            XCTAssertEqual(
                                layout.spec.bodyContentHeight,
                                PopoverLayoutMetrics.compactContentBodyHeight(rowCount: 5))
                        }
                        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                            let scheme: ColorScheme = appearance == .aqua ? .light : .dark
                            let image = try renderHosted(
                                PopoverView(viewModel: model, settings: settings)
                                    .background(Color(nsColor: .windowBackgroundColor))
                                    .preferredColorScheme(scheme),
                                appearance: appearance)
                            XCTAssertEqual(image.size.width, layout.spec.size.width, accuracy: 0.5)
                            XCTAssertEqual(image.size.height, layout.spec.size.height, accuracy: 0.5)
                            attach(
                                image,
                                "Supplementary-\(service.rawValue)-\(compact ? "compact" : "standard")-\(appearance.rawValue)-\(stale ? "stale-expiring" : "fresh")"
                            )
                        }
                    }
                }
            }
            XCTAssertEqual(settings.popoverItems(for: .claude), storedClaude)
            XCTAssertEqual(settings.popoverItems(for: .codex), storedCodex)
        }
    }

    func testResetCreditStateGalleryKeepsFixedRowHeights() throws {
        let now = Date()
        let states: [(String, Int, ResetCreditSummary.Scope, TimeInterval?, Bool, Bool)] = [
            ("normal", 1, .all, 22 * 86400, false, false),
            ("new", 1, .all, 22 * 86400, true, false),
            ("expiring", 2, .fiveHourOnly, 12 * 3600, true, false),
            ("zero", 0, .all, nil, false, false),
            ("unknown-expiry", 1, .fiveHourOnly, nil, false, false),
            ("at-limit", 1, .all, 22 * 86400, false, true),
            ("long-expiry", 1, .all, 22 * 86400 + 23 * 3600, false, false),
        ]
        let sections = states.map { name, count, scope, remaining, isNew, atLimit in
            PopoverDisplaySection(
                id: name, kind: .resetCredits, importance: .primary,
                payload: .resetCredits(
                    .init(
                        summary: .init(
                            items: count > 0
                                ? [
                                    .init(
                                        id: name, serverTitle: "Fixture server title for \(name)",
                                        scope: scope, expiresAt: remaining.map { now.addingTimeInterval($0) })
                                ] : [],
                            availableCount: count, atLimit: atLimit),
                        isNew: isNew)))
        }
        let quotaSection = PopoverDisplaySection(
            id: "reference-quota", kind: .usage, importance: .primary,
            payload: .usage(
                .init(
                    title: "5시간 한도", compactLabel: "5시간", percentage: 42,
                    resetAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(2 * 3600)),
                    isWeekly: false, timeFormatStyle: .remaining, basis: .remaining)))
        let credits = try JSONDecoder().decode(
            CodexCredits.self,
            from: Data(
                """
                {"has_credits":true,"unlimited":false,"balance":"62500"}
                """.utf8))
        let creditSection = PopoverDisplaySection(
            id: "reference-credits", kind: .credits, importance: .primary,
            payload: .credits(.init(credits: credits)))
        let gallerySections = [quotaSection] + sections + [creditSection]
        for density in [PopoverDensity.standard, .compact] {
            let width: CGFloat = density.isCompact ? 276 : 336
            let rowHeight =
                density.isCompact
                ? PopoverLayoutMetrics.compactCreditsRowHeight : PopoverLayoutMetrics.standardSecondaryUsageRowHeight
            for section in sections {
                let row = try renderHosted(
                    PopoverDisplaySectionView(section: section, density: density).frame(width: width),
                    appearance: .aqua)
                XCTAssertEqual(row.size.height, rowHeight, accuracy: 0.5, section.id)
            }
            let creditRow = try renderHosted(
                PopoverDisplaySectionView(section: creditSection, density: density).frame(width: width),
                appearance: .aqua)
            XCTAssertEqual(
                creditRow.size.height,
                density.isCompact
                    ? PopoverLayoutMetrics.compactCreditsRowHeight : PopoverLayoutMetrics.standardCreditsRowHeight,
                accuracy: 0.5)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let scheme: ColorScheme = appearance == .aqua ? .light : .dark
                let content = VStack(spacing: AppDesign.Space.control) {
                    ForEach(gallerySections) { section in
                        PopoverDisplaySectionView(section: section, density: density)
                    }
                }
                .frame(width: width)
                .padding(AppDesign.Space.content)
                .background(Color(nsColor: .windowBackgroundColor))
                .preferredColorScheme(scheme)
                let image = try renderHosted(content, appearance: appearance)
                attach(
                    image, "Reset-credit-states-\(density.isCompact ? "compact" : "standard")-\(appearance.rawValue)")
            }
        }
    }

    func testMetricRowKeepsTrackAndValueGeometryAcrossDigitAndDetailChanges() throws {
        for density in [PopoverDensity.standard, .compact] {
            let width: CGFloat = density.isCompact ? 276 : 336
            var reference: (track: CGRect, value: CGRect, baseline: CGFloat)?
            for amount in [0.0, 9, 10, 100] {
                let measured = PopoverRowGeometryRecorder()
                let row = PopoverMetricRow(density: density) {
                    Text("주간 한도")
                        .font(density.isCompact ? AppDesign.Typography.caption : AppDesign.Typography.subheadline)
                } middle: {
                    ProgressBarView(percentage: amount, color: .green)
                        .background(popoverRowFrameProbe("track"))
                } value: {
                    PopoverValueBaselineProbe(recorder: measured) {
                        UsagePercentageLabel(
                            percentage: amount, basis: .used, compact: density.isCompact, color: .green)
                    }
                    .background(popoverRowFrameProbe("value"))
                } detail: {
                    if amount != 0 {
                        Text("2h 34m")
                            .font(density.isCompact ? AppDesign.Typography.metadata : AppDesign.Typography.caption)
                    }
                }
                .frame(width: width)
                .coordinateSpace(name: "popover-row-geometry")
                .onPreferenceChange(PopoverRowFramesPreferenceKey.self) { measured.recordFrames($0) }
                let image = try renderHosted(row, appearance: .darkAqua)
                XCTAssertEqual(image.size.height, density.isCompact ? 18 : 36, accuracy: 0.5)
                let observed = measured.snapshot()
                let track = try XCTUnwrap(observed.frames["track"])
                let value = try XCTUnwrap(observed.frames["value"])
                let baseline = value.minY + (try XCTUnwrap(observed.baseline))
                XCTAssertGreaterThan(track.width, 0)
                XCTAssertGreaterThan(value.width, 0)
                if let reference {
                    XCTAssertEqual(track.minX, reference.track.minX, accuracy: 0.5)
                    XCTAssertEqual(track.maxX, reference.track.maxX, accuracy: 0.5)
                    XCTAssertEqual(value.maxX, reference.value.maxX, accuracy: 0.5)
                    XCTAssertEqual(baseline, reference.baseline, accuracy: 0.5)
                } else {
                    reference = (track, value, baseline)
                }
            }
            let measured = PopoverRowGeometryRecorder()
            let longValue = PopoverMetricRow(density: density, valueSpansMiddle: true) {
                Text("크레딧 잔액")
            } middle: {
                EmptyView()
            } value: {
                PopoverValueBaselineProbe(recorder: measured) {
                    PopoverMetricValue(text: "99999.99", compact: density.isCompact)
                }
                .background(popoverRowFrameProbe("value"))
            } detail: {
                EmptyView()
            }
            .frame(width: width)
            .coordinateSpace(name: "popover-row-geometry")
            .onPreferenceChange(PopoverRowFramesPreferenceKey.self) { measured.recordFrames($0) }
            _ = try renderHosted(longValue, appearance: .darkAqua)
            let observed = measured.snapshot()
            let value = try XCTUnwrap(observed.frames["value"])
            let baseline = value.minY + (try XCTUnwrap(observed.baseline))
            let expected = try XCTUnwrap(reference)
            XCTAssertEqual(value.maxX, expected.value.maxX, accuracy: 0.5)
            XCTAssertEqual(baseline, expected.baseline, accuracy: 0.5)
        }
    }

    func testActualPopoverRowBoundaryVisualGalleryPreservesHeights() async throws {
        let now = Date()
        let reset = now.addingTimeInterval(2 * 3600 + 34 * 60)
        let resetString = ISO8601DateFormatter().string(from: reset)
        var sections = [0.0, 9, 10, 100].map { remaining in
            PopoverDisplaySection(
                id: "remaining-\(Int(remaining))", kind: .usage, importance: .primary,
                payload: .usage(
                    .init(
                        title: "주간 한도", compactLabel: "주간", percentage: 100 - remaining,
                        resetAt: resetString, isWeekly: true, timeFormatStyle: .remaining, basis: .remaining)))
        }
        let creditFixtures: [(id: String, response: String)] = [
            ("credits-zero", #"{"has_credits":true,"unlimited":false,"balance":"0"}"#),
            ("credits-62500-73", #"{"has_credits":true,"unlimited":false,"balance":"62500.73"}"#),
            ("credits-99999-99", #"{"has_credits":true,"unlimited":false,"balance":"99999.99"}"#),
            ("credits-unlimited", #"{"has_credits":true,"unlimited":true,"balance":null}"#),
            ("credits-unreported", #"{"has_credits":false,"unlimited":false,"balance":null}"#),
        ]
        let decoder = JSONDecoder()
        for fixture in creditFixtures {
            let credits = try decoder.decode(CodexCredits.self, from: Data(fixture.response.utf8))
            sections.append(
                .init(
                    id: fixture.id, kind: .credits, importance: .primary,
                    payload: .credits(.init(credits: credits))))
        }
        for count in [1, 100] {
            sections.append(
                .init(
                    id: "reset-\(count)", kind: .resetCredits, importance: .primary,
                    payload: .resetCredits(
                        .init(
                            summary: .init(
                                items: [
                                    .init(
                                        id: "fixture-reset", serverTitle: nil, scope: .all,
                                        expiresAt: now.addingTimeInterval(17 * 86400 + 3 * 3600))
                                ],
                                availableCount: count, atLimit: false), isNew: false))))
        }
        for limit in [Double?(2000), nil] {
            sections.append(
                .init(
                    id: limit == nil ? "unlimited-overage" : "finite-overage", kind: .overage, importance: .primary,
                    payload: .overage(
                        .init(
                            overage: .init(
                                monthlyCreditLimitCents: limit, usedCreditsCents: limit == nil ? 999999999 : 1120,
                                isEnabled: true, outOfCredits: false, currency: "USD")))))
        }
        let laneSpecifications: [(AntigravityQuotaLaneID, AntigravityQuotaScope, AntigravityQuotaCadence, Double)] = [
            (.geminiFiveHour, .gemini, .fiveHour, 0),
            (.geminiWeekly, .gemini, .weekly, 9),
            (.thirdPartyFiveHour, .thirdPartyModels, .fiveHour, 10),
            (.thirdPartyWeekly, .thirdPartyModels, .weekly, 100),
        ]
        let quota = AntigravityQuotaSnapshot(
            identity: nil, plan: nil,
            lanes: laneSpecifications.map { id, scope, cadence, remaining in
                .init(
                    id: id, upstreamGroupID: nil, upstreamBucketID: id.rawValue, scope: scope, cadence: cadence,
                    remainingFraction: remaining / 100, resetAt: reset, resetDescription: nil, availability: .available)
            }, decodeIssues: [],
            provenance: .init(
                transport: .cliUsageReport, endpointOwner: .managed, accountIdentity: nil,
                capability: .groupedQuotaSummary, processIdentity: nil), fetchedAt: now)
        let agy = AntigravityQuotaPresentationMapper.map(
            snapshot: quota, settings: .default, basisOverride: .remaining, now: now)
        for density in [PopoverDensity.standard, .compact] {
            let contentWidth: CGFloat = density.isCompact ? 276 : 336
            for section in sections {
                let row = try renderHosted(
                    PopoverDisplaySectionView(section: section, density: density).frame(width: contentWidth),
                    appearance: .darkAqua)
                let expectedHeight: CGFloat =
                    density.isCompact ? 18 : section.kind == .usage ? 36 : section.kind == .credits ? 42 : 38
                XCTAssertEqual(row.size.height, expectedHeight, accuracy: 0.5, section.id)
            }
            let gallery = VStack(alignment: .leading, spacing: AppDesign.Space.row) {
                ForEach(sections) { section in
                    PopoverDisplaySectionView(section: section, density: density)
                }
                Divider()
                if density.isCompact {
                    AntigravityCompactQuotaView(presentation: agy.compact)
                } else {
                    AntigravityQuotaGroupsView(groups: agy.groups)
                }
            }
            .frame(width: contentWidth)
            .padding(
                density.isCompact ? PopoverLayoutMetrics.compactBodyInsets : PopoverLayoutMetrics.standardBodyInsets
            )
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(.dark)
            let controller = NSHostingController(rootView: gallery)
            controller.sizingOptions = []
            let size = controller.sizeThatFits(in: CGSize(width: density.isCompact ? 296 : 368, height: 2000))
            // Native host/capture success and row heights are automated. The actual
            // provider assemblies, numeric/caption baselines and track edges are
            // visually reviewed from these two unmodified original images.
            attach(
                try await renderSettingsNativeVerified(gallery, size: size, appearance: .darkAqua),
                "Popover-row-boundaries-\(density.isCompact ? "compact" : "standard")")
        }
    }

    private var usage: ClaudeUsageResponse {
        .init(
            fiveHour: .init(utilization: 8, resetsAt: "2026-10-01T12:00:00Z"),
            sevenDay: .init(utilization: 37, resetsAt: "2026-10-06T12:00:00Z"),
            sevenDaySonnet: .init(utilization: 30, resetsAt: "2026-10-06T12:00:00Z"))
    }

    private func makeModel(settings: AppSettings) -> PopoverViewModel {
        let model = PopoverViewModel(updateRuntimeState: UpdateRuntimeState(settings: settings))
        model.update(snapshots: [
            .init(
                service: .claude, payload: .claude(usage),
                lastUpdated: Date(), credentialState: .usable, isDetected: true,
                canAttemptRefresh: true, hasAuthError: false)
        ])
        return model
    }

    private func withSettings(_ body: (AppSettings) throws -> Void) throws {
        let suite = "DesignSystemTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.setProviderEnabled(true, for: .claude)
        try body(settings)
    }

    func testClassicAndModernDesignChoicesAndWelcomeGallery() throws {
        let suite = "DesignSystemTests.welcome.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.menuBarColorMode = .monochrome
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let picker = MenuBarDesignPicker(settings: settings).padding(20).frame(width: 420)
                .background(Color(nsColor: .windowBackgroundColor))
            attach(try renderHosted(picker, appearance: appearance), "Menu bar design choices \(appearance.rawValue)")
        }
        settings.motion.mode = .custom
        settings.motion.enabledCategories = [.popoverResize, .disclosure]
        attach(
            try renderHosted(
                AppMotionSettingsView(settings: settings).padding(20).frame(width: 420)
                    .background(Color(nsColor: .windowBackgroundColor)), appearance: .aqua), "Custom motion settings")
        for step in [WelcomeStep.services, .appearance] {
            settings.welcomeStep = step
            let view = WelcomeView(
                settings: settings, selectedProvider: .constant(.claude),
                statuses: [.claude: .verified],
                rows: [
                    OnboardingServiceRow(
                        provider: .claude, status: "연결됨", tone: .connected, detail: "work@example.com"),
                    OnboardingServiceRow(
                        provider: .codex, status: "찾지 못함", tone: .missing, primary: .init(title: "추가") {}),
                    OnboardingServiceRow(
                        provider: .antigravity, status: "AGY CLI 있음", tone: .ready, primary: .init(title: "연결") {}),
                ],
                display: Text("표시 항목 fixture"), onDefer: {}, onFinish: {}
            )
            .padding(24).frame(width: 520).background(Color(nsColor: .windowBackgroundColor))
            attach(try renderHosted(view, appearance: .aqua), "Welcome step \(step.rawValue)")
        }
        let classic = MenuBarIconRenderer.batteryIcon(percentage: 80, color: .systemGreen, design: .classic)
        XCTAssertEqual(classic.size, NSSize(width: 40, height: 14))
        let classicPair = MenuBarIconRenderer.sideBySideBatteryIcon(
            leftPercent: 80, rightPercent: 50,
            leftColor: .systemGreen, rightColor: .systemYellow, design: .classic)
        XCTAssertEqual(classicPair.size, NSSize(width: 83, height: 14))
        XCTAssertEqual(
            MenuBarIconRenderer.concentricRingsIcon(
                outerPercent: 80, innerPercent: 50,
                outerColor: .systemGreen, innerColor: .systemGreen, design: .classic
            ).size, NSSize(width: 22, height: 22))
    }

    func testModernMonochromeCutsOutGlyphsWithoutRemovingColoredText() throws {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            var counts: [Int] = []
            for monochrome in [false, true] {
                var rendered: NSImage?
                appearance.performAsCurrentDrawingAppearance {
                    rendered = MenuBarIconRenderer.batteryIcon(
                        percentage: 100, color: .labelColor, monochrome: monochrome)
                }
                let image = try XCTUnwrap(rendered)
                let rep = try XCTUnwrap(
                    NSBitmapImageRep(
                        bitmapDataPlanes: nil, pixelsWide: 56, pixelsHigh: 26, bitsPerSample: 8,
                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                        bytesPerRow: 0, bitsPerPixel: 0))
                rep.size = image.size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                image.draw(in: NSRect(origin: .zero, size: image.size))
                NSGraphicsContext.restoreGraphicsState()
                var transparent = 0
                for y in 5..<21 {
                    for x in 9..<42 where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 1) < 0.2 {
                        transparent += 1
                    }
                }
                counts.append(transparent)
            }
            XCTAssertEqual(counts[0], 0)
            if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            {
                XCTAssertEqual(counts[1], 0)
            } else {
                XCTAssertGreaterThan(counts[1], 20)
            }
        }
    }

    func testModernBatteryBoundaryUsesOneGlyphCompositionAcrossFillEdge() throws {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            guard !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
                !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            else {
                continue
            }

            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            var image: NSImage?
            appearance.performAsCurrentDrawingAppearance {
                image = MenuBarIconRenderer.batteryIcon(
                    percentage: 62,
                    color: .labelColor,
                    monochrome: true
                )
            }

            let rendered = try XCTUnwrap(image)
            let width = 56
            let height = 26
            let rep = try XCTUnwrap(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: width,
                    pixelsHigh: height,
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0,
                    bitsPerPixel: 0
                )
            )
            rep.size = rendered.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            rendered.draw(in: NSRect(origin: .zero, size: rendered.size))
            NSGraphicsContext.restoreGraphicsState()

            let scale = CGFloat(width) / rendered.size.width
            let boundary = Int((BatteryGeometry.bodyWidth * 0.62 * scale).rounded())
            let safeBodyEnd = Int((BatteryGeometry.bodyWidth * scale).rounded()) - 4
            let yRange = 8..<18

            func cutoutCount(_ xRange: Range<Int>) -> Int {
                var count = 0
                for y in yRange {
                    for x in xRange
                    where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 1) < 0.05 {
                        count += 1
                    }
                }
                return count
            }

            let leftStart = max(4, boundary - 8)
            let rightEnd = min(safeBodyEnd, boundary + 8)
            XCTAssertGreaterThan(
                cutoutCount(leftStart..<boundary),
                0,
                "the whole monochrome glyph must be cut out on the filled side"
            )
            XCTAssertGreaterThan(
                cutoutCount(boundary..<rightEnd),
                0,
                "the same cutout glyph must continue across the 62% fill boundary"
            )
        }
    }

    func testDefaultMotionAndNotificationEditorsStayCompactAtSettingsWidths() throws {
        try withSettings { settings in
            var heights: [AppMotionMode: CGFloat] = [:]
            for mode in AppMotionMode.allCases {
                settings.motion.mode = mode
                let image = try renderHosted(
                    AppMotionSettingsView(settings: settings).padding(12).frame(width: 520)
                        .background(Color(nsColor: .windowBackgroundColor)), appearance: .darkAqua)
                heights[mode] = image.size.height
                attach(image, "Motion mode \(mode.rawValue)")
            }
            XCTAssertLessThan(try XCTUnwrap(heights[.instant]), 130)
            XCTAssertLessThan(try XCTUnwrap(heights[.smooth]), 130)
            XCTAssertGreaterThan(try XCTUnwrap(heights[.custom]), try XCTUnwrap(heights[.smooth]))
            settings.notificationPresets = [
                .init(id: "first", threshold: 65), .init(id: "second", threshold: 85),
                .init(id: "third", threshold: 95),
            ]
            for basis in [UsageDisplayMode.used, .remaining] {
                settings.usageDisplayMode = basis
                for width in [CGFloat(240), 520] {
                    let image = try renderHosted(
                        NotificationThresholdEditor(settings: settings).padding(12).frame(width: width)
                            .background(Color(nsColor: .windowBackgroundColor)), appearance: .darkAqua)
                    XCTAssertEqual(image.size.width, width, accuracy: 1)
                    attach(image, "Notification rules \(basis.rawValue) width \(Int(width))")
                }
            }
        }
    }

    func testSettingsChoicesAdaptToAvailableWidthWithoutShrinkingLabels() throws {
        try withSettings { settings in
            for width in [CGFloat(420), 580, 760] {
                let view = VStack(alignment: .leading, spacing: AppDesign.Space.content) {
                    MenuBarDesignPicker(settings: settings)
                    SettingsChoiceGroup(
                        title: "메뉴바 색상",
                        options: MenuBarColorMode.allCases.map { ($0, $0.displayName) },
                        selection: settings.menuBarColorMode, onChange: { _ in })
                }.padding(12).frame(width: width).background(Color(nsColor: .windowBackgroundColor))
                let image = try renderHosted(view, appearance: .darkAqua)
                XCTAssertEqual(image.size.width, width, accuracy: 1)
                attach(image, "Adaptive settings width \(Int(width))")
            }
            let longLabels = SettingsChoiceGroup(
                title: "설명과 선택 항목이 긴 경우",
                options: [
                    (1, "이 선택은 긴 설명을 포함하며 줄바꿈 뒤에도 끝까지 읽을 수 있어야 합니다"),
                    (2, "두 번째 긴 선택 항목도 글자를 줄이지 않고 세로로 배치합니다"),
                ],
                selection: 1, onChange: { _ in }
            )
            .font(.title3).padding(12).frame(width: 300).background(Color(nsColor: .windowBackgroundColor))
            let image = try renderHosted(longLabels, appearance: .aqua)
            XCTAssertEqual(image.size.width, 300, accuracy: 1)
            attach(image, "Long settings choices vertical fallback")
        }
    }

    func testMotionExamplesGallery() throws {
        for category in AppMotionCategory.allCases {
            attach(
                try renderHosted(AppMotionComparisonView(category: category).frame(width: 500), appearance: .aqua),
                "Motion comparison \(category.rawValue)")
        }
    }

    func testSettingsMouseDownDismissesFieldEditorOnlyOutsideActiveTextField() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let content = NSView(frame: window.contentView?.bounds ?? .zero)
        let field = NSTextField(frame: NSRect(x: 20, y: 100, width: 100, height: 24))
        content.addSubview(field)
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        XCTAssertTrue(window.makeFirstResponder(field))
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(editor.isFieldEditor)

        let insideLocation = editor.convert(
            NSPoint(x: editor.bounds.midX, y: editor.bounds.midY),
            to: nil
        )
        let insideEvent = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: insideLocation,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )
        )
        _ = SettingsFocusDismissal.handleMouseDown(insideEvent)
        XCTAssertTrue(window.firstResponder === editor)

        let outsideEvent = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: NSPoint(x: 260, y: 40),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 2,
                clickCount: 1,
                pressure: 1
            )
        )
        _ = SettingsFocusDismissal.handleMouseDown(outsideEvent)
        XCTAssertFalse(window.firstResponder === editor)
    }

    func testMonochromeBatteryOnColoredBackgrounds() throws {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            var battery: NSImage?
            appearance.performAsCurrentDrawingAppearance {
                battery = MenuBarIconRenderer.batteryIcon(percentage: 80, color: .labelColor, monochrome: true)
            }
            let image = try XCTUnwrap(battery)
            let backgrounds: [Color] = [
                .white, .black, Color(red: 0.64, green: 0.9, blue: 0.98), Color(red: 0.9, green: 0.74, blue: 0.61),
            ]
            let gallery = VStack(spacing: 0) {
                ForEach(backgrounds.indices, id: \.self) { index in
                    HStack(spacing: 20) {
                        Image(nsImage: image)
                        Image(nsImage: image).scaleEffect(3).frame(width: 100, height: 50)
                    }.padding(12).frame(width: 220).background(backgrounds[index])
                }
            }
            attach(try render(gallery), "Monochrome background comparison \(appearanceName.rawValue)")
        }
    }

    private func render<V: View>(_ content: V) throws -> NSImage {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return try XCTUnwrap(renderer.nsImage)
    }

    /// ImageRenderer intentionally omits AppKit-backed controls/ScrollView. Host real views for visual QA.

    func testWhatsNewAndVersionHistoryGalleryRendersNativeViews() throws {
        let notes = BundledReleaseNotes.load(
            bundle: try BuiltAppTestResources.bundle(relativeTo: Self.self), upTo: "2.8.0")
        XCTAssertEqual(notes.count, 8)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let scheme: ColorScheme = appearance == .aqua ? .light : .dark
            let whatsNew = WhatsNewView(
                pages: WhatsNewCatalog.latestPages(upTo: "2.8.0"),
                onAction: { _ in }, onClose: {}, initialPageIndex: 1
            )
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(scheme)
            let slide = try renderHosted(whatsNew, appearance: appearance)
            XCTAssertEqual(slide.size.width, 340, accuracy: 0.5)
            XCTAssertEqual(slide.size.height, 360, accuracy: 0.5)
            attach(slide, "Whats-new-settings-page-\(appearance.rawValue)")
            var historyImages: [Data] = []
            for version in ["2.8.0", "2.7.0"] {
                let history = ReleaseNotesView(notes: notes, selectedVersion: version, onClose: {})
                    .background(Color(nsColor: .windowBackgroundColor))
                    .preferredColorScheme(scheme)
                let image = try renderHosted(history, appearance: appearance) { root in
                    self.inspectVersionPicker(in: root, titles: notes.map { "v\($0.version)" }, selected: "v\(version)")
                }
                XCTAssertEqual(image.size.width, 720, accuracy: 0.5)
                XCTAssertEqual(image.size.height, 540, accuracy: 0.5)
                historyImages.append(try XCTUnwrap(image.tiffRepresentation))
                attach(image, "Version-history-\(version)-\(appearance.rawValue)")
            }
            XCTAssertNotEqual(historyImages[0], historyImages[1], "Current and previous notes must render separately")
            let empty = ReleaseNotesView(notes: [], onClose: {})
                .background(Color(nsColor: .windowBackgroundColor))
                .preferredColorScheme(scheme)
            attach(try renderHosted(empty, appearance: appearance), "Version-history-empty-\(appearance.rawValue)")
            let actions = UpdateHistoryActions(onShowWhatsNew: {})
                .padding(AppDesign.Space.content)
                .frame(width: 320, alignment: .leading)
                .background(Color(nsColor: .windowBackgroundColor))
                .preferredColorScheme(scheme)
            attach(try renderHosted(actions, appearance: appearance), "Update-history-actions-\(appearance.rawValue)")
        }
    }

    func testCodexProSettingsAndPopoverEditorUseTheAccountResponse() async throws {
        let suite = "DesignSystemTests.codex-pro.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, hasExistingAccountStorage: false)
        settings.welcomeState = .completed
        settings.motion.mode = .instant
        settings.notificationsEnabled = true
        settings.setProviderEnabled(true, for: .codex)
        let usage = try JSONDecoder().decode(
            CodexUsageResponse.self,
            from: Data(
                """
                {"account_id":"settings-pro-fixture","plan_type":"pro",
                 "rate_limit":{"primary_window":{"used_percent":12,"limit_window_seconds":604800},
                               "secondary_window":null},
                 "spend_control":{},"credits":{"has_credits":true,"unlimited":false,"balance":"125.50"}}
                """.utf8))
        let storedFull = settings.popoverItems(for: .codex)
        let storedCompact = settings.compactPopoverItems(for: .codex)
        let dependencies = await makeSettingsGalleryDependencies(defaults: defaults, settings: settings)
        defer { dependencies.antigravity.stopObserving() }
        for section in [SettingsSection.limits, .popover] {
            let size = section == .limits ? AppDesign.Window.settingsMinimum : AppDesign.Window.settingsIdeal
            let calls = dependencies.codex.calls
            let view = SettingsView(
                claudeAPIService: dependencies.claude, antigravitySettings: dependencies.antigravity,
                settings: settings, updateRuntimeState: dependencies.updates,
                claudeAccountStore: dependencies.accountStore, sessionKeyLoader: { _ in nil },
                codexAuthStatusReader: dependencies.codex.status,
                claudeOAuthMigrationCoordinator: dependencies.migration,
                codexLastUsage: { usage }, codexLastError: { nil },
                initialPanel: .codex, initialSection: section)
            let image = try await renderSettingsNativeVerified(
                view.frame(width: size.width, height: size.height)
                    .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.light),
                size: size, appearance: .aqua,
                ready: { dependencies.updates.engineStatus != nil && dependencies.codex.calls > calls })
            attach(image, "Settings-codex-pro-\(section.rawValue)")
            XCTAssertEqual(settings.settingsLastTab, "codex")
        }
        XCTAssertEqual(settings.popoverItems(for: .codex), storedFull)
        XCTAssertEqual(settings.compactPopoverItems(for: .codex), storedCompact)
        XCTAssertEqual(dependencies.updateEngine.checks, 0)
        XCTAssertEqual(dependencies.reader.readCountSync, 0)
    }

    func testSettingsGalleryUsesAnEmptyMetadataCache() async throws {
        let suite = "DesignSystemTests.empty-cache.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, hasExistingAccountStorage: false)
        let dependencies = await makeSettingsGalleryDependencies(defaults: defaults, settings: settings)
        let metadata = await dependencies.claude.fetchCachedProfileMetadata()
        XCTAssertNil(metadata)
    }

    func testEntitySettingsGalleryUsesTheProductionLayoutWithFakeDependencies() async throws {
        let suite = "DesignSystemTests.settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, hasExistingAccountStorage: false)
        settings.welcomeState = .completed
        settings.motion.mode = .instant
        settings.notificationsEnabled = true
        for provider in AppProviderKind.allCases { settings.setProviderEnabled(true, for: provider) }
        let dependencies = await makeSettingsGalleryDependencies(defaults: defaults, settings: settings)
        let panels: [SettingsProviderPanel] = [.common, .display, .claude, .codex, .antigravity, .updates]
        for panel in panels {
            for size in [AppDesign.Window.settingsMinimum, AppDesign.Window.settingsIdeal] {
                for scheme in [ColorScheme.light, .dark] {
                    let view = SettingsView(
                        claudeAPIService: dependencies.claude, antigravitySettings: dependencies.antigravity,
                        settings: settings, updateRuntimeState: dependencies.updates,
                        claudeAccountStore: dependencies.accountStore, sessionKeyLoader: { _ in nil },
                        codexAuthStatusReader: dependencies.codex.status,
                        claudeOAuthMigrationCoordinator: dependencies.migration,
                        claudeLastUsage: { self.usage }, initialPanel: panel)
                    let content = view.frame(width: size.width, height: size.height)
                        .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(scheme)
                    let codexCalls = dependencies.codex.calls
                    let claudeReads = dependencies.reader.readCountSync
                    let image = try await renderSettingsNativeVerified(
                        content, size: size, appearance: scheme == .dark ? .darkAqua : .aqua,
                        onFailure: {
                            self.attach($0, "Settings-native-failure-\(panel.rawValue)-\(Int(size.width))-\(scheme)")
                        },
                        ready: {
                            dependencies.updates.engineStatus != nil
                                && (panel != .codex || dependencies.codex.calls > codexCalls)
                                && (panel != .claude || dependencies.reader.readCountSync > claudeReads)
                                && dependencies.antigravity.state.activity == .idle
                        })
                    XCTAssertEqual(settings.settingsLastTab, panel.rawValue)
                    attach(image, "Settings-entity-\(panel.rawValue)-\(Int(size.width))-\(scheme)")
                }
            }
        }
        XCTAssertGreaterThan(dependencies.codex.calls, 0)
        XCTAssertEqual(dependencies.updateEngine.checks, 0)
        XCTAssertEqual(settings.welcomeState, .completed)
        XCTAssertEqual(settings.settingsLastTab, "updates")
    }

    func testNativeSidebarRowsSelectEachPanelAndPreserveGroupDisclosure() async throws {
        guard #available(macOS 14.4, *) else {
            throw XCTSkip("Own-process WindowServer gallery requires macOS 14.4+. Production supports macOS 14.0.")
        }
        let suite = "DesignSystemTests.sidebar.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, hasExistingAccountStorage: false)
        settings.welcomeState = .completed
        settings.motion.mode = .instant
        for provider in AppProviderKind.allCases { settings.setProviderEnabled(true, for: provider) }
        let dependencies = await makeSettingsGalleryDependencies(defaults: defaults, settings: settings)
        defer { dependencies.antigravity.stopObserving() }
        let view = SettingsView(
            claudeAPIService: dependencies.claude, antigravitySettings: dependencies.antigravity,
            settings: settings, updateRuntimeState: dependencies.updates,
            claudeAccountStore: dependencies.accountStore, sessionKeyLoader: { _ in nil },
            codexAuthStatusReader: dependencies.codex.status,
            claudeOAuthMigrationCoordinator: dependencies.migration,
            claudeLastUsage: { self.usage }, initialPanel: .updates)
        let size = AppDesign.Window.settingsIdeal
        let panels = SettingsProviderRegistry.appPanels + SettingsProviderRegistry.servicePanels
        _ = try await renderSettingsNativeVerified(
            view.frame(width: size.width, height: size.height), size: size, appearance: .aqua,
            interaction: { window, host in
                let outline = try XCTUnwrap(settingsSidebarOutline(in: host))
                XCTAssertEqual(outline.numberOfChildren(ofItem: nil), 2)
                let groups = try (0..<2).map { try XCTUnwrap(outline.child($0, ofItem: nil)) }
                for group in groups {
                    XCTAssertEqual(outline.numberOfChildren(ofItem: group), 3)
                    outline.expandItem(group)
                }
                await yieldSettingsNativeMainQueue()
                XCTAssertEqual(outline.numberOfRows, 8)
                let leaves = try groups.flatMap { group in
                    try (0..<3).map { try XCTUnwrap(outline.child($0, ofItem: group)) }
                }
                XCTAssertEqual(Set(leaves.map { outline.row(forItem: $0) }).count, 6)
                for (index, item) in leaves.enumerated() {
                    let row = outline.row(forItem: item)
                    XCTAssertGreaterThanOrEqual(row, 0)
                    XCTAssertEqual(outline.numberOfChildren(ofItem: item), 0)
                    XCTAssertEqual(outline.level(forRow: row), 1)
                    XCTAssertNotNil(outline.rowView(atRow: row, makeIfNecessary: false))
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    let panel = panels[index].panel
                    let changed = await waitForSettingsReady { settings.settingsLastTab == panel.rawValue }
                    XCTAssertTrue(changed)
                    host.layoutSubtreeIfNeeded()
                    await yieldSettingsNativeMainQueue()
                    XCTAssertEqual(outline.selectedRow, row)
                    self.attach(
                        try await captureOwnSettingsWindow(window, hostView: host),
                        "Settings-sidebar-action-\(panel.rawValue)")
                    XCTAssertFalse(window.isKeyWindow)
                    XCTAssertFalse(NSApplication.shared.isActive)
                }
                let appGroup = try XCTUnwrap(outline.child(0, ofItem: nil))
                let appChild = try XCTUnwrap(outline.child(0, ofItem: appGroup))
                XCTAssertGreaterThanOrEqual(outline.row(forItem: appChild), 0)
                outline.collapseItem(appGroup)
                await yieldSettingsNativeMainQueue()
                XCTAssertEqual(outline.row(forItem: appChild), -1)
                XCTAssertEqual(outline.numberOfRows, 5)
                self.attach(
                    try await captureOwnSettingsWindow(window, hostView: host), "Settings-sidebar-apps-collapsed")
                outline.expandItem(try XCTUnwrap(outline.child(0, ofItem: nil)))
                await yieldSettingsNativeMainQueue()
                let expandedGroup = try XCTUnwrap(outline.child(0, ofItem: nil))
                let expandedChild = try XCTUnwrap(outline.child(0, ofItem: expandedGroup))
                XCTAssertGreaterThanOrEqual(outline.row(forItem: expandedChild), 0)
                XCTAssertEqual(outline.numberOfRows, 8)
                XCTAssertEqual(settings.settingsLastTab, "antigravity")
            },
            ready: { dependencies.updates.engineStatus != nil })
        let agy = settingsGalleryAGYSnapshot()
        guard case .ready(let quota) = agy.presentationState else { return XCTFail("Missing ready CLI fixture") }
        XCTAssertNil(quota.identity)
        XCTAssertNil(quota.provenance.accountIdentity)
        XCTAssertEqual(settingsGalleryAGYWelcomeStatuses()[.antigravity], .verified)
        XCTAssertEqual(dependencies.updateEngine.checks, 0)
    }

    func testServiceSectionDestinationsRenderInsideTheSameSettingsLayout() async throws {
        let suite = "DesignSystemTests.settings-editor.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, hasExistingAccountStorage: false)
        settings.welcomeState = .completed
        settings.motion.mode = .instant
        for provider in AppProviderKind.allCases { settings.setProviderEnabled(true, for: provider) }
        let dependencies = await makeSettingsGalleryDependencies(defaults: defaults, settings: settings)
        for provider in AppProviderKind.allCases {
            for section in [SettingsSection.limits, .popover] {
                let size = section == .limits ? AppDesign.Window.settingsMinimum : AppDesign.Window.settingsIdeal
                for scheme in [ColorScheme.light, .dark] {
                    let view = SettingsView(
                        claudeAPIService: dependencies.claude, antigravitySettings: dependencies.antigravity,
                        settings: settings, updateRuntimeState: dependencies.updates,
                        claudeAccountStore: dependencies.accountStore, sessionKeyLoader: { _ in nil },
                        codexAuthStatusReader: dependencies.codex.status,
                        claudeOAuthMigrationCoordinator: dependencies.migration,
                        claudeLastUsage: { self.usage }, initialPanel: .service(provider), initialSection: section)
                    let content = view.frame(width: size.width, height: size.height)
                        .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(scheme)
                    let codexCalls = dependencies.codex.calls
                    let claudeReads = dependencies.reader.readCountSync
                    let image = try await renderSettingsNativeVerified(
                        content, size: size, appearance: scheme == .dark ? .darkAqua : .aqua,
                        ready: {
                            dependencies.updates.engineStatus != nil
                                && (provider != .codex || dependencies.codex.calls > codexCalls)
                                && (provider != .claude || dependencies.reader.readCountSync > claudeReads)
                                && dependencies.antigravity.state.activity == .idle
                        })
                    XCTAssertEqual(settings.settingsLastTab, SettingsProviderPanel.service(provider).rawValue)
                    attach(image, "Settings-section-\(section.rawValue)-\(provider.rawValue)-\(scheme)")
                }
            }
        }
        XCTAssertGreaterThan(dependencies.codex.calls, 0)
        XCTAssertEqual(dependencies.updateEngine.checks, 0)
    }

    func testWelcomeAppearanceLoadsAGYWithoutVisitingItsServicePane() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let suite = "DesignSystemTests.welcome-unloaded.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = AppSettings(defaults: defaults, hasExistingAccountStorage: false)
            settings.welcomeState = .pending
            settings.welcomeStep = .services
            settings.motion.mode = .instant
            settings.setProviderEnabled(true, for: .antigravity)
            settings.setActiveProvider(.antigravity)
            let dependencies = await makeSettingsGalleryDependencies(
                defaults: defaults, settings: settings, preloadAntigravity: false)
            defer { dependencies.antigravity.stopObserving() }
            let detector = SettingsGalleryOnboardingDetector()
            let view = SettingsView(
                claudeAPIService: dependencies.claude, antigravitySettings: dependencies.antigravity,
                settings: settings, updateRuntimeState: dependencies.updates,
                claudeAccountStore: dependencies.accountStore, sessionKeyLoader: { _ in nil },
                codexAuthStatusReader: dependencies.codex.status,
                claudeOAuthMigrationCoordinator: dependencies.migration,
                initialPanel: .welcome, welcomeStatuses: { settingsGalleryAGYWelcomeStatuses() },
                onboardingDetector: detector.detect)
            XCTAssertNil(dependencies.antigravity.state.display)
            XCTAssertNil(view.settingsDataPreparationRequest)
            let initialBootstraps = await dependencies.runtime.bootstrapArguments()
            XCTAssertTrue(initialBootstraps.isEmpty)
            let size = AppDesign.Window.settingsIdeal
            let content = view.frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(scheme)
            let image = try await renderSettingsNativeVerified(
                content, size: size, appearance: scheme == .dark ? .darkAqua : .aqua,
                change: { settings.welcomeStep = .appearance },
                ready: { dependencies.antigravity.state.display != nil && detector.calls > 0 })
            XCTAssertEqual(dependencies.antigravity.state.display, AntigravityDisplaySettings.default)
            XCTAssertEqual(dependencies.antigravity.state.activity, .idle)
            let bootstraps = await dependencies.runtime.bootstrapArguments()
            XCTAssertEqual(bootstraps, [true])
            let reads = await dependencies.reader.readCount()
            XCTAssertEqual(reads, 0)
            XCTAssertEqual(detector.calls, 1)
            attach(image, "Settings-Welcome-AGY-unloaded-to-ready-\(scheme)")
        }
    }

    func testDisplayLoadsActiveAGYWithoutVisitingItsServicePane() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let suite = "DesignSystemTests.display-unloaded.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = AppSettings(defaults: defaults, hasExistingAccountStorage: false)
            settings.welcomeState = .completed
            settings.motion.mode = .instant
            settings.setProviderEnabled(true, for: .antigravity)
            settings.setActiveProvider(.antigravity)
            let dependencies = await makeSettingsGalleryDependencies(
                defaults: defaults, settings: settings, preloadAntigravity: false)
            defer { dependencies.antigravity.stopObserving() }
            let view = SettingsView(
                claudeAPIService: dependencies.claude, antigravitySettings: dependencies.antigravity,
                settings: settings, updateRuntimeState: dependencies.updates,
                claudeAccountStore: dependencies.accountStore, sessionKeyLoader: { _ in nil },
                codexAuthStatusReader: dependencies.codex.status,
                claudeOAuthMigrationCoordinator: dependencies.migration,
                initialPanel: .display, onboardingDetector: { OnboardingDetection(isLoaded: true) })
            XCTAssertNil(dependencies.antigravity.state.display)
            XCTAssertEqual(view.settingsDataPreparationRequest?.provider, .antigravity)
            let size = AppDesign.Window.settingsIdeal
            let content = view.frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(scheme)
            let image = try await renderSettingsNativeVerified(
                content, size: size, appearance: scheme == .dark ? .darkAqua : .aqua,
                ready: { dependencies.antigravity.state.display != nil })
            XCTAssertEqual(dependencies.antigravity.state.display, AntigravityDisplaySettings.default)
            XCTAssertEqual(dependencies.antigravity.state.activity, .idle)
            let bootstraps = await dependencies.runtime.bootstrapArguments()
            XCTAssertEqual(bootstraps, [true])
            let reads = await dependencies.reader.readCount()
            XCTAssertEqual(reads, 0)
            attach(image, "Settings-Display-active-AGY-unloaded-to-ready-\(scheme)")
        }
    }

    func testAGYPopoverDestinationCapturesBeforeAndAfterUnloadedRuntimePublishes() async throws {
        for size in [AppDesign.Window.settingsMinimum, AppDesign.Window.settingsIdeal] {
            for scheme in [ColorScheme.light, .dark] {
                let suite = "DesignSystemTests.agy-popover-load.\(UUID().uuidString)"
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                let settings = AppSettings(defaults: defaults, hasExistingAccountStorage: false)
                settings.welcomeState = .completed
                settings.motion.mode = .instant
                settings.setProviderEnabled(true, for: .antigravity)
                settings.setActiveProvider(.antigravity)
                let gate = SettingsGalleryLoadGate()
                let dependencies = await makeSettingsGalleryDependencies(
                    defaults: defaults, settings: settings,
                    preloadAntigravity: false, antigravityLoadGate: gate)
                defer { dependencies.antigravity.stopObserving() }
                XCTAssertNil(dependencies.antigravity.state.display)
                let view = SettingsView(
                    claudeAPIService: dependencies.claude, antigravitySettings: dependencies.antigravity,
                    settings: settings, updateRuntimeState: dependencies.updates,
                    claudeAccountStore: dependencies.accountStore, sessionKeyLoader: { _ in nil },
                    codexAuthStatusReader: dependencies.codex.status,
                    claudeOAuthMigrationCoordinator: dependencies.migration,
                    initialPanel: .antigravity, initialSection: .popover,
                    onboardingDetector: { OnboardingDetection(isLoaded: true) })
                let content = view.frame(width: size.width, height: size.height)
                    .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(scheme)
                var released = false
                do {
                    let image = try await renderSettingsNativeVerified(
                        content, size: size, appearance: scheme == .dark ? .darkAqua : .aqua,
                        initialCapture: .init(
                            ready: {
                                guard dependencies.antigravity.state.display == nil,
                                    dependencies.antigravity.state.activity == .loading
                                else { return false }
                                return await gate.hasBothLoadEntries()
                            },
                            didCapture: { initial in
                                self.attach(initial, "Settings-AGY-popover-before-load-\(Int(size.width))-\(scheme)")
                                released = await gate.releaseAfterPixelObservation()
                                XCTAssertTrue(released)
                            }),
                        onFailure: {
                            self.attach($0, "Settings-AGY-popover-load-failure-\(Int(size.width))-\(scheme)")
                        },
                        ready: {
                            released && dependencies.antigravity.state.display != nil
                                && dependencies.antigravity.state.activity == .idle
                        })
                    XCTAssertEqual(dependencies.antigravity.state.display, AntigravityDisplaySettings.default)
                    XCTAssertEqual(settings.settingsLastTab, SettingsProviderPanel.antigravity.rawValue)
                    let bootstraps = await dependencies.runtime.bootstrapArguments()
                    XCTAssertEqual(bootstraps, [true])
                    XCTAssertEqual(dependencies.reader.readCountSync, 0)
                    XCTAssertEqual(dependencies.codex.calls, 0)
                    XCTAssertEqual(dependencies.updateEngine.checks, 0)
                    attach(image, "Settings-AGY-popover-after-load-\(Int(size.width))-\(scheme)")
                    await gate.cancel()
                } catch {
                    await gate.cancel()
                    throw error
                }
            }
        }
    }

    private func renderHosted<V: View>(
        _ content: V, appearance: NSAppearance.Name, inspect: ((NSView) -> Void)? = nil
    ) throws -> NSImage {
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = []
        let size = controller.sizeThatFits(in: CGSize(width: 2000, height: 2000))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentViewController = controller
        controller.view.frame = NSRect(origin: .zero, size: size)
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        controller.view.layoutSubtreeIfNeeded()
        inspect?(controller.view)
        let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        window.close()
        return image
    }

    private func inspectVersionPicker(in root: NSView, titles: [String], selected: String) {
        func popups(in view: NSView) -> [NSPopUpButton] {
            let own = (view as? NSPopUpButton).map { [$0] } ?? []
            return own + view.subviews.flatMap { popups(in: $0) }
        }
        let buttons = popups(in: root)
        let native = buttons.first
        let snapshot = XCTAttachment(
            string: "expected=\(titles)\nselected=\(selected)\n"
                + "nativePopups=\(buttons.map(\.itemTitles))\n"
                + "nativeSelection=\(native?.titleOfSelectedItem ?? "not exposed")")
        snapshot.name = "Native version picker before capture \(selected)"
        snapshot.lifetime = .keepAlways
        add(snapshot)
        if let native {
            XCTAssertEqual(Set(native.itemTitles.filter { titles.contains($0) }), Set(titles))
            XCTAssertEqual(native.titleOfSelectedItem, selected)
        }
    }

    private func attach(_ image: NSImage, _ name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["CLAUDEUSAGE_UI_RENDER_DIRECTORY"] {
            do {
                let folder = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let name = name.unicodeScalars.map {
                    CharacterSet.alphanumerics.contains($0) || $0 == "-" ? String($0) : "-"
                }.joined()
                guard let bitmap = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
                    let png = bitmap.representation(using: .png, properties: [:])
                else {
                    XCTFail("Could not export UI fixture image")
                    return
                }
                try png.write(to: folder.appendingPathComponent(name + ".png"), options: .atomic)
            } catch {
                XCTFail("Could not export UI fixture image: \(error)")
            }
        }
    }
}


@MainActor
private func makeSettingsGalleryDependencies(
    defaults: UserDefaults, settings: AppSettings, preloadAntigravity: Bool = true,
    antigravityLoadGate: SettingsGalleryLoadGate? = nil
) async -> (
    claude: ClaudeAPIService,
    reader: SettingsGalleryOAuthReader,
    migration: ClaudeOAuthCredentialMigrationCoordinator,
    antigravity: AntigravitySettingsViewModel,
    runtime: SettingsGalleryAGYRuntime,
    accountStore: ClaudeAccountStore,
    codex: SettingsGalleryCodexReader,
    updates: UpdateRuntimeState,
    updateEngine: SettingsGalleryUpdateEngine,
    metadataDirectory: SettingsGalleryMetadataDirectory
) {
    defaults.set(
        ClaudeAccountStore.currentMigrationVersion,
        forKey: ClaudeAccountStore.migrationVersionDefaultsKey
    )
    let vault = SettingsGalleryEmptyVault()
    let accountStore = ClaudeAccountStore(
        defaults: defaults,
        keychainVault: vault,
        legacySandboxCredentialStore: nil,
        postsNotifications: false
    )
    let reader = SettingsGalleryOAuthReader()
    let metadataDirectory = SettingsGalleryMetadataDirectory()
    let cache = ClaudeAPIService.CacheStorage(defaults: defaults, profileMetadataDirectory: metadataDirectory.url)
    let claude = ClaudeAPIService(
        accountStore: accountStore,
        oauthCredentialReader: reader,
        sessionKeyLoader: { _ in nil },
        cacheStorage: cache
    )
    let migration = ClaudeOAuthCredentialMigrationCoordinator(
        destination: vault,
        migrator: SettingsGalleryNoMigration()
    )
    precondition(antigravityLoadGate == nil || !preloadAntigravity)
    let runtime = SettingsGalleryAGYRuntime(snapshot: settingsGalleryAGYSnapshot(), loadGate: antigravityLoadGate)
    let antigravity = AntigravitySettingsViewModel(runtimeController: runtime)
    if preloadAntigravity {
        await antigravity.load()
        antigravity.stopObserving()
    }
    let updateEngine = SettingsGalleryUpdateEngine()
    let updates = UpdateRuntimeState(
        settings: settings,
        updateService: UpdateService(engine: updateEngine))
    return (
        claude, reader, migration, antigravity, runtime, accountStore,
        SettingsGalleryCodexReader(), updates, updateEngine, metadataDirectory
    )
}

private actor SettingsGalleryOAuthReader: ClaudeOAuthCredentialReading {
    nonisolated private let counter = SettingsGalleryReadCounter()
    nonisolated var readCountSync: Int { counter.value }
    func readCount() -> Int { counter.value }
    func readAccessToken() async throws -> String? { counter.increment(); return nil }
    func refreshCredentialInventoryWithoutUI() async throws -> ClaudeOAuthCredentialInventoryRefresh {
        .init(accessToken: nil, credentialChanged: false)
    }
    func forceRefreshAccessToken() async throws -> String? { nil }
    func invalidateCache() async {}
    func importActiveCLICredential() async -> ClaudeOAuthCredentialImportResult { .notFound }
}

private nonisolated struct SettingsGalleryEmptyVault: ClaudeSessionKeyVault, ClaudeOAuthCredentialVault {
    func saveString(_ value: String, account: String) throws {}
    func loadString(account: String) throws -> String? { nil }
    func delete(account: String) throws {}
    func loadPayload() throws -> String? { nil }
    func savePayload(_ payload: String) throws {}
    func deletePayload() throws {}
}

private nonisolated struct SettingsGalleryNoMigration: ClaudeOAuthLegacyCredentialMigrating {
    func availability(destination: any ClaudeOAuthCredentialVault) -> ClaudeOAuthCredentialMigrationAvailability {
        .notNeeded
    }
    func migrate(destination: any ClaudeOAuthCredentialVault) -> ClaudeOAuthCredentialMigrationResult {
        .cancelled
    }
}

private actor SettingsGalleryLoadGate {
    enum Entry: Hashable, Sendable { case bootstrap, snapshots }
    enum State { case held, released, cancelled }
    private var state = State.held
    private var entered: Set<Entry> = []
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    func hasBothLoadEntries() -> Bool {
        entered.contains(.bootstrap) && entered.contains(.snapshots)
    }

    func wait(for entry: Entry) async -> Bool {
        entered.insert(entry)
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                switch state {
                case .released: continuation.resume(returning: true)
                case .cancelled: continuation.resume(returning: false)
                case .held:
                    if Task.isCancelled { continuation.resume(returning: false) } else { waiters[token] = continuation }
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(token) }
        }
    }

    @discardableResult
    func releaseAfterPixelObservation() -> Bool {
        guard state == .held, hasBothLoadEntries() else { return false }
        state = .released
        completeWaiters(allowed: true)
        return true
    }

    func cancel() {
        guard state == .held else { return }
        state = .cancelled
        completeWaiters(allowed: false)
    }

    private func cancelWaiter(_ token: UUID) {
        waiters.removeValue(forKey: token)?.resume(returning: false)
    }

    private func completeWaiters(allowed: Bool) {
        let pending = Array(waiters.values)
        waiters.removeAll()
        for continuation in pending { continuation.resume(returning: allowed) }
    }
}

private actor SettingsGalleryAGYRuntime: AntigravitySettingsRuntimeControlling {
    private let value: AntigravityRuntimeSnapshot
    private let loadGate: SettingsGalleryLoadGate?
    private var bootstrapRequests: [Bool] = []

    init(snapshot: AntigravityRuntimeSnapshot, loadGate: SettingsGalleryLoadGate? = nil) {
        value = snapshot
        self.loadGate = loadGate
    }

    func snapshot() async -> AntigravityRuntimeSnapshot { value }
    func snapshots() async -> AsyncStream<AntigravityRuntimeSnapshot> {
        if let loadGate, !(await loadGate.wait(for: .snapshots)) {
            return AsyncStream { $0.finish() }
        }
        return AsyncStream { continuation in
            continuation.yield(value)
            continuation.finish()
        }
    }
    func bootstrapArguments() -> [Bool] { bootstrapRequests }
    func bootstrap(performInitialRefresh: Bool) async -> AntigravityRuntimeSnapshot {
        bootstrapRequests.append(performInitialRefresh)
        if let loadGate, !(await loadGate.wait(for: .bootstrap)) { return .idle }
        return value
    }
    func refresh(trigger: AntigravityRefreshTrigger) async -> AntigravityRuntimeSnapshot { value }
    func updateDisplay(
        _ display: AntigravityDisplaySettings, replacing expectedDisplay: AntigravityDisplaySettings
    ) async throws -> AntigravityRuntimeSnapshot { value }
    func consumePendingSettingsNotice() async -> AntigravityRuntimeSnapshot { value }
}

private nonisolated func settingsGalleryAGYSnapshot() -> AntigravityRuntimeSnapshot {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let specifications: [(AntigravityQuotaLaneID, AntigravityQuotaScope, Double)] = [
        (.geminiWeekly, .gemini, 0.82),
        (.thirdPartyWeekly, .thirdPartyModels, 0.54),
    ]
    let lanes = specifications.map { id, scope, remaining in
        AntigravityQuotaLane(
            id: id,
            upstreamGroupID: id.rawValue,
            upstreamBucketID: id.rawValue,
            scope: scope,
            cadence: .weekly,
            remainingFraction: remaining,
            resetAt: now.addingTimeInterval(4 * 86400),
            resetDescription: nil,
            availability: .available
        )
    }
    let quota = AntigravityQuotaSnapshot(
        identity: nil,
        plan: nil,
        lanes: lanes,
        decodeIssues: [],
        provenance: .init(
            transport: .cliUsageReport,
            endpointOwner: .managed,
            accountIdentity: nil,
            capability: .groupedQuotaSummary,
            processIdentity: nil
        ),
        fetchedAt: now
    )
    return AntigravityRuntimeSnapshot(
        readiness: .ready,
        settings: .init(connection: .default, display: .default),
        presentationState: .ready(quota),
        quotaPresentation: .content(
            AntigravityQuotaPresentationMapper.map(
                snapshot: quota,
                settings: .default,
                now: now,
                timeZone: TimeZone(secondsFromGMT: 0)!
            )
        ),
        managedRuntimeAvailability: .available(displayPath: "fixture/agy"),
        lastAttemptAt: now,
        lastSuccessfulAt: now,
        publicationRevision: 1
    )
}

@MainActor
private func settingsGalleryAGYWelcomeStatuses() -> [AppProviderKind: WelcomeServiceStatus] {
    let antigravity = settingsGalleryAGYSnapshot()
    let facade = AppRuntimeStateFacade()
    facade.antigravityRuntimeSnapshot = antigravity
    return [
        .antigravity: WelcomeServiceStatus.resolve(
            snapshot: facade.snapshot(for: .antigravity, codexAuthenticated: false), antigravity: antigravity)
    ]
}

@MainActor
private func settingsSidebarOutline(in view: NSView) -> NSOutlineView? {
    if let outline = view as? NSOutlineView { return outline }
    for child in view.subviews {
        if let outline = settingsSidebarOutline(in: child) { return outline }
    }
    return nil
}

@MainActor
private final class SettingsGalleryOnboardingDetector {
    private(set) var calls = 0

    func detect() async -> OnboardingDetection {
        calls += 1
        return OnboardingDetection(isLoaded: true)
    }
}

@MainActor
private final class SettingsGalleryCodexReader {
    private(set) var calls = 0

    func status(isProviderEnabled: Bool) async -> CodexAuthStatus {
        calls += 1
        return isProviderEnabled ? .authenticated : .notLoggedIn
    }
}

@MainActor
private final class SettingsGalleryUpdateEngine: AppUpdateEngine {
    private(set) var checks = 0

    func modeSummary() async -> String { "가상 업데이트" }
    func checkForUpdates() async -> UpdateCheckResult { checks += 1; return .upToDate(message: nil) }
    func latestDownloadURL() async -> URL { URL(string: "https://example.com/fixture.zip")! }
    func usesExternalScheduler() async -> Bool { true }
    func supportsInteractiveCheck() async -> Bool { false }
    func performInteractiveCheck() async -> String? { checks += 1; return nil }
    func presentPreparedUpdate() async -> Bool { false }
    func synchronizeScheduler(interval: UpdateCheckInterval, runImmediate: Bool) async {}
    func installPreparedUpdate() async -> Bool { false }
    func configurationStatus() async -> UpdateEngineStatus {
        .init(modeSummary: "가상 업데이트", sparkleIntegrated: false, feedConfigured: false, publicKeyConfigured: false)
    }
}

private nonisolated final class SettingsGalleryReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}

@MainActor
private final class SettingsGalleryNonKeyWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private struct SettingsInitialCapture {
    let ready: () async -> Bool
    let didCapture: (NSImage) async -> Void
}

@MainActor
private func renderSettingsNativeVerified<V: View>(
    _ content: V,
    size: CGSize,
    appearance: NSAppearance.Name,
    change: () -> Void = {},
    interaction: ((NSWindow, NSView) async throws -> Void)? = nil,
    initialCapture: SettingsInitialCapture? = nil,
    onFailure: (NSImage) -> Void = { _ in },
    ready: () -> Bool = { true },
    file: StaticString = #filePath,
    line: UInt = #line
) async throws -> NSImage {
    guard #available(macOS 14.4, *) else {
        throw XCTSkip("Own-process WindowServer gallery requires macOS 14.4+. Production supports macOS 14.0.")
    }
    let application = NSApplication.shared
    let originalAppearance = application.appearance
    application.appearance = NSAppearance(named: appearance)
    defer { application.appearance = originalAppearance }
    let controller = NSHostingController(rootView: content)
    controller.sizingOptions = []
    let screen = try XCTUnwrap(NSScreen.main, file: file, line: line)
    let origin = NSPoint(
        x: screen.visibleFrame.midX - size.width / 2,
        y: screen.visibleFrame.midY - size.height / 2)
    let window = SettingsGalleryNonKeyWindow(
        contentRect: NSRect(origin: origin, size: size),
        styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    window.ignoresMouseEvents = true
    window.isExcludedFromWindowsMenu = true
    window.appearance = NSAppearance(named: appearance)
    window.contentViewController = controller
    window.setContentSize(size)
    controller.view.frame = NSRect(origin: .zero, size: size)
    window.setFrameOrigin(origin)
    window.orderFront(nil)
    defer { window.orderOut(nil); window.close() }
    controller.view.layoutSubtreeIfNeeded()
    window.displayIfNeeded()

    XCTAssertFalse(window.isKeyWindow, file: file, line: line)
    XCTAssertFalse(application.isActive, file: file, line: line)
    await yieldSettingsNativeMainQueue()
    if let initialCapture {
        let initialReady = await waitForSettingsReady(initialCapture.ready)
        controller.view.layoutSubtreeIfNeeded()
        await yieldSettingsNativeMainQueue()
        let initial = try await captureOwnSettingsWindow(window, hostView: controller.view)
        if !initialReady { onFailure(initial) }
        _ = try XCTUnwrap(
            initialReady ? true : nil, "Initial settings phase did not become ready", file: file, line: line)
        await initialCapture.didCapture(initial)
    }
    change()
    let dataReady = await waitForSettingsReady { ready() }
    controller.view.layoutSubtreeIfNeeded()
    await yieldSettingsNativeMainQueue()
    if let interaction { try await interaction(window, controller.view) }
    let image = try await captureOwnSettingsWindow(window, hostView: controller.view)
    XCTAssertFalse(application.isActive, file: file, line: line)
    XCTAssertFalse(window.isKeyWindow, file: file, line: line)
    XCTAssertEqual(window.contentLayoutRect.width, size.width, accuracy: 0.5, file: file, line: line)
    XCTAssertEqual(window.contentLayoutRect.height, size.height, accuracy: 0.5, file: file, line: line)
    XCTAssertEqual(controller.view.bounds.width, size.width, accuracy: 0.5, file: file, line: line)
    XCTAssertEqual(controller.view.bounds.height, size.height, accuracy: 0.5, file: file, line: line)
    if !dataReady { onFailure(image) }
    _ = try XCTUnwrap(dataReady ? true : nil, "Settings dependencies did not become ready", file: file, line: line)
    return image
}

@MainActor
private func waitForSettingsReady(_ ready: () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(1)
    while clock.now < deadline {
        if await ready() { return true }
        await yieldSettingsNativeMainQueue()
    }
    return await ready()
}

@MainActor
private func yieldSettingsNativeMainQueue() async {
    await withCheckedContinuation { continuation in
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max
        ) { _, _ in continuation.resume() }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}

private nonisolated final class SettingsGalleryMetadataDirectory {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "SettingsGalleryMetadata-\(UUID().uuidString)", isDirectory: true)

    deinit {
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

private enum OwnWindowCaptureError: Error {
    case hostNotInSpecifiedWindow
    case ownWindowNotAvailable
    case invalidCanvas(contentRect: CGRect, pixelScale: CGFloat)
    case emptyCapturedImage(pixelSize: CGSize)
    case geometryChangedDuringCapture
}

// Capture only this test process's window, preserving the WindowServer's native canvas.
@available(macOS 14.4, *)
@MainActor
private func captureOwnSettingsWindow(_ window: NSWindow, hostView: NSView) async throws -> NSImage {
    guard hostView.window === window, window.windowNumber > 0, !hostView.bounds.isEmpty else {
        throw OwnWindowCaptureError.hostNotInSpecifiedWindow
    }
    let windowID = CGWindowID(window.windowNumber)
    let windowFrame = window.frame
    let hostBounds = hostView.bounds
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(1)
    var filter: SCContentFilter?
    var captureSize = CGSize.zero
    var nativeScale: CGFloat = 0
    var lastCanvas = CGRect.zero
    repeat {
        let content = try await SCShareableContent.currentProcess
        guard
            let own = content.windows.first(where: {
                $0.windowID == windowID && $0.owningApplication?.processID == getpid()
            })
        else { throw OwnWindowCaptureError.ownWindowNotAvailable }
        let candidate = SCContentFilter(desktopIndependentWindow: own)
        lastCanvas = candidate.contentRect
        nativeScale = CGFloat(candidate.pointPixelScale)
        captureSize = lastCanvas.size
        if nativeScale.isFinite, nativeScale > 0,
            captureSize.width.isFinite, captureSize.width > 0,
            captureSize.height.isFinite, captureSize.height > 0
        {
            filter = candidate
            break
        }
        window.displayIfNeeded()
        await yieldSettingsNativeMainQueue()
    } while clock.now < deadline
    guard let filter else {
        throw OwnWindowCaptureError.invalidCanvas(contentRect: lastCanvas, pixelScale: nativeScale)
    }
    let configuration = SCStreamConfiguration()
    configuration.width = Int(ceil(captureSize.width * nativeScale))
    configuration.height = Int(ceil(captureSize.height * nativeScale))
    configuration.showsCursor = false
    configuration.capturesAudio = false
    configuration.includeChildWindows = false
    configuration.ignoreShadowsSingleWindow = true
    configuration.capturesShadowsOnly = false
    let captured = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    guard window.windowNumber == Int(windowID), window.frame == windowFrame,
        hostView.window === window, hostView.bounds == hostBounds
    else { throw OwnWindowCaptureError.geometryChangedDuringCapture }
    guard captured.width > 0, captured.height > 0 else {
        throw OwnWindowCaptureError.emptyCapturedImage(
            pixelSize: CGSize(width: captured.width, height: captured.height))
    }
    return NSImage(cgImage: captured, size: captureSize)
}

private nonisolated struct PopoverRowFramesPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
    }
}

@MainActor
private func popoverRowFrameProbe(_ role: String) -> some View {
    GeometryReader { geometry in
        Color.clear.preference(
            key: PopoverRowFramesPreferenceKey.self,
            value: [role: geometry.frame(in: .named("popover-row-geometry"))])
    }
}

private nonisolated final class PopoverRowGeometryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [String: CGRect] = [:]
    private var baseline: CGFloat?

    func recordFrames(_ value: [String: CGRect]) {
        lock.lock()
        defer { lock.unlock() }
        frames = value
    }

    func recordBaseline(_ value: CGFloat) {
        lock.lock()
        defer { lock.unlock() }
        baseline = value
    }

    func snapshot() -> (frames: [String: CGRect], baseline: CGFloat?) {
        lock.lock()
        defer { lock.unlock() }
        return (frames, baseline)
    }
}

// Observe the real child value's public baseline without adding geometry,
// changing its proposal, or giving production views a diagnostic callback.
private struct PopoverValueBaselineProbe: Layout {
    let recorder: PopoverRowGeometryRecorder

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let dimensions = child.dimensions(in: proposal)
        recorder.recordBaseline(dimensions[VerticalAlignment.firstTextBaseline])
        return CGSize(width: dimensions.width, height: dimensions.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
    }

    func explicitAlignment(
        of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGFloat? {
        subviews.first?.dimensions(in: proposal)[guide]
    }
}
