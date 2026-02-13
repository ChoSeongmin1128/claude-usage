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

    var hasIssue: Bool {
        indicator != .none
    }
}

// MARK: - API 응답 모델

struct StatusPageResponse: Sendable {
    let status: StatusInfo
    let incidents: [StatusIncident]

    struct StatusInfo: Sendable {
        let indicator: String
        let description: String
    }

    struct StatusIncident: Sendable {
        let name: String
        let status: String
        let impact: String
    }

    nonisolated static func decode(from data: Data) -> StatusPageResponse? {
        struct _Response: Codable {
            let status: _Status
            let incidents: [_Incident]
            struct _Status: Codable { let indicator: String; let description: String }
            struct _Incident: Codable { let name: String; let status: String; let impact: String }
        }
        guard let r = try? JSONDecoder().decode(_Response.self, from: data) else { return nil }
        return StatusPageResponse(
            status: StatusInfo(indicator: r.status.indicator, description: r.status.description),
            incidents: r.incidents.map { StatusIncident(name: $0.name, status: $0.status, impact: $0.impact) }
        )
    }
}
