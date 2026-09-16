import AppKit
import SwiftUI
import XCTest
@testable import ClaudeUsage

@MainActor
final class DesignSystemTests: XCTestCase {
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
            XCTAssertTrue(first.tooltip.contains("주간 —"))
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
            ProviderOverviewCardView(
                title: "연결된 서비스", subtitle: nil,
                items: [
                    .init(id: "claude", title: "Claude", isEnabled: true, isActive: true, summary: "사용량 확인됨"),
                    .init(id: "codex", title: "Codex", isEnabled: true, isActive: false, summary: "로그인 필요"),
                ])
            ClaudeOAuthMigrationCard(state: .available, onMigrate: {}, onDefer: {}, onReconnectClaudeCode: {})
            SettingsDisclosureControl(isExpanded: .constant(true), accessibilityLabel: "고급 진단") {
                Text("고급 진단")
            } content: {
                Text("이전 사용량 표시 중 · 5분 전 성공").font(AppDesign.Typography.caption)
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

    private func render<V: View>(_ content: V) throws -> NSImage {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return try XCTUnwrap(renderer.nsImage)
    }

    /// ImageRenderer intentionally omits AppKit-backed controls/ScrollView. Host real views for visual QA.
    private func renderHosted<V: View>(_ content: V, appearance: NSAppearance.Name) throws -> NSImage {
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
        let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        window.close()
        return image
    }

    private func attach(_ image: NSImage, _ name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
