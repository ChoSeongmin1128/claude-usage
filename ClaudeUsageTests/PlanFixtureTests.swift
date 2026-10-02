import AppKit
import XCTest
@testable import ClaudeUsage

/// Fixtures/Plans의 요금제별 응답을 디코딩해 화면에 보일 한도 행과 메뉴바 값을 기대 결과와 비교한다.
/// 표시 동작이 바뀌면 fixture의 expected를 고쳐야 하므로 변화가 diff로 드러난다.
@MainActor
final class PlanFixtureTests: XCTestCase {
    private static let plansDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Plans")

    func testClaudePlanFixtures() throws {
        for fixture in try Self.fixtures(provider: "claude") {
            let decoded = Result { try JSONDecoder().decode(ClaudeUsageResponse.self, from: fixture.response) }
            if fixture.expectsDecodeError {
                XCTAssertThrowsError(try decoded.get(), fixture.name)
                continue
            }
            let usage = try decoded.get()
            var actual: [String: Any] = [
                "rows": Self.rows(UsageLimitCatalog.claude(usage)),
                "menuBar": Dictionary(
                    uniqueKeysWithValues: Self.displays.map { key, display in
                        (key, Self.claudeMenuBarText(usage, display: display))
                    }),
            ]
            actual = actual.filter { fixture.expected[$0.key] != nil }
            XCTAssertEqual(NSDictionary(dictionary: actual), NSDictionary(dictionary: fixture.expected), fixture.name)
        }
    }

    func testCodexPlanFixtures() throws {
        for fixture in try Self.fixtures(provider: "codex") {
            let decoded = Result { try JSONDecoder().decode(CodexUsageResponse.self, from: fixture.response) }
            if fixture.expectsDecodeError {
                XCTAssertThrowsError(try decoded.get(), fixture.name)
                continue
            }
            let usage = try decoded.get()
            var actual: [String: Any] = [
                "rows": Self.rows(UsageLimitCatalog.codex(usage)),
                "menuBar": Dictionary(
                    uniqueKeysWithValues: Self.displays.map { key, display in
                        (key, Self.codexMenuBarText(usage, display: display))
                    }),
            ]
            if let credits = usage.credits { actual["credits"] = credits.formattedBalance }
            if let percent = usage.spendControl?.individualLimit?.usedPercent { actual["spendLimit"] = Int(percent) }
            if let notice = usage.workspaceLimitNotice { actual["notice"] = notice }
            actual = actual.filter { fixture.expected[$0.key] != nil }
            XCTAssertEqual(NSDictionary(dictionary: actual), NSDictionary(dictionary: fixture.expected), fixture.name)
        }
    }

    private struct Fixture {
        let name: String
        let response: Data
        let expected: [String: Any]
        var expectsDecodeError: Bool { expected["decodeError"] as? Bool == true }
    }

    private static let displays: [(String, PercentageDisplay)] = [
        ("fiveHour", .fiveHour), ("weekly", .weekly), ("dual", .dual),
    ]

    private static func fixtures(provider: String) throws -> [Fixture] {
        let directory = plansDirectory.appendingPathComponent(provider)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(files.isEmpty, "no \(provider) plan fixtures")
        return try files.map { url in
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], url.lastPathComponent)
            let response = try JSONSerialization.data(withJSONObject: XCTUnwrap(object["response"]))
            let expected = try XCTUnwrap(object["expected"] as? [String: Any], url.lastPathComponent)
            return Fixture(name: url.lastPathComponent, response: response, expected: expected)
        }
    }

    private static func rows(_ limits: [UsageLimit]) -> [String] {
        limits.map { limit in
            "\(limit.title)=\(limit.usedPercentage.map { String(Int($0.rounded())) } ?? "nil")"
        }
    }

    private static func config(_ kind: AppProviderKind, display: PercentageDisplay) -> ProviderMenuBarDisplayConfig {
        ProviderMenuBarDisplayConfig(
            kind: kind, showIcon: false, style: .none, percentageDisplay: display, showBatteryPercent: false,
            resetTimeDisplay: .none, timeFormat: .h24, circularDisplayMode: .usage, iconMetric: .fiveHour,
            colorMode: .always)
    }

    private static func claudeMenuBarText(_ usage: ClaudeUsageResponse, display: PercentageDisplay) -> String {
        MenuBarStatusComposer.claudeSnapshot(
            config: config(.claude, display: display), usage: usage, error: nil, hasAuthError: false,
            hasCredential: true, secondaryColor: .secondaryLabelColor, icon: nil, renderImages: false
        ).text
    }

    private static func codexMenuBarText(_ usage: CodexUsageResponse, display: PercentageDisplay) -> String {
        MenuBarStatusComposer.codexSnapshot(
            config: config(.codex, display: display), usage: usage, error: nil, hasAuthError: false,
            isAuthenticated: true, secondaryColor: .secondaryLabelColor, icon: nil, renderImages: false
        ).text
    }
}
