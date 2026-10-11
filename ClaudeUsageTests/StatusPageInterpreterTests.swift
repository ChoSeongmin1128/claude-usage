import XCTest
import AppKit
@testable import ClaudeUsage

final class StatusPageInterpreterTests: XCTestCase {
    func testClaudeSummaryUsesWholePageAndWorstState() throws {
        let status = try XCTUnwrap(
            StatusPageInterpreter.parseStatus(data: try fixture("claude-summary.json"), priorityRule: .claude))

        // monitoring 중인 장애의 영향은 major지만 페이지가 minor로 매겼으므로 머리 상태도 minor다.
        XCTAssertEqual(status.indicator, .minor)
        XCTAssertEqual(status.effectiveIndicator, .minor)
        XCTAssertEqual(status.description, "Partially Degraded Service")
        XCTAssertEqual(status.activeIncidents.map(\.name), ["Elevated errors on platform.claude.com"])
        XCTAssertEqual(status.activeIncidents.first?.affectedComponents, ["Claude Console (platform.claude.com)"])
        XCTAssertEqual(status.activeIncidents.first?.isPriority, false)
        XCTAssertEqual(
            status.activeIncidents.first?.latestUpdateAt, ISO8601DateFormatter.fractional("2026-10-07T21:44:41.466Z"))
        XCTAssertEqual(
            status.componentIssues,
            [.init(name: "Claude Console (platform.claude.com)", indicator: .minor)])
    }

    func testOpenAISummaryIsReadWithoutCodexComponentFilter() throws {
        let status = try XCTUnwrap(
            StatusPageInterpreter.parseStatus(data: try fixture("openai-summary.json"), priorityRule: .codex))

        XCTAssertEqual(status.indicator, .minor)
        XCTAssertEqual(status.activeIncidents.map(\.name), ["Delayed Costs data in the Compliance API"])
        XCTAssertEqual(status.activeIncidents.first?.affectedComponents, [])
        XCTAssertEqual(status.activeIncidents.first?.isPriority, false)
        XCTAssertEqual(status.componentIssues, [.init(name: "Compliance API", indicator: .minor)])
        XCTAssertTrue(status.hasIssue)
    }

    func testHeaderStateFollowsThePageAndFallsBackToWorstOnlyWhenThePageHasNone() throws {
        let pageMinor = try makeStatus(
            pageIndicator: "minor",
            components: [("Images", "major_outage")],
            incidents: [incidentJSON("Images slow", impact: "major")])
        XCTAssertEqual(pageMinor.indicator, .minor)

        let pageNoneWithIncident = try makeStatus(
            pageIndicator: "none", components: [], incidents: [incidentJSON("Login errors", impact: "major")])
        XCTAssertEqual(pageNoneWithIncident.indicator, .none)
        XCTAssertEqual(pageNoneWithIncident.effectiveIndicator, .minor, "장애가 있으면 정상으로 보이지 않습니다")

        let pageWorst = try makeStatus(pageIndicator: "critical", components: [], incidents: [])
        XCTAssertEqual(pageWorst.indicator, .critical)
        XCTAssertEqual(pageWorst.effectiveIndicator, .critical)

        let unknownPage = try makeStatus(
            pageIndicator: "unexpected",
            components: [("Images", "major_outage")],
            incidents: [incidentJSON("Login errors", impact: "major")])
        XCTAssertEqual(unknownPage.indicator, .critical)

        let incidentWithoutImpact = try makeStatus(
            pageIndicator: "none", components: [], incidents: [incidentJSON("Billing delays", impact: "none")])
        XCTAssertEqual(incidentWithoutImpact.indicator, .none)
        XCTAssertEqual(incidentWithoutImpact.effectiveIndicator, .minor)
    }

    func testClaudePriorityUsesProductComponentsAndOrdersThemFirst() throws {
        let status = try XCTUnwrap(
            StatusPageInterpreter.parseStatus(
                data: try activeIncidentsPage(fromFixture: "claude-incidents.json"), priorityRule: .claude))

        let nonPriority = status.activeIncidents.filter { !$0.isPriority }.map(\.name)
        XCTAssertEqual(
            nonPriority,
            [
                "Elevated errors on platform.claude.com",
                "Issue with spend limits",
                "Elevated errors loading usage data on platform.claude.com",
                "Issues with Google Play subscriptions",
                "Degraded functionality for Claude Cowork on Windows",
                "Delays in credit purchases",
                "Issues reaching status.claude.com",
            ])
        XCTAssertEqual(status.activeIncidents.count, 50)
        assertPriorityFirstThenNewest(status.activeIncidents)

        let byTitle = Dictionary(
            status.activeIncidents.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        // Cowork만 걸렸지만 제목에 Claude Code가 있다.
        XCTAssertEqual(byTitle["Service disruption on Claude Code on the web and related services"]?.isPriority, true)
        XCTAssertEqual(byTitle["Issues logging into Claude.ai"]?.isPriority, true)
        // incident의 components는 비었지만 update에 Claude API와 Claude Code가 나온다.
        let emptyComponents = try XCTUnwrap(byTitle["Elevated errors across all models"])
        XCTAssertTrue(emptyComponents.isPriority)
        XCTAssertEqual(
            Set(emptyComponents.affectedComponents),
            ["claude.ai", "Claude API (api.anthropic.com)", "Claude Code", "Claude Cowork"])
    }

    func testCodexPriorityUsesTitlesWhenOpenAIIncidentsHaveNoComponents() throws {
        let status = try XCTUnwrap(
            StatusPageInterpreter.parseStatus(
                data: try activeIncidentsPage(fromFixture: "openai-incidents.json"), priorityRule: .codex))

        XCTAssertEqual(
            status.activeIncidents.filter(\.isPriority).map(\.name),
            [
                "Some APAC users are seeing errors in ChatGPT Work, conversations, and GPTs.",
                "Degraded performance in Codex and Work mode: Dot turn failures, delayed responses, and reduced proactivity",
                "Dot in Codex may fail to create new threads",
                "Unable to create new ChatGPT Work threads in latest version of desktop app",
                "Elevated errors across ChatGPT, Codex, and the API including the Agents API",
                "Elevated Work Mode errors",
                "Elevated error rates in Codex Cloud",
            ])
        XCTAssertEqual(status.activeIncidents.count, 25)
        assertPriorityFirstThenNewest(status.activeIncidents)
    }

    func testCodexPriorityUsesCodexAndChatGPTWorkComponents() throws {
        let status = try makeStatus(
            pageIndicator: "minor",
            components: [],
            incidents: [
                incidentJSON(
                    "Elevated errors", components: ["Codex in ChatGPT Desktop"], updatedAt: "2026-10-11T01:00:00Z"),
                incidentJSON("Slow responses", components: ["ChatGPT Work"], updatedAt: "2026-10-11T02:00:00Z"),
                incidentJSON("Image errors", components: ["Images"], updatedAt: "2026-10-11T03:00:00Z"),
            ],
            priorityRule: .codex)

        XCTAssertEqual(status.activeIncidents.map(\.name), ["Slow responses", "Elevated errors", "Image errors"])
        XCTAssertEqual(status.activeIncidents.map(\.isPriority), [true, true, false])
    }

    func testCodexPriorityDoesNotMatchWorkOrCLIInsideOtherWords() {
        let rule = StatusIncidentPriorityRule.codex
        for title in [
            "Login not working for some users",
            "Desktop client fails to start",
            "Workspace admins may be unable to manage plugins",
            "Errors in ChatGPT Workspace settings",
            "Elevated errors with CLI tools",
        ] {
            XCTAssertFalse(rule.isPriority(title: title, componentNames: []), title)
        }
        XCTAssertFalse(rule.isPriority(title: "Errors", componentNames: ["ChatGPT Workspace", "CLI", "Responses"]))
        XCTAssertTrue(rule.isPriority(title: "codex cli login errors", componentNames: []))
        XCTAssertTrue(rule.isPriority(title: "Elevated WORK MODE errors", componentNames: []))
    }

    func testClaudePriorityMatchesExactComponentsAndAPIPrefix() {
        let rule = StatusIncidentPriorityRule.claude
        XCTAssertTrue(rule.isPriority(title: "Errors", componentNames: ["Claude API (api.anthropic.com)"]))
        XCTAssertTrue(rule.isPriority(title: "Errors", componentNames: ["claude.ai"]))
        XCTAssertTrue(rule.isPriority(title: "Errors", componentNames: ["Claude Code"]))
        XCTAssertFalse(rule.isPriority(title: "Errors", componentNames: ["Claude Console (platform.claude.com)"]))
        XCTAssertFalse(rule.isPriority(title: "Errors", componentNames: ["Claude Cowork", "Claude for Government"]))
        XCTAssertFalse(rule.isPriority(title: "Elevated errors on platform.claude.com", componentNames: []))
    }

    func testDegradedComponentsWithoutIncidentsKeepWorstStatePerName() throws {
        let status = try makeStatus(
            pageIndicator: "minor",
            components: [
                ("Login", "degraded_performance"),
                ("Codex in ChatGPT Desktop", "partial_outage"),
                ("Login", "major_outage"),
                ("Images", "operational"),
                ("Batch", "under_maintenance"),
            ],
            incidents: [])

        XCTAssertTrue(status.activeIncidents.isEmpty)
        XCTAssertEqual(
            status.componentIssues,
            [
                .init(name: "Login", indicator: .critical),
                .init(name: "Codex in ChatGPT Desktop", indicator: .major),
                .init(name: "Batch", indicator: .minor),
            ])
        // 구성 요소가 더 나빠도 머리 상태는 페이지가 매긴 값이다.
        XCTAssertEqual(status.indicator, .minor)
        XCTAssertEqual(status.menuBarSummary, "Login, Codex in ChatGPT Desktop 일부 성능 저하")
    }

    func testResolvedIncidentsLeftInSummaryAreNotActive() throws {
        let status = try makeStatus(
            pageIndicator: "none",
            components: [],
            incidents: [
                incidentJSON("Old outage", impact: "critical", status: "resolved"),
                incidentJSON("Postmortem", impact: "major", status: "postmortem"),
            ])

        XCTAssertTrue(status.activeIncidents.isEmpty)
        XCTAssertEqual(status.indicator, .none)
        XCTAssertFalse(status.hasIssue)
    }

    func testSummaryWithoutIncidentsAndUpdatesWithoutComponentsStillParse() throws {
        let summary = Data(
            #"""
            {"page":{"updated_at":"2026-10-04T00:00:00Z"},"status":{"indicator":"none","description":"All Systems Operational"},
             "components":[{"name":"Codex API","status":"operational"}]}
            """#.utf8)
        let withNullComponents = Data(
            #"""
            {"page":{},"status":{"indicator":"minor","description":"Minor"},"components":[],
             "incidents":[{"name":"Login errors","status":"investigating","impact":"minor","updated_at":"2026-10-04T00:00:00Z",
               "incident_updates":[{"status":"investigating","body":"Looking","display_at":null,"affected_components":null}]}]}
            """#.utf8)

        let normal = try XCTUnwrap(StatusPageInterpreter.parseStatus(data: summary, priorityRule: .codex))
        XCTAssertFalse(normal.hasIssue)
        let parsed = try XCTUnwrap(StatusPageInterpreter.parseStatus(data: withNullComponents, priorityRule: .codex))
        XCTAssertEqual(parsed.activeIncidents.map(\.name), ["Login errors"])
        XCTAssertEqual(parsed.activeIncidents.first?.latestUpdateAt, ISO8601DateFormatter.plain("2026-10-04T00:00:00Z"))
    }

    @MainActor
    func testMenuBarBadgesProviderSystemIssueAndLeavesTextToStatusPanel() {
        let icon = NSImage(size: NSSize(width: 18, height: 18))
        let status = ProviderSystemStatus(
            indicator: .minor,
            description: "Partial System Outage",
            activeIncidents: [
                ProviderSystemStatus.IncidentSummary(
                    name: "Claude API latency",
                    status: "investigating",
                    impact: "minor",
                    shortlink: nil,
                    latestUpdateBody: nil,
                    latestUpdateAt: nil,
                    affectedComponents: ["API"]
                )
            ],
            componentIssues: [.init(name: "API", indicator: .minor)],
            pageUpdatedAt: nil
        )
        let snapshot = MenuBarProviderSnapshot(
            kind: .claude,
            text: "51%",
            color: .labelColor,
            tooltip: "현재 51% / 주간 72%",
            icon: icon,
            styleIcon: nil,
            resetText: "3h",
            systemStatus: status
        )

        let content = MenuBarStatusComposer.singleProviderContent(
            snapshot: snapshot,
            secondaryColor: .secondaryLabelColor,
            appearance: NSAppearance(named: .aqua)!
        )

        XCTAssertGreaterThan(content.image.size.width, icon.size.width)
        XCTAssertEqual(content.image.size.height, 22)
        // 장애 문구는 서비스 상태 패널과 버튼의 접근성 도움말이 맡는다.
        XCTAssertFalse(content.tooltip.contains("서비스 상태"))
    }

    @MainActor
    func testPlaceholderKeepsAnAccessibleNameWithoutTooltip() {
        let content = MenuBarStatusComposer.placeholder(secondaryColor: .secondaryLabelColor)

        XCTAssertEqual(content.accessibilityLabel, AppDistribution.current.appName)
    }
}

private func fixture(_ name: String) throws -> Data {
    try Data(
        contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/StatusPage/\(name)"))
}

/// incidents.json에는 해결된 장애와 페이지 상태가 없다. 분류 규칙을 실제 제목과 구성 요소로 확인하려고
/// 모든 장애를 진행 중으로 바꾸고 정상 페이지 상태를 붙인다.
private func activeIncidentsPage(fromFixture name: String) throws -> Data {
    var page = try XCTUnwrap(JSONSerialization.jsonObject(with: try fixture(name)) as? [String: Any])
    let incidents = try XCTUnwrap(page["incidents"] as? [[String: Any]])
    page["incidents"] = incidents.map { incident in
        var active = incident
        active["status"] = "investigating"
        return active
    }
    page["status"] = ["indicator": "none", "description": "All Systems Operational"]
    return try JSONSerialization.data(withJSONObject: page)
}

private func assertPriorityFirstThenNewest(
    _ incidents: [ProviderSystemStatus.IncidentSummary],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let firstNonPriority = incidents.firstIndex { !$0.isPriority } ?? incidents.endIndex
    XCTAssertFalse(incidents[firstNonPriority...].contains(where: \.isPriority), file: file, line: line)
    for group in [incidents[..<firstNonPriority], incidents[firstNonPriority...]] {
        let dates = group.map { $0.latestUpdateAt ?? .distantPast }
        XCTAssertEqual(dates, dates.sorted(by: >), file: file, line: line)
    }
}

private func makeStatus(
    pageIndicator: String,
    components: [(name: String, status: String)],
    incidents: [String],
    priorityRule: StatusIncidentPriorityRule = .claude
) throws -> ProviderSystemStatus {
    let componentJSON = components.map { #"{"name":"\#($0.name)","status":"\#($0.status)"}"# }
    let json = """
        {"page":{"updated_at":"2026-10-11T00:00:00Z"},
         "status":{"indicator":"\(pageIndicator)","description":"fixture"},
         "components":[\(componentJSON.joined(separator: ","))],
         "incidents":[\(incidents.joined(separator: ","))]}
        """
    return try XCTUnwrap(StatusPageInterpreter.parseStatus(data: Data(json.utf8), priorityRule: priorityRule))
}

private func incidentJSON(
    _ name: String,
    impact: String = "minor",
    status: String = "investigating",
    components: [String] = [],
    updatedAt: String = "2026-10-11T00:00:00Z"
) -> String {
    let componentJSON = components.map { #"{"name":"\#($0)","status":"partial_outage"}"# }
    let affectedJSON = components.map { #"{"name":"\#($0)"}"# }
    return """
        {"name":"\(name)","status":"\(status)","impact":"\(impact)","shortlink":null,"updated_at":"\(updatedAt)",
         "components":[\(componentJSON.joined(separator: ","))],
         "incident_updates":[{"status":"\(status)","body":"Investigating","display_at":"\(updatedAt)",
           "affected_components":[\(affectedJSON.joined(separator: ","))]}]}
        """
}

extension ISO8601DateFormatter {
    fileprivate static func fractional(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw)
    }

    fileprivate static func plain(_ raw: String) -> Date? {
        ISO8601DateFormatter().date(from: raw)
    }
}
