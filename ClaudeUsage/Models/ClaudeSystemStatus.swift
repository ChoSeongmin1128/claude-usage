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

struct StatusPageResponse: Codable, Sendable {
    let status: StatusInfo
    let incidents: [StatusIncident]

    struct StatusInfo: Codable, Sendable {
        let indicator: String
        let description: String
    }

    struct StatusIncident: Codable, Sendable {
        let name: String
        let status: String
        let impact: String
    }
}
