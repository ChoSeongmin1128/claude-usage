import AppKit
import SwiftUI
import XCTest
@testable import ClaudeUsage

@MainActor
final class CommonTimeFormatPropagationTests: XCTestCase {
    func testCatalogPassesTheCommonFormatToClaudeAndCodexRows() throws {
        let suite = "CommonTimeFormatPropagation.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.timeFormat = .remaining
        let claude = try JSONDecoder().decode(
            ClaudeUsageResponse.self,
            from: Data(#"{"five_hour":{"utilization":25,"resets_at":"2030-01-01T00:00:00Z"}}"#.utf8))
        let codex = try JSONDecoder().decode(
            CodexUsageResponse.self,
            from: Data(
                #"{"rate_limit":{"primary_window":{"used_percent":25,"reset_at":1893456000,"limit_window_seconds":18000}}}"#
                    .utf8))
        let context = UsageItemContext(
            density: .compact, settings: settings, claudeUsage: claude, claudeOverage: nil,
            claudeAccounts: [], activeClaudeAccountID: nil, codexUsage: codex, codexError: nil)
        for (service, item) in [(PopoverService.claude, "currentSession"), (.codex, "codexPrimary")] {
            let catalog = try XCTUnwrap(UsageItemCatalogRegistry.catalog(for: service))
            let section = try XCTUnwrap(catalog.section(for: item, context: context))
            guard case .usage(let usage) = section.payload else { return XCTFail("Expected numeric usage row") }
            XCTAssertEqual(usage.timeFormatStyle, .remaining)
        }
    }

    func testTimeFormatObservationReprojectsWithoutRequestingQuota() async throws {
        let suite = "ObservedCommonTimeFormat.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let coordinator = AppRuntimeObservationCoordinator()
        defer { coordinator.cancelAll() }
        var formatChanges = 0
        var refreshChanges = 0
        let changed = expectation(description: "one common formatting change")
        coordinator.bind(
            settings: settings, onRefreshConfigurationChanged: { _ in refreshChanges += 1 },
            onUpdateConfigurationChanged: {}, onMenuBarDisplayChanged: {}, onProviderSelectionChanged: { _ in },
            onClaudeCredentialContextChanged: {},
            onTimeFormatChanged: {
                formatChanges += 1
                changed.fulfill()
            })
        settings.timeFormat = .remaining
        await fulfillment(of: [changed], timeout: 1)
        XCTAssertEqual(formatChanges, 1)
        XCTAssertEqual(refreshChanges, 0)
    }
}

@MainActor
final class TimeFormatterPresentationTests: XCTestCase {
    // Exported production widgets are reviewed manually for names, examples, and clipping.
    // Automatic checks below validate the actual fixture host and capture, not an AppKit backing class.
    func testTimeFormatPickerExamplesVisualGallery() async throws {
        let content = VStack(alignment: .leading, spacing: AppDesign.Space.content) {
            Text("시간 형식").font(AppDesign.Typography.headline)
            ForEach(TimeFormatStyle.allCases, id: \.self) { style in
                TimeFormatPicker(selection: .constant(style))
                    .font(AppDesign.Typography.subheadline)
                    .controlSize(.small)
                    .frame(width: 340)
            }
        }
        .padding(20).frame(width: 380, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.light)
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = []
        let size = controller.sizeThatFits(in: CGSize(width: 2000, height: 2000))
        let window = TimeFormatPickerTestWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        defer { window.orderOut(nil); window.close() }
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = controller
        window.setContentSize(size)
        controller.view.frame = NSRect(origin: .zero, size: size)
        window.orderBack(nil)
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(window.isMainWindow)
        XCTAssertFalse(NSApplication.shared.isActive)
        controller.view.layoutSubtreeIfNeeded()
        controller.view.display()
        window.displayIfNeeded()
        await commitTimeFormatPickerViews()
        controller.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        XCTAssertTrue(controller.view.window === window)
        XCTAssertTrue(window.contentViewController === controller)
        XCTAssertEqual(controller.view.bounds.size, size)
        XCTAssertTrue(window.contentView === controller.view)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, size)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(window.isMainWindow)
        XCTAssertFalse(NSApplication.shared.isActive)
        let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let backingBounds = controller.view.convertToBacking(controller.view.bounds)
        XCTAssertEqual(bitmap.pixelsWide, Int(backingBounds.width.rounded()))
        XCTAssertEqual(bitmap.pixelsHigh, Int(backingBounds.height.rounded()))
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        let name = "Time-format-choices"
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["CLAUDEUSAGE_UI_RENDER_DIRECTORY"] {
            let folder = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: folder.appendingPathComponent(name + ".png"), options: .atomic)
        }
    }

    private func commitTimeFormatPickerViews() async {
        await withCheckedContinuation { continuation in
            let observer = CFRunLoopObserverCreateWithHandler(
                kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max
            ) { _, _ in continuation.resume() }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }
}

@MainActor
private final class TimeFormatPickerTestWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
