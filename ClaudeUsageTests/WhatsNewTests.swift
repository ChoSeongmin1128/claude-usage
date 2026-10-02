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

        XCTAssertTrue(pages.first { $0.title == "남은 시간 1:23 형식" }?.body.hasSuffix("Claude 설정 값으로 맞췄습니다.") ?? false)
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
}
