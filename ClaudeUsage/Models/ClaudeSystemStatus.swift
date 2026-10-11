//
//  ClaudeSystemStatus.swift
//  ClaudeUsage
//
//  Provider 시스템 상태 모델 (Statuspage API)
//

import Foundation

nonisolated enum StatusIndicator: String, Codable, Sendable {
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

nonisolated struct ProviderSystemStatus: Sendable, Equatable {
    let indicator: StatusIndicator
    let description: String
    /// 해결되지 않은 장애. 앱이 쓰는 제품에 걸린 장애가 먼저, 같은 묶음 안에서는 최근 업데이트 순이다.
    let activeIncidents: [IncidentSummary]
    let componentIssues: [ComponentIssue]
    let pageUpdatedAt: Date?

    struct IncidentSummary: Sendable, Equatable {
        let name: String
        let status: String
        let impact: String
        let shortlink: String?
        let latestUpdateBody: String?
        let latestUpdateAt: Date?
        let affectedComponents: [String]
        let isPriority: Bool

        init(
            name: String,
            status: String,
            impact: String,
            shortlink: String?,
            latestUpdateBody: String?,
            latestUpdateAt: Date?,
            affectedComponents: [String],
            isPriority: Bool = false
        ) {
            self.name = name
            self.status = status
            self.impact = impact
            self.shortlink = shortlink
            self.latestUpdateBody = latestUpdateBody
            self.latestUpdateAt = latestUpdateAt
            self.affectedComponents = affectedComponents
            self.isPriority = isPriority
        }
    }

    struct ComponentIssue: Sendable, Equatable {
        let name: String
        let indicator: StatusIndicator
    }

    init(
        indicator: StatusIndicator,
        description: String,
        activeIncidents: [IncidentSummary] = [],
        componentIssues: [ComponentIssue] = [],
        pageUpdatedAt: Date?
    ) {
        self.indicator = indicator
        self.description = description
        self.activeIncidents = activeIncidents
        self.componentIssues = componentIssues
        self.pageUpdatedAt = pageUpdatedAt
    }

    nonisolated var activeIncidentCount: Int {
        activeIncidents.count
    }

    nonisolated var latestIncident: IncidentSummary? {
        activeIncidents.max { ($0.latestUpdateAt ?? .distantPast) < ($1.latestUpdateAt ?? .distantPast) }
    }

    nonisolated var degradedComponents: [String] {
        componentIssues.map(\.name)
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

/// 상태 페이지 전체 중 앱이 보여 주는 제품에 걸린 장애를 고르는 규칙.
/// 단어 단위로 맞춰 "not working"의 work나 "client"의 cli 같은 부분 문자열은 고르지 않는다.
nonisolated struct StatusIncidentPriorityRule: Sendable {
    let componentNames: Set<String>
    let componentNamePrefixes: [String]
    let componentNameKeywords: [String]
    let titleKeywords: [String]

    static let claude = StatusIncidentPriorityRule(
        componentNames: ["claude.ai", "Claude Code"],
        componentNamePrefixes: ["Claude API"],
        componentNameKeywords: [],
        titleKeywords: ["claude.ai", "Claude Code", "Claude API"]
    )

    /// OpenAI 장애에는 구성 요소 정보가 비어 있는 경우가 많아 제목으로도 고른다.
    static let codex = StatusIncidentPriorityRule(
        componentNames: ["ChatGPT Work"],
        componentNamePrefixes: [],
        componentNameKeywords: ["Codex"],
        titleKeywords: ["Codex", "Work mode", "ChatGPT Work"]
    )

    nonisolated func isPriority(title: String, componentNames names: [String]) -> Bool {
        let matchesComponent = names.contains { name in
            componentNames.contains(name)
                || componentNamePrefixes.contains { name.hasPrefix($0) }
                || componentNameKeywords.contains { Self.containsWord($0, in: name) }
        }
        return matchesComponent || titleKeywords.contains { Self.containsWord($0, in: title) }
    }

    nonisolated static func containsWord(_ word: String, in text: String) -> Bool {
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: word, options: [.caseInsensitive], range: searchRange) {
            let startsAtBoundary =
                found.lowerBound == text.startIndex
                || !isWordCharacter(text[text.index(before: found.lowerBound)])
            let endsAtBoundary = found.upperBound == text.endIndex || !isWordCharacter(text[found.upperBound])
            if startsAtBoundary && endsAtBoundary {
                return true
            }
            searchRange = text.index(after: found.lowerBound)..<text.endIndex
        }
        return false
    }

    nonisolated private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}

typealias ClaudeSystemStatus = ProviderSystemStatus

// MARK: - API 응답 모델

nonisolated struct StatusPageResponse: Sendable {
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

    /// 서비스마다 응답 모양이 조금씩 다르다(OpenAI 장애에는 components와 shortlink가 없고, update의
    /// affected_components가 없거나 null일 수 있다). 목록이 빠져도 상태 전체를 버리지 않도록 목록은 모두 선택값으로 읽는다.
    nonisolated static func decode(from data: Data) -> StatusPageResponse? {
        struct _Response: Codable {
            let page: _Page
            let status: _Status
            let components: [_Component]?
            let incidents: [_Incident]?

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
                let incidentUpdates: [_IncidentUpdate]?
                let components: [_Component]?

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
                let affectedComponents: [_AffectedComponent]?

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

        let components = (r.components ?? []).map { StatusComponent(name: $0.name, status: $0.status) }
        let incidents = (r.incidents ?? []).map { incident in
            StatusIncident(
                name: incident.name,
                status: incident.status,
                impact: incident.impact,
                shortlink: incident.shortlink,
                updatedAt: parseISO8601(incident.updatedAt),
                incidentUpdates: (incident.incidentUpdates ?? []).map { update in
                    StatusIncidentUpdate(
                        status: update.status,
                        body: update.body,
                        displayAt: parseISO8601(update.displayAt),
                        affectedComponents: (update.affectedComponents ?? []).map {
                            StatusAffectedComponent(name: $0.name)
                        }
                    )
                },
                components: (incident.components ?? []).map { StatusComponent(name: $0.name, status: $0.status) }
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

nonisolated enum StatusPageInterpreter {
    /// 해결된 장애가 summary에 남아 있어도 진행 중으로 세지 않는다.
    nonisolated private static let finishedIncidentStatuses: Set<String> = ["resolved", "postmortem", "completed"]

    nonisolated static func parseStatus(
        data: Data,
        priorityRule: StatusIncidentPriorityRule
    ) -> ProviderSystemStatus? {
        guard let statusResponse = StatusPageResponse.decode(from: data) else {
            return nil
        }
        return makeStatus(from: statusResponse, priorityRule: priorityRule)
    }

    /// 상태 페이지 전체를 그 서비스의 상태로 읽는다. 머리 상태는 페이지가 매긴 값을 따른다.
    /// 확인 단계(monitoring)인 장애의 영향도로 페이지보다 높이면 페이지와 다른 상태를 보여 주게 된다.
    /// 페이지 값이 없거나 모르는 값일 때만 구성 요소와 장애 중 가장 나쁜 값을 쓴다.
    nonisolated static func makeStatus(
        from response: StatusPageResponse,
        priorityRule: StatusIncidentPriorityRule
    ) -> ProviderSystemStatus {
        let componentIssues = componentIssues(from: response.components)
        let activeIncidents = response.incidents
            .filter { !finishedIncidentStatuses.contains($0.status) }
            .map { incidentSummary(for: $0, priorityRule: priorityRule) }

        let pageIndicator = StatusIndicator(rawValue: response.status.indicator)
        let componentIndicator = StatusIndicator.highest(componentIssues.map(\.indicator))
        let incidentIndicator = StatusIndicator.highest(activeIncidents.map { Self.indicator(forImpact: $0.impact) })

        return ProviderSystemStatus(
            indicator: pageIndicator ?? StatusIndicator.highest([componentIndicator, incidentIndicator]),
            description: response.status.description,
            activeIncidents: displayOrder(activeIncidents),
            componentIssues: componentIssues,
            pageUpdatedAt: response.page.updatedAt
        )
    }

    nonisolated static func displayOrder(
        _ incidents: [ProviderSystemStatus.IncidentSummary]
    ) -> [ProviderSystemStatus.IncidentSummary] {
        incidents.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.isPriority != rhs.element.isPriority {
                    return lhs.element.isPriority
                }
                let leftDate = lhs.element.latestUpdateAt ?? .distantPast
                let rightDate = rhs.element.latestUpdateAt ?? .distantPast
                if leftDate != rightDate {
                    return leftDate > rightDate
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// 같은 이름이 두 번 오는 페이지가 있어(OpenAI의 Login) 이름별로 가장 나쁜 상태 하나만 남긴다.
    nonisolated private static func componentIssues(
        from components: [StatusPageResponse.StatusComponent]
    ) -> [ProviderSystemStatus.ComponentIssue] {
        var issues: [ProviderSystemStatus.ComponentIssue] = []
        for component in components {
            let indicator = indicator(forComponentStatus: component.status)
            let name = component.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard indicator != .none, !name.isEmpty else { continue }
            if let index = issues.firstIndex(where: { $0.name == name }) {
                let worst = StatusIndicator.highest([issues[index].indicator, indicator])
                issues[index] = ProviderSystemStatus.ComponentIssue(name: name, indicator: worst)
            } else {
                issues.append(ProviderSystemStatus.ComponentIssue(name: name, indicator: indicator))
            }
        }
        return issues
    }

    nonisolated private static func incidentSummary(
        for incident: StatusPageResponse.StatusIncident,
        priorityRule: StatusIncidentPriorityRule
    ) -> ProviderSystemStatus.IncidentSummary {
        let updates = incident.incidentUpdates
            .sorted { ($0.displayAt ?? .distantPast) > ($1.displayAt ?? .distantPast) }
        let latestUpdate = updates.first

        // incident의 components가 걸린 구성 요소 전체다. update에는 그 회차에 상태가 바뀐 것만 오고,
        // components가 빈 장애도 있어(실측 2026-10-11) 그때는 update에 나온 이름을 모두 쓴다.
        let incidentComponents = deduplicateNames(incident.components.map(\.name))
        let updateComponents = deduplicateNames(updates.flatMap { $0.affectedComponents.map(\.name) })

        return ProviderSystemStatus.IncidentSummary(
            name: incident.name,
            status: incident.status,
            impact: incident.impact,
            shortlink: incident.shortlink,
            latestUpdateBody: latestUpdate?.body,
            latestUpdateAt: latestUpdate?.displayAt ?? incident.updatedAt,
            affectedComponents: incidentComponents.isEmpty ? updateComponents : incidentComponents,
            isPriority: priorityRule.isPriority(
                title: incident.name,
                componentNames: incidentComponents + updateComponents
            )
        )
    }

    nonisolated private static func indicator(forComponentStatus status: String) -> StatusIndicator {
        switch status {
        case "operational":
            return .none
        case "partial_outage":
            return .major
        case "major_outage":
            return .critical
        default:
            // degraded_performance, under_maintenance와 처음 보는 값은 정상이 아니므로 경미로 둔다.
            return .minor
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
