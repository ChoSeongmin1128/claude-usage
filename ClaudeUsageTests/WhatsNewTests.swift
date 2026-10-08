import AppKit
import SwiftUI
import XCTest
@testable import ClaudeUsage

final class WhatsNewTests: XCTestCase {
    private func page(_ version: String, _ title: String) -> WhatsNewPage {
        WhatsNewPage(version: version, symbol: "star", title: title, body: title)
    }

    func testPagesAfterLastSeenRunOldestFirstAndStopAtCurrent() {
        let catalog = [page("2.9.0", "B"), page("2.8.0", "A"), page("2.10.0", "C"), page("2.8.0", "A2")]

        XCTAssertEqual(
            WhatsNewCatalog.pagesToShow(after: "2.7.1", upTo: "2.9.0", catalog: catalog).map(\.title), ["A", "A2", "B"])
        XCTAssertEqual(WhatsNewCatalog.pagesToShow(after: "2.9.0", upTo: "2.9.0", catalog: catalog), [])
        XCTAssertEqual(
            WhatsNewCatalog.pagesToShow(after: "2.8.0", upTo: "2.10.0-stg.1", catalog: catalog).map(\.title),
            ["B", "C"])
    }

    func testMoreThanFivePagesFoldIntoOtherChanges() {
        let catalog = (1...7).map { page("2.\($0 + 7).0", "P\($0)") }
        let pages = WhatsNewCatalog.pagesToShow(after: "2.7.0", upTo: "3.0.0", catalog: catalog)

        XCTAssertEqual(pages.count, 5)
        XCTAssertEqual(pages.last?.title, "그 밖의 변경")
        XCTAssertEqual(pages.last?.body, "P5 (2.12.0)\nP6 (2.13.0)\nP7 (2.14.0)")
    }

    func testConditionalNoteJoinsItsPage() {
        let pages = WhatsNewCatalog.pagesToShow(after: "2.7.1", upTo: "2.8.0", notes: [.timeFormatUnified])

        XCTAssertTrue(pages.first { $0.symbol == "clock" }?.body.hasSuffix("Claude 설정 값으로 맞췄습니다.") ?? false)
    }

    func testFreshInstallSkipsCurrentPagesButUpgradeShowsThem() throws {
        let suite = "WhatsNewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        WhatsNewState.prepare(defaults: defaults, isExistingInstall: false, currentVersion: "2.8.0")
        XCTAssertEqual(WhatsNewState.lastSeen(defaults: defaults), "2.8.0")

        defaults.removeObject(forKey: WhatsNewState.lastSeenKey)
        WhatsNewState.prepare(defaults: defaults, isExistingInstall: true, currentVersion: "2.8.0")
        XCTAssertFalse(
            WhatsNewCatalog.pagesToShow(after: WhatsNewState.lastSeen(defaults: defaults), upTo: "2.8.0").isEmpty)

        UpdateNotesQueue.enqueue(.timeFormatUnified, defaults: defaults)
        WhatsNewState.markSeen("2.8.0", defaults: defaults)
        XCTAssertEqual(WhatsNewState.lastSeen(defaults: defaults), "2.8.0")
        XCTAssertTrue(UpdateNotesQueue.pending(defaults: defaults).isEmpty)
    }

    func testLatestPagesForReplay() {
        let catalog = [page("2.8.0", "A"), page("2.9.0", "B"), page("2.11.0", "C")]
        XCTAssertEqual(WhatsNewCatalog.latestPages(upTo: "2.10.0", catalog: catalog).map(\.title), ["B"])
    }

    @MainActor
    func testMultiGaugeGuideOpensTheMenuBarEditor() throws {
        let page = try XCTUnwrap(WhatsNewCatalog.pages.first { $0.version == "2.9.0" })
        XCTAssertEqual(page.action, .openSettings(.claude, section: .menuBar))
        XCTAssertTrue(page.body.contains("메뉴바 표시"))
        XCTAssertFalse(page.body.contains("이름을 붙여 가로로 표시"))
    }

    @MainActor
    func testSettingsActionPreservesWhatsNewWindowAndPendingNotesUntilClose() throws {
        let suite = "WhatsNewTests.window.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        WhatsNewState.prepare(defaults: defaults, isExistingInstall: false, currentVersion: "2.7.0")
        UpdateNotesQueue.enqueue(.timeFormatUnified, defaults: defaults)
        let coordinator = WhatsNewWindowCoordinator()
        var actions: [WhatsNewPage.Action] = []
        var closeCount = 0
        coordinator.present(
            pages: WhatsNewCatalog.latestPages(upTo: "2.8.0"), toggle: { _ in nil },
            onAction: { actions.append($0) },
            onClose: {
                closeCount += 1
                WhatsNewState.markSeen("2.8.0", defaults: defaults)
            })
        defer { coordinator.close() }
        let window = try XCTUnwrap(coordinator.window)
        let controller = try XCTUnwrap(window.contentViewController)
        coordinator.performAction(.openSettings(.common))

        XCTAssertEqual(actions, [.openSettings(.common)])
        XCTAssertTrue(coordinator.window === window)
        XCTAssertTrue(window.contentViewController === controller)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(closeCount, 0)
        XCTAssertEqual(WhatsNewState.lastSeen(defaults: defaults), "2.7.0")
        XCTAssertEqual(UpdateNotesQueue.pending(defaults: defaults), [.timeFormatUnified])

        window.orderOut(nil)
        XCTAssertFalse(window.isVisible)
        coordinator.present(
            pages: [page("2.8.0", "replacement")], toggle: { _ in nil },
            onAction: { _ in XCTFail("The open window must keep its original callbacks") },
            onClose: { XCTFail("The open window must keep its original close callback") })
        XCTAssertTrue(coordinator.window === window)
        XCTAssertTrue(window.contentViewController === controller)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(closeCount, 0)

        coordinator.close()
        XCTAssertNil(coordinator.window)
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(WhatsNewState.lastSeen(defaults: defaults), "2.8.0")
        XCTAssertTrue(UpdateNotesQueue.pending(defaults: defaults).isEmpty)
    }

    func testBundledHistoryContainsCurrentAndPreviousReleaseNotes() throws {
        let notes = BundledReleaseNotes.load(
            bundle: try BuiltAppTestResources.bundle(relativeTo: Self.self), upTo: "2.8.0")
        XCTAssertEqual(notes.first?.version, "2.8.0")
        XCTAssertEqual(notes.last?.version, "2.4.15")
        XCTAssertEqual(notes.count, 8)
        XCTAssertTrue(notes.contains { $0.version == "2.7.0" })
        XCTAssertTrue(notes.allSatisfy { !$0.blocks.isEmpty })
    }

    func testLocalHistorySortsNumericallyAndDoesNotShowFutureOrInvalidNotes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WhatsNewTests.\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for version in ["2.8.0", "2.9.0", "2.10.0"] {
            try "# \(version)\n\n- Fixture".write(
                to: folder.appendingPathComponent("\(version).md"), atomically: true, encoding: .utf8)
        }
        try "ignored".write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "".write(to: folder.appendingPathComponent("2.7.0.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(
            BundledReleaseNotes.load(directory: folder, upTo: "2.10.0-stg.8").map(\.version),
            ["2.10.0", "2.9.0", "2.8.0"])
        XCTAssertEqual(
            BundledReleaseNotes.load(directory: folder, upTo: "2.8.0").map(\.version), ["2.8.0"])
        XCTAssertTrue(
            BundledReleaseNotes.load(directory: folder.appendingPathComponent("missing"), upTo: "2.8.0").isEmpty)
    }

    func testMarkdownHistorySeparatesHeadingsAndItemsWithoutShowingBlockMarkers() {
        let note = BundledReleaseNote(
            version: "2.8.0",
            markdown: "# 2.8.0\n\n## 화면\n\n- **첫 변경**\n- `설정` 열기\n\n추가 설명")
        XCTAssertEqual(note.blocks.map(\.kind), [.heading, .bullet, .bullet, .paragraph])
        XCTAssertEqual(note.blocks.map(\.text), ["화면", "**첫 변경**", "`설정` 열기", "추가 설명"])
        XCTAssertEqual(note.blocks.map(\.id), [0, 1, 2, 3])
    }
}

nonisolated enum BuiltAppTestResources {
    static func bundle(relativeTo testClass: AnyClass) throws -> Bundle {
        var directories = [
            ProcessInfo.processInfo.environment["BUILT_PRODUCTS_DIR"].map(URL.init(fileURLWithPath:))
        ].compactMap { $0 }
        var ancestor = Bundle(for: testClass).bundleURL
        for _ in 0..<4 {
            ancestor.deleteLastPathComponent()
            directories.append(ancestor)
        }
        for directory in directories {
            let products =
                (try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil)) ?? []
            for product in products where product.pathExtension == "app" {
                if let bundle = Bundle(url: product),
                    [AppIdentifiers.productionBundleIdentifier, AppIdentifiers.stagingBundleIdentifier]
                        .contains(bundle.bundleIdentifier ?? "")
                {
                    return bundle
                }
            }
        }
        throw NSError(
            domain: "BuiltAppTestResources", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "빌드한 앱 번들을 찾지 못했습니다"])
    }
}
