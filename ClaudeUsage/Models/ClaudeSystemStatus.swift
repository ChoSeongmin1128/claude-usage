//
//  ClaudeSystemStatus.swift
//  ClaudeUsage
//
//  Provider 시스템 상태 모델 (Statuspage API)
//

import Foundation

enum StatusIndicator: String, Codable, Sendable {
    case none       // 정상
    case minor      // 경미한 장애
    case major      // 주요 장애
    case critical   // 심각한 장애

    nonisolated var displayText: String {
        switch self {
        case .none: return "정상 운영 중"
        case .minor: return "일부 성능 저하"
        case .major: return "서비스 장애"
        case .critical: return "심각한 장애"
        }
    }

    nonisolated var severityRank: Int {
        switch self {
        case .none: return 0
        case .minor: return 1
        case .major: return 2
        case .critical: return 3
        }
    }

    nonisolated static func highest(_ indicators: [StatusIndicator]) -> StatusIndicator {
        indicators.max { $0.severityRank < $1.severityRank } ?? .none
    }
}

struct ProviderSystemStatus: Sendable {
    let indicator: StatusIndicator
    let description: String
    let activeIncidentCount: Int
    let latestIncident: IncidentSummary?
    let degradedComponents: [String]
    let pageUpdatedAt: Date?

    struct IncidentSummary: Sendable {
        let name: String
        let status: String
        let impact: String
        let shortlink: String?
        let latestUpdateBody: String?
        let latestUpdateAt: Date?
        let affectedComponents: [String]
    }

    nonisolated var hasIssue: Bool {
        indicator != .none || activeIncidentCount > 0 || !degradedComponents.isEmpty
    }

    nonisolated var effectiveIndicator: StatusIndicator {
        if indicator != .none {
            return indicator
        }
        return hasIssue ? .minor : .none
    }

    nonisolated var menuBarSummary: String {
        if let latestIncident {
            return latestIncident.name
        }

        if !degradedComponents.isEmpty {
            let affected = degradedComponents.prefix(2).joined(separator: ", ")
            return "\(affected) \(effectiveIndicator.displayText)"
        }

        return effectiveIndicator.displayText
    }
}

typealias ClaudeSystemStatus = ProviderSystemStatus

// MARK: - API 응답 모델

struct StatusPageResponse: Sendable {
    let page: StatusPage
    let status: StatusInfo
    let components: [StatusComponent]
    let incidents: [StatusIncident]

    struct StatusPage: Sendable {
        let updatedAt: Date?
    }

    struct StatusInfo: Sendable {
        let indicator: String
        let description: String
    }

    struct StatusComponent: Sendable {
        let name: String
        let status: String
    }

    struct StatusIncident: Sendable {
        let name: String
        let status: String
        let impact: String
        let shortlink: String?
        let updatedAt: Date?
        let incidentUpdates: [StatusIncidentUpdate]
        let components: [StatusComponent]
    }

    struct StatusIncidentUpdate: Sendable {
        let status: String
        let body: String
        let displayAt: Date?
        let affectedComponents: [StatusAffectedComponent]
    }

    struct StatusAffectedComponent: Sendable {
        let name: String
    }

    nonisolated static func decode(from data: Data) -> StatusPageResponse? {
        struct _Response: Codable {
            let page: _Page
            let status: _Status
            let components: [_Component]
            let incidents: [_Incident]

            struct _Page: Codable {
                let updatedAt: String?

                enum CodingKeys: String, CodingKey {
                    case updatedAt = "updated_at"
                }
            }

            struct _Status: Codable {
                let indicator: String
                let description: String
            }

            struct _Component: Codable {
                let name: String
                let status: String
            }

            struct _Incident: Codable {
                let name: String
                let status: String
                let impact: String
                let shortlink: String?
                let updatedAt: String?
                let incidentUpdates: [_IncidentUpdate]
                let components: [_Component]

                enum CodingKeys: String, CodingKey {
                    case name
                    case status
                    case impact
                    case shortlink
                    case updatedAt = "updated_at"
                    case incidentUpdates = "incident_updates"
                    case components
                }
            }

            struct _IncidentUpdate: Codable {
                let status: String
                let body: String
                let displayAt: String?
                let affectedComponents: [_AffectedComponent]

                enum CodingKeys: String, CodingKey {
                    case status
                    case body
                    case displayAt = "display_at"
                    case affectedComponents = "affected_components"
                }
            }

            struct _AffectedComponent: Codable {
                let name: String
            }
        }

        guard let r = try? JSONDecoder().decode(_Response.self, from: data) else { return nil }

        let components = r.components.map { StatusComponent(name: $0.name, status: $0.status) }
        let incidents = r.incidents.map { incident in
            StatusIncident(
                name: incident.name,
                status: incident.status,
                impact: incident.impact,
                shortlink: incident.shortlink,
                updatedAt: parseISO8601(incident.updatedAt),
                incidentUpdates: incident.incidentUpdates.map { update in
                    StatusIncidentUpdate(
                        status: update.status,
                        body: update.body,
                        displayAt: parseISO8601(update.displayAt),
                        affectedComponents: update.affectedComponents.map { StatusAffectedComponent(name: $0.name) }
                    )
                },
                components: incident.components.map { StatusComponent(name: $0.name, status: $0.status) }
            )
        }

        return StatusPageResponse(
            page: StatusPage(updatedAt: parseISO8601(r.page.updatedAt)),
            status: StatusInfo(indicator: r.status.indicator, description: r.status.description),
            components: components,
            incidents: incidents
        )
    }

    nonisolated private static func parseISO8601(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }

        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: raw) {
            return date
        }

        let withoutFractional = ISO8601DateFormatter()
        withoutFractional.formatOptions = [.withInternetDateTime]
        return withoutFractional.date(from: raw)
    }
}

enum StatusPageInterpreter {
    nonisolated static func parseStatus(
        data: Data,
        relevantComponentNames: Set<String>? = nil,
        fallbackDescription: String? = nil
    ) -> ProviderSystemStatus? {
        guard let statusResponse = StatusPageResponse.decode(from: data) else {
            return nil
        }
        return makeStatus(
            from: statusResponse,
            relevantComponentNames: relevantComponentNames,
            fallbackDescription: fallbackDescription
        )
    }

    nonisolated static func makeStatus(
        from response: StatusPageResponse,
        relevantComponentNames: Set<String>? = nil,
        fallbackDescription: String? = nil
    ) -> ProviderSystemStatus? {
        let components = filteredComponents(response.components, relevantComponentNames: relevantComponentNames)
        if relevantComponentNames != nil, components.isEmpty {
            return nil
        }

        let degradedComponents = components
            .filter { $0.status != "operational" }
        let relevantIncidents = response.incidents
            .filter { incident in
                isRelevantIncident(incident, relevantComponentNames: relevantComponentNames)
            }

        let pageIndicator = relevantComponentNames == nil
            ? StatusIndicator(rawValue: response.status.indicator) ?? .none
            : .none
        let componentIndicator = StatusIndicator.highest(degradedComponents.map { Self.indicator(forComponentStatus: $0.status) })
        let incidentIndicator = StatusIndicator.highest(relevantIncidents.map { Self.indicator(forImpact: $0.impact) })
        let resolvedIndicator = StatusIndicator.highest([pageIndicator, componentIndicator, incidentIndicator])

        let latestIncident = relevantIncidents
            .sorted { lhs, rhs in
                let leftDate = lhs.updatedAt ?? .distantPast
                let rightDate = rhs.updatedAt ?? .distantPast
                return leftDate > rightDate
            }
            .first

        let latestIncidentSummary = latestIncident.map { incident in
            incidentSummary(for: incident, relevantComponentNames: relevantComponentNames)
        }

        return ProviderSystemStatus(
            indicator: resolvedIndicator,
            description: fallbackDescription ?? response.status.description,
            activeIncidentCount: relevantIncidents.count,
            latestIncident: latestIncidentSummary,
            degradedComponents: degradedComponents.map(\.name),
            pageUpdatedAt: response.page.updatedAt
        )
    }

    nonisolated private static func filteredComponents(
        _ components: [StatusPageResponse.StatusComponent],
        relevantComponentNames: Set<String>?
    ) -> [StatusPageResponse.StatusComponent] {
        guard let relevantComponentNames else {
            return components
        }
        return components.filter { relevantComponentNames.contains($0.name) }
    }

    nonisolated private static func isRelevantIncident(
        _ incident: StatusPageResponse.StatusIncident,
        relevantComponentNames: Set<String>?
    ) -> Bool {
        guard let relevantComponentNames else {
            return true
        }

        if incident.components.contains(where: { relevantComponentNames.contains($0.name) }) {
            return true
        }

        if incident.incidentUpdates.contains(where: { update in
            update.affectedComponents.contains(where: { relevantComponentNames.contains($0.name) })
        }) {
            return true
        }

        return relevantComponentNames.contains { componentName in
            incident.name.localizedCaseInsensitiveContains(componentName)
        }
    }

    nonisolated private static func incidentSummary(
        for incident: StatusPageResponse.StatusIncident,
        relevantComponentNames: Set<String>?
    ) -> ProviderSystemStatus.IncidentSummary {
        let latestUpdate = incident.incidentUpdates
            .sorted { lhs, rhs in
                let leftDate = lhs.displayAt ?? .distantPast
                let rightDate = rhs.displayAt ?? .distantPast
                return leftDate > rightDate
            }
            .first

        let affectedComponents = deduplicateNames(
            latestUpdate?.affectedComponents.map(\.name) ??
            incident.components.map(\.name)
        )
        let filteredAffectedComponents = relevantComponentNames.map { relevant in
            affectedComponents.filter { relevant.contains($0) }
        } ?? affectedComponents

        return ProviderSystemStatus.IncidentSummary(
            name: incident.name,
            status: incident.status,
            impact: incident.impact,
            shortlink: incident.shortlink,
            latestUpdateBody: latestUpdate?.body,
            latestUpdateAt: latestUpdate?.displayAt ?? incident.updatedAt,
            affectedComponents: filteredAffectedComponents
        )
    }

    nonisolated private static func indicator(forComponentStatus status: String) -> StatusIndicator {
        switch status {
        case "degraded_performance", "under_maintenance":
            return .minor
        case "partial_outage":
            return .major
        case "major_outage":
            return .critical
        default:
            return .none
        }
    }

    nonisolated private static func indicator(forImpact impact: String) -> StatusIndicator {
        switch impact {
        case "minor", "maintenance":
            return .minor
        case "major":
            return .major
        case "critical":
            return .critical
        default:
            return .none
        }
    }

    nonisolated private static func deduplicateNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }
}
