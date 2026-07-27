import XCTest
import AppKit
@testable import ClaudeUsage

final class StatusPageInterpreterTests: XCTestCase {
    func testCodexStatusIgnoresUnrelatedOpenAIIncidents() throws {
        let status = try XCTUnwrap(StatusPageInterpreter.parseStatus(
            data: openAIStatusPayload(
                overallIndicator: "major",
                codexComponentStatus: "partial_outage",
                unrelatedComponentStatus: "major_outage",
                codexIncidentImpact: "major",
                unrelatedIncidentImpact: "critical"
            ),
            relevantComponentNames: ["Codex API", "Codex Web", "CLI", "Responses"],
            fallbackDescription: "Codex 상태"
        ))

        XCTAssertEqual(status.indicator, .major)
        XCTAssertEqual(status.activeIncidentCount, 1)
        XCTAssertEqual(status.latestIncident?.name, "Codex API elevated errors")
        XCTAssertEqual(status.degradedComponents, ["Codex API"])
    }

    func testCodexStatusStaysNormalWhenOnlyUnrelatedOpenAIComponentFails() throws {
        let status = try XCTUnwrap(StatusPageInterpreter.parseStatus(
            data: openAIStatusPayload(
                overallIndicator: "major",
                codexComponentStatus: "operational",
                unrelatedComponentStatus: "major_outage",
                codexIncidentImpact: nil,
                unrelatedIncidentImpact: "critical"
            ),
            relevantComponentNames: ["Codex API", "Codex Web", "CLI", "Responses"],
            fallbackDescription: "Codex 상태"
        ))

        XCTAssertEqual(status.indicator, .none)
        XCTAssertFalse(status.hasIssue)
        XCTAssertEqual(status.activeIncidentCount, 0)
        XCTAssertTrue(status.degradedComponents.isEmpty)
    }

    @MainActor
    func testMenuBarTooltipIncludesProviderSystemIssueOnlyWhenPresent() {
        let icon = NSImage(size: NSSize(width: 18, height: 18))
        let status = ProviderSystemStatus(
            indicator: .minor,
            description: "Partial System Outage",
            activeIncidentCount: 1,
            latestIncident: ProviderSystemStatus.IncidentSummary(
                name: "Claude API latency",
                status: "investigating",
                impact: "minor",
                shortlink: nil,
                latestUpdateBody: nil,
                latestUpdateAt: nil,
                affectedComponents: ["API"]
            ),
            degradedComponents: ["API"],
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
        XCTAssertTrue(content.tooltip.contains("Claude 상태: Claude API latency"))
    }
}

private func openAIStatusPayload(
    overallIndicator: String,
    codexComponentStatus: String,
    unrelatedComponentStatus: String,
    codexIncidentImpact: String?,
    unrelatedIncidentImpact: String?
) -> Data {
    let codexIncident = codexIncidentImpact.map {
        incidentJSON(
            name: "Codex API elevated errors",
            impact: $0,
            componentName: "Codex API",
            updatedAt: "2026-04-24T10:00:00Z"
        )
    }
    let unrelatedIncident = unrelatedIncidentImpact.map {
        incidentJSON(
            name: "Image generation outage",
            impact: $0,
            componentName: "Images",
            updatedAt: "2026-04-24T11:00:00Z"
        )
    }
    let incidents = [codexIncident, unrelatedIncident]
        .compactMap { $0 }
        .joined(separator: ",")
    let json = """
    {
      "page": {
        "id": "openai",
        "name": "OpenAI",
        "url": "https://status.openai.com/",
        "updated_at": "2026-04-24T12:00:00Z"
      },
      "status": {
        "description": "Some systems are degraded",
        "indicator": "\(overallIndicator)"
      },
      "components": [
        { "id": "codex-api", "name": "Codex API", "status": "\(codexComponentStatus)" },
        { "id": "codex-web", "name": "Codex Web", "status": "operational" },
        { "id": "cli", "name": "CLI", "status": "operational" },
        { "id": "responses", "name": "Responses", "status": "operational" },
        { "id": "images", "name": "Images", "status": "\(unrelatedComponentStatus)" }
      ],
      "incidents": [\(incidents)]
    }
    """
    return Data(json.utf8)
}

private func incidentJSON(
    name: String,
    impact: String,
    componentName: String,
    updatedAt: String
) -> String {
    """
    {
      "name": "\(name)",
      "status": "investigating",
      "impact": "\(impact)",
      "shortlink": null,
      "updated_at": "\(updatedAt)",
      "components": [
        { "id": "\(componentName)", "name": "\(componentName)", "status": "partial_outage" }
      ],
      "incident_updates": [
        {
          "status": "investigating",
          "body": "Investigating",
          "display_at": "\(updatedAt)",
          "affected_components": [
            { "name": "\(componentName)" }
          ]
        }
      ]
    }
    """
}
