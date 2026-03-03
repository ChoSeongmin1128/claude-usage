//
//  ClaudeSystemStatus.swift
//  ClaudeUsage
//
//  Claude 시스템 상태 모델 (status.claude.com API)
//

import Foundation

enum StatusIndicator: String, Codable, Sendable {
    case none       // 정상
    case minor      // 경미한 장애
    case major      // 주요 장애
    case critical   // 심각한 장애

    var displayText: String {
        switch self {
        case .none: return "정상 운영 중"
        case .minor: return "일부 성능 저하"
        case .major: return "서비스 장애"
        case .critical: return "심각한 장애"
        }
    }
}

struct ClaudeSystemStatus: Sendable {
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

    var hasIssue: Bool {
        indicator != .none || activeIncidentCount > 0 || !degradedComponents.isEmpty
    }
}

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
