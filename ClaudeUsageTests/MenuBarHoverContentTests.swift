import AppKit
import SwiftUI
import XCTest
@testable import ClaudeUsage

@MainActor
final class MenuBarHoverContentTests: XCTestCase {
    func testDefaultTableUsesTheActualBasisAndAgyDoesNotBreakColumns() throws {
        try withSettings { settings, _ in
            settings.usageDisplayMode = .remaining
            let provider = try XCTUnwrap(
                MenuBarHoverUsageContent.catalogProvider(snapshot: self.snapshot(), settings: settings))
            XCTAssertEqual(provider.items.map(\.value), ["75%", "60%"])
            XCTAssertTrue(MenuBarHoverUsageContent(providers: [provider]).usesCommonColumns)
            let agy = MenuBarHoverUsageContent.Provider(
                kind: .antigravity, basis: .remaining,
                items: [
                    .init(id: "gemini.5h", title: "Gemini 5시간", compactTitle: "Gemini 5시간", value: "42%")
                ])
            let combined = MenuBarHoverUsageContent(providers: [provider, agy])
            XCTAssertTrue(combined.usesCommonColumns)
            XCTAssertEqual(combined.catalogProviders, [provider])
            XCTAssertEqual(combined.listProviders, [agy])
            settings.usageDisplayMode = .used
            XCTAssertEqual(
                MenuBarHoverUsageContent.catalogProvider(snapshot: self.snapshot(), settings: settings)?.items.map(
                    \.value), ["25%", "40%"])
        }
    }

    func testMissingFieldStaysUnknownAndCustomOrderStaysInAList() throws {
        try withSettings { settings, _ in
            let onlyWeekly = ClaudeUsageResponse(fiveHour: nil, sevenDay: UsageWindow(utilization: 40, resetsAt: nil))
            let provider = try XCTUnwrap(
                MenuBarHoverUsageContent.catalogProvider(snapshot: self.snapshot(usage: onlyWeekly), settings: settings)
            )
            XCTAssertEqual(provider.items[0].value, "미확인")
            XCTAssertTrue(provider.items[0].isUnknown)
            XCTAssertNotEqual(provider.items[0].value, provider.items[1].value)
            let reordered = [
                PopoverItemConfig(id: "weeklyLimit", visible: true), .init(id: "currentSession", visible: true),
            ]
            try settings.setDisplayItems(reordered, for: .claude, surface: .hover)
            let custom = try XCTUnwrap(
                MenuBarHoverUsageContent.catalogProvider(snapshot: self.snapshot(), settings: settings))
            XCTAssertEqual(custom.items.map(\.id), ["weeklyLimit", "currentSession"])
            XCTAssertFalse(MenuBarHoverUsageContent(providers: [custom]).usesCommonColumns)
        }
    }

    func testFetchFailureKeepsPreviousValuesAndHoverDoesNotWrite() throws {
        try withSettings { settings, defaults in
            let before = defaults.dictionaryRepresentation() as NSDictionary
            let previous = try XCTUnwrap(
                MenuBarHoverUsageContent.catalogProvider(
                    snapshot: self.snapshot(error: .networkError("fixture connection failure")), settings: settings))
            XCTAssertEqual(previous.stateText, "조회 실패 / 이전 값")
            XCTAssertEqual(previous.items.count, 2)
            XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
        }
    }

    func testAccessibilityHelpIncludesEveryHoverItemWithItsUnitAndState() throws {
        try withSettings { settings, _ in
            settings.usageDisplayMode = .remaining
            let provider = try XCTUnwrap(
                MenuBarHoverUsageContent.catalogProvider(
                    snapshot: self.snapshot(error: .networkError("fixture failure")), settings: settings))
            let content = ServiceStatusPanelContent(services: [], usage: .init(providers: [provider]))
            XCTAssertTrue(content.accessibilitySummary.contains("5시간 한도 75% 남음"))
            XCTAssertTrue(content.accessibilitySummary.contains("주간 한도 60% 남음"))
            XCTAssertTrue(content.accessibilitySummary.contains("조회 실패 / 이전 값"))
        }
    }

    func testProductHoverRendersOffscreenInBothAppearances() throws {
        try withSettings { settings, _ in
            settings.usageDisplayMode = .remaining
            var provider = try XCTUnwrap(
                MenuBarHoverUsageContent.catalogProvider(snapshot: self.snapshot(), settings: settings))
            provider.serviceTone = .normal
            let normal = ServiceStatusPanelContent(services: [], usage: .init(providers: [provider]))
            let incident = ProviderSystemStatus.IncidentSummary(
                name: "서비스별 모델의 응답 오류율 증가", status: "monitoring", impact: "major", shortlink: nil,
                latestUpdateBody: nil, latestUpdateAt: Date(), affectedComponents: ["Claude Code", "Claude API"],
                isPriority: true)
            let issue = ProviderSystemStatus(
                indicator: .major, description: "", activeIncidents: [incident], pageUpdatedAt: nil)
            let busy = try XCTUnwrap(
                ServiceStatusPanelContent.make(statuses: [.claude: issue], usage: .init(providers: [provider])))
            let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".work/product-hover-render")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
                for (name, content) in [("normal", normal), ("incident", busy)] {
                    let host = NSHostingView(
                        rootView: ServiceStatusPanelView(content: content)
                            .background(Color(nsColor: .windowBackgroundColor))
                            .environment(\.colorScheme, appearance == .aqua ? .light : .dark))
                    host.appearance = NSAppearance(named: appearance)
                    let size = host.fittingSize
                    host.frame = NSRect(origin: .zero, size: size)
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let image = NSImage(size: size)
                    image.addRepresentation(bitmap)
                    XCTAssertEqual(size.width, AppDesign.Hover.width)
                    XCTAssertGreaterThan(size.height, 20)
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "Hover \(name) \(appearance.rawValue) offscreen"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try data.write(
                        to: directory.appendingPathComponent("\(name)-\(appearance == .aqua ? "light" : "dark").png"))
                }
            }
        }
    }

    private func snapshot(usage: ClaudeUsageResponse? = nil, error: APIError? = nil) -> RuntimeProviderSnapshot {
        RuntimeProviderSnapshot(
            service: .claude,
            payload: .claude(
                usage
                    ?? ClaudeUsageResponse(
                        fiveHour: UsageWindow(utilization: 25, resetsAt: nil),
                        sevenDay: UsageWindow(utilization: 40, resetsAt: nil))),
            error: error, credentialState: .usable, isDetected: true, canAttemptRefresh: true, hasAuthError: false)
    }

    private func withSettings(_ action: (AppSettings, UserDefaults) throws -> Void) throws {
        let suite = "MenuBarHoverContentTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(
            defaults: defaults, hasExistingAccountStorage: false,
            launchAtLoginController: LaunchAtLoginController(service: HoverTestLoginService()))
        try action(settings, defaults)
    }
}

private struct HoverTestLoginService: LoginItemManaging {
    var status: LoginItemStatus { .notRegistered }
    func register() throws { XCTFail("Fixture must not change login items") }
    func unregister() throws { XCTFail("Fixture must not change login items") }
    func openSystemSettings() { XCTFail("Fixture must not open settings") }
}
