//
//  ClaudeStatusService.swift
//  ClaudeUsage
//
//  Claude 시스템 상태 확인 (status.claude.com API)
//

import Foundation

actor ClaudeStatusService {
    static let shared = ClaudeStatusService()

    private let statusURL = "https://status.claude.com/api/v2/summary.json"

    /// 시스템 상태 가져오기 (실패 시 nil 반환, 앱 중단 방지)
    func fetchStatus() async -> ClaudeSystemStatus? {
        guard let url = URL(string: statusURL) else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                Logger.warning("상태 API 응답 오류")
                return nil
            }

            return Self.parseStatus(data: data)

        } catch {
            Logger.warning("상태 확인 실패: \(error.localizedDescription)")
            return nil
        }
    }

    /// JSON 파싱 (nonisolated로 MainActor 제약 회피)
    nonisolated private static func parseStatus(data: Data) -> ClaudeSystemStatus? {
        guard let statusResponse = StatusPageResponse.decode(from: data) else {
            return nil
        }

        let indicator = StatusIndicator(rawValue: statusResponse.status.indicator) ?? .none
        let degradedComponents = statusResponse.components
            .filter { $0.status != "operational" }
            .map(\.name)

        let latestIncident = statusResponse.incidents
            .sorted { lhs, rhs in
                let leftDate = lhs.updatedAt ?? .distantPast
                let rightDate = rhs.updatedAt ?? .distantPast
                return leftDate > rightDate
            }
            .first

        let latestIncidentSummary: ClaudeSystemStatus.IncidentSummary? = latestIncident.map { incident in
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

            return ClaudeSystemStatus.IncidentSummary(
                name: incident.name,
                status: incident.status,
                impact: incident.impact,
                shortlink: incident.shortlink,
                latestUpdateBody: latestUpdate?.body,
                latestUpdateAt: latestUpdate?.displayAt ?? incident.updatedAt,
                affectedComponents: affectedComponents
            )
        }

        return ClaudeSystemStatus(
            indicator: indicator,
            description: statusResponse.status.description,
            activeIncidentCount: statusResponse.incidents.count,
            latestIncident: latestIncidentSummary,
            degradedComponents: degradedComponents,
            pageUpdatedAt: statusResponse.page.updatedAt
        )
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
