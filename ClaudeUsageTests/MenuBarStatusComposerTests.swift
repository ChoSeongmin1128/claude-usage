import AppKit
import XCTest
@testable import ClaudeUsage

@MainActor
final class MenuBarStatusComposerTests: XCTestCase {
    func testStatusBadgeOutlineStaysInsideMenuBarIconCanvas() {
        let size = NSSize(width: 18, height: 18)

        for indicator in [StatusIndicator.minor, .critical] {
            let badge = MenuBarIconFactory.statusBadgeRect(
                for: size,
                indicator: indicator
            )
            let outline = badge.insetBy(dx: -1, dy: -1)

            XCTAssertGreaterThanOrEqual(outline.minX, 0)
            XCTAssertGreaterThanOrEqual(outline.minY, 0)
            XCTAssertLessThanOrEqual(outline.maxX, size.width)
            XCTAssertLessThanOrEqual(outline.maxY, size.height)
        }
    }

    func testCodexMenuBarAssetUsesSuppliedAquaAndDarkAquaAppearances() throws {
        let source = try XCTUnwrap(codexAssetImage())
        let aqua = try XCTUnwrap(NSAppearance(named: .aqua))
        let darkAqua = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let size = NSSize(width: 18, height: 18)

        let lightIcon = MenuBarIconFactory.rasterizedIcon(
            source,
            size: size,
            appearance: aqua
        )
        let darkIcon = MenuBarIconFactory.rasterizedIcon(
            source,
            size: size,
            appearance: darkAqua
        )

        XCTAssertLessThan(try averageOpaqueLuminance(of: lightIcon), 0.25)
        XCTAssertGreaterThan(try averageOpaqueLuminance(of: darkIcon), 0.75)
    }

    func testMenuBarColorModeControlsGaugeColor() {
        func claudeColor(percentage: Double, mode: MenuBarColorMode) -> NSColor {
            let usage = ClaudeUsageResponse(
                fiveHour: UsageWindow(utilization: percentage, resetsAt: nil),
                sevenDay: nil
            )
            return MenuBarStatusComposer.claudeSnapshot(
                config: ProviderMenuBarDisplayConfig(
                    kind: .claude,
                    showIcon: false,
                    style: .none,
                    percentageDisplay: .fiveHour,
                    showBatteryPercent: false,
                    resetTimeDisplay: .none,
                    timeFormat: .h24,
                    circularDisplayMode: .usage,
                    iconMetric: .fiveHour,
                    colorMode: mode
                ),
                usage: usage,
                error: nil,
                hasAuthError: false,
                hasCredential: true,
                secondaryColor: .secondaryLabelColor,
                icon: nil
            ).color
        }

        // always: 임계값 색상 그대로
        XCTAssertTrue(claudeColor(percentage: 55, mode: .always).isEqual(NSColor.systemYellow))
        // warningOnly: 75 미만은 모노크롬, 이상은 색상
        XCTAssertTrue(claudeColor(percentage: 55, mode: .warningOnly).isEqual(NSColor.labelColor))
        XCTAssertTrue(claudeColor(percentage: 92, mode: .warningOnly).isEqual(NSColor.systemRed))
        // monochrome: 항상 모노크롬
        XCTAssertTrue(claudeColor(percentage: 92, mode: .monochrome).isEqual(NSColor.labelColor))
    }

    func testAntigravityV2HiddenPresentationProducesNoSnapshot() {
        let presentation = makeAntigravityMenuBarPresentation(
            isVisible: false
        )

        XCTAssertNil(
            MenuBarStatusComposer.antigravitySnapshot(
                presentation: presentation,
                icon: NSImage(size: NSSize(width: 18, height: 18))
            )
        )
    }

    func testAntigravityV2SnapshotPreservesPresentationTextAndAccessibility() throws {
        let presentation = makeAntigravityMenuBarPresentation(
            showsProviderIcon: false,
            style: .none,
            regularText: "Claude·GPT · 주간 68% 월요일 09:00",
            condensedText: "68%",
            gaugePercentage: 91,
            showsGaugePercentage: true,
            tooltip: "typed tooltip",
            tone: .warning,
            accessibilityLabel: "typed accessibility label",
            accessibilityValue: "typed accessibility value"
        )
        let snapshot = try XCTUnwrap(
            MenuBarStatusComposer.antigravitySnapshot(
                presentation: presentation,
                icon: NSImage(size: NSSize(width: 18, height: 18))
            )
        )

        XCTAssertEqual(
            snapshot.regularText,
            "Claude·GPT · 주간 68% 월요일 09:00"
        )
        XCTAssertEqual(snapshot.condensedText, "68%")
        XCTAssertEqual(
            snapshot.text,
            "Claude·GPT · 주간 68% 월요일 09:00"
        )
        XCTAssertTrue(snapshot.color.isEqual(NSColor.systemOrange))
        XCTAssertEqual(snapshot.tooltip, "typed tooltip")
        XCTAssertNil(snapshot.icon)
        XCTAssertNil(snapshot.styleIcon)
        XCTAssertNil(snapshot.resetText)
        XCTAssertEqual(
            snapshot.accessibilityLabel,
            "typed accessibility label"
        )
        XCTAssertEqual(
            snapshot.accessibilityValue,
            "typed accessibility value"
        )

        let content = MenuBarStatusComposer.singleProviderContent(
            snapshot: snapshot,
            secondaryColor: .secondaryLabelColor,
            appearance: NSAppearance(named: .aqua)!
        )
        XCTAssertEqual(
            content.accessibilityLabel,
            presentation.accessibilityLabel
        )
        XCTAssertEqual(
            content.accessibilityValue,
            presentation.accessibilityValue
        )
    }

    func testAntigravityV2StaleContentAddsRestrainedVisualAndSpokenMarker() throws {
        let presentation = makeAntigravityMenuBarPresentation(
            showsProviderIcon: false,
            style: .none,
            regularText: "주간 68%",
            condensedText: "68%",
            tooltip: "Antigravity typed tooltip",
            accessibilityValue: "주간, 68퍼센트 사용"
        )
        let freshSnapshot = try XCTUnwrap(
            MenuBarStatusComposer.antigravitySnapshot(
                presentation: presentation,
                context: .init(phase: .current),
                icon: nil
            )
        )
        let staleSnapshot = try XCTUnwrap(
            MenuBarStatusComposer.antigravitySnapshot(
                presentation: presentation,
                context: .init(
                    phase: .stale(
                        .sourceUnavailable(.googleOAuth)
                    )
                ),
                icon: nil
            )
        )
        let appearance = try XCTUnwrap(
            NSAppearance(named: .aqua)
        )
        let freshContent =
            MenuBarStatusComposer.singleProviderContent(
                snapshot: freshSnapshot,
                secondaryColor: .secondaryLabelColor,
                appearance: appearance
            )
        let staleContent =
            MenuBarStatusComposer.singleProviderContent(
                snapshot: staleSnapshot,
                secondaryColor: .secondaryLabelColor,
                appearance: appearance
            )

        XCTAssertFalse(freshSnapshot.isStale)
        XCTAssertTrue(staleSnapshot.isStale)
        XCTAssertGreaterThan(
            staleContent.image.size.width,
            freshContent.image.size.width
        )
        XCTAssertTrue(
            staleContent.tooltip.contains("상태: 이전 데이터")
        )
        XCTAssertTrue(
            staleContent.accessibilityValue?
                .contains("이전 데이터")
                == true
        )
    }

    func testRenderedContentAppliesAndClearsStatusBarAccessibility() throws {
        let statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        defer {
            NSStatusBar.system.removeStatusItem(
                statusItem
            )
        }
        let button = try XCTUnwrap(statusItem.button)
        let content = MenuBarRenderedContent(
            image: NSImage(
                size: NSSize(width: 18, height: 18)
            ),
            tooltip: "tooltip",
            accessibilityLabel: "Antigravity 메뉴 막대 사용량",
            accessibilityValue: "주간, 68퍼센트 사용"
        )

        content.applyAccessibility(to: button)

        XCTAssertEqual(
            button.accessibilityLabel(),
            content.accessibilityLabel
        )
        XCTAssertEqual(
            button.accessibilityValue() as? String,
            content.accessibilityValue
        )

        MenuBarRenderedContent(
            image: content.image,
            tooltip: "placeholder"
        )
        .applyAccessibility(to: button)

        XCTAssertNil(button.accessibilityLabel())
        XCTAssertNil(button.accessibilityValue())
    }

    func testAntigravityV2ToneMapsDirectlyToAppKitColor() throws {
        let cases: [(AntigravityQuotaRiskTone, NSColor)] = [
            (.neutral, .secondaryLabelColor),
            (.healthy, .systemGreen),
            (.attention, .systemYellow),
            (.warning, .systemOrange),
            (.critical, .systemRed),
        ]

        for (tone, expectedColor) in cases {
            let snapshot = try XCTUnwrap(
                MenuBarStatusComposer.antigravitySnapshot(
                    presentation: makeAntigravityMenuBarPresentation(
                        tone: tone
                    ),
                    icon: nil
                )
            )

            XCTAssertTrue(
                snapshot.color.isEqual(expectedColor),
                "Unexpected AppKit color for \(tone)"
            )
        }
    }

    func testAntigravityV2StyleUsesOnlyPresentationGaugeAndIconIntent() throws {
        let providerIcon = NSImage(
            size: NSSize(width: 18, height: 18)
        )
        let batteryWithoutPercentage = try XCTUnwrap(
            MenuBarStatusComposer.antigravitySnapshot(
                presentation: makeAntigravityMenuBarPresentation(
                    style: .batteryBar,
                    gaugePercentage: 37,
                    showsGaugePercentage: false
                ),
                icon: providerIcon
            )
        )
        let batteryWithPercentage = try XCTUnwrap(
            MenuBarStatusComposer.antigravitySnapshot(
                presentation: makeAntigravityMenuBarPresentation(
                    style: .batteryBar,
                    gaugePercentage: 37,
                    showsGaugePercentage: true
                ),
                icon: providerIcon
            )
        )
        let circular37 = try XCTUnwrap(
            MenuBarStatusComposer.antigravitySnapshot(
                presentation: makeAntigravityMenuBarPresentation(
                    style: .circular,
                    gaugePercentage: 37
                ),
                icon: providerIcon
            )
        )
        let circular81 = try XCTUnwrap(
            MenuBarStatusComposer.antigravitySnapshot(
                presentation: makeAntigravityMenuBarPresentation(
                    style: .circular,
                    gaugePercentage: 81
                ),
                icon: providerIcon
            )
        )

        XCTAssertTrue(batteryWithoutPercentage.icon === providerIcon)
        XCTAssertEqual(
            try XCTUnwrap(batteryWithoutPercentage.styleIcon).size,
            NSSize(width: 40, height: 14)
        )
        XCTAssertNotEqual(
            try XCTUnwrap(
                batteryWithoutPercentage.styleIcon?.tiffRepresentation
            ),
            try XCTUnwrap(
                batteryWithPercentage.styleIcon?.tiffRepresentation
            )
        )
        XCTAssertEqual(
            try XCTUnwrap(circular37.styleIcon).size,
            NSSize(width: 20, height: 20)
        )
        XCTAssertNotEqual(
            try XCTUnwrap(circular37.styleIcon?.tiffRepresentation),
            try XCTUnwrap(circular81.styleIcon?.tiffRepresentation)
        )
    }

    func testAntigravityV2SingleAndMultipleContentUseRegularAndCondensedText() throws {
        let presentation = makeAntigravityMenuBarPresentation(
            style: .none,
            regularText: "Claude·GPT · 주간 68% 월요일 09:00",
            condensedText: "68%",
            accessibilityLabel: "Antigravity 사용량",
            accessibilityValue: "Claude·GPT 주간, 68퍼센트 사용"
        )
        let snapshot = try XCTUnwrap(
            MenuBarStatusComposer.antigravitySnapshot(
                presentation: presentation,
                icon: nil
            )
        )
        let appearance = try XCTUnwrap(
            NSAppearance(named: .aqua)
        )
        let single = MenuBarStatusComposer.singleProviderContent(
            snapshot: snapshot,
            secondaryColor: .secondaryLabelColor,
            appearance: appearance
        )
        let multiple = MenuBarStatusComposer.multipleProviderContent(
            snapshots: [snapshot],
            secondaryColor: .secondaryLabelColor,
            appearance: appearance
        )

        XCTAssertGreaterThan(single.image.size.width, multiple.image.size.width)
        XCTAssertEqual(
            multiple.accessibilityLabel,
            presentation.accessibilityLabel
        )
        XCTAssertEqual(
            multiple.accessibilityValue,
            presentation.accessibilityValue
        )
    }

    func testAntigravityV2StyleWithoutGaugeDoesNotSynthesizeZero() throws {
        let snapshot = try XCTUnwrap(
            MenuBarStatusComposer.antigravitySnapshot(
                presentation: makeAntigravityMenuBarPresentation(
                    style: .batteryBar,
                    gaugePercentage: nil
                ),
                icon: nil
            )
        )

        XCTAssertNil(snapshot.styleIcon)
    }

    private func makeAntigravityMenuBarPresentation(
        isVisible: Bool = true,
        showsProviderIcon: Bool = true,
        style: AntigravityDisplaySettings.MenuBarPresentationIntent.Style = .none,
        regularText: String? = "Claude·GPT · 주간 68%",
        condensedText: String? = "68%",
        gaugePercentage: Double? = nil,
        showsGaugePercentage: Bool = true,
        tooltip: String = "Antigravity typed tooltip",
        tone: AntigravityQuotaRiskTone = .healthy,
        accessibilityLabel: String = "Antigravity 메뉴 막대 사용량",
        accessibilityValue: String = "Claude·GPT 주간, 68퍼센트 사용"
    ) -> AntigravityMenuBarQuotaPresentation {
        AntigravityMenuBarQuotaPresentation(
            isVisible: isVisible,
            showsProviderIcon: showsProviderIcon,
            style: style,
            selectedLaneID: .thirdPartyWeekly,
            regularText: regularText,
            condensedText: condensedText,
            gaugePercentage: gaugePercentage,
            showsGaugePercentage: showsGaugePercentage,
            tooltip: tooltip,
            tone: tone,
            accessibilityLabel: accessibilityLabel,
            accessibilityValue: accessibilityValue
        )
    }

    private func codexAssetImage() -> NSImage? {
        let productDirectories = [
            ProcessInfo.processInfo.environment["BUILT_PRODUCTS_DIR"].map(URL.init(fileURLWithPath:)),
            Bundle(for: MenuBarStatusComposerTests.self).bundleURL.deletingLastPathComponent(),
        ].compactMap { $0 }

        for productsDirectory in productDirectories {
            let appBundleURL = productsDirectory
                .appendingPathComponent("ClaudeUsage.app", isDirectory: true)
            if let appBundle = Bundle(url: appBundleURL),
               let image = appBundle.image(forResource: NSImage.Name("ProviderCodexIcon")) {
                return image
            }
        }

        return nil
    }

    private func averageOpaqueLuminance(of image: NSImage) throws -> CGFloat {
        let representation = try XCTUnwrap(
            image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
        )
        var luminance: CGFloat = 0
        var pixelCount: CGFloat = 0

        for y in 0..<representation.pixelsHigh {
            for x in 0..<representation.pixelsWide {
                guard
                    let color = representation.colorAt(x: x, y: y)?
                        .usingColorSpace(.deviceRGB),
                    color.alphaComponent > 0.05
                else {
                    continue
                }
                luminance += (0.2126 * color.redComponent)
                    + (0.7152 * color.greenComponent)
                    + (0.0722 * color.blueComponent)
                pixelCount += 1
            }
        }

        XCTAssertGreaterThan(pixelCount, 0)
        return luminance / max(pixelCount, 1)
    }
}
