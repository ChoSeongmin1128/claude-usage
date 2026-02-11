//
//  UsageModels.swift
//  ClaudeUsage
//
//  Phase 1: API 응답 데이터 모델
//

import Foundation

/// Claude.ai API 전체 응답 구조
struct ClaudeUsageResponse: Codable, Sendable {
    let fiveHour: UsageWindow
    let sevenDay: UsageWindow
    let sevenDayOpus: UsageWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
    }
}

/// 개별 사용량 윈도우 (5시간, 주간, Opus)
struct UsageWindow: Codable, Sendable {
    let utilizationPercentage: Double  // 0.0 ~ 100.0
    let resetAt: String                // ISO 8601 형식

    enum CodingKeys: String, CodingKey {
        case utilizationPercentage = "utilization_percentage"
        case resetAt = "reset_at"
    }
}

// MARK: - 편의 기능

extension UsageWindow {
    /// 퍼센트를 정수로 반환 (67.5% → 67)
    var percentageInt: Int {
        Int(utilizationPercentage)
    }

    /// 리셋 시간을 Date로 변환
    var resetDate: Date? {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: resetAt)
    }
}

extension ClaudeUsageResponse {
    /// 5시간 세션 퍼센트 (메인 표시용)
    var fiveHourPercentage: Double {
        fiveHour.utilizationPercentage
    }

    /// 주간 한도 퍼센트
    var weeklyPercentage: Double {
        sevenDay.utilizationPercentage
    }

    /// Opus 주간 퍼센트 (없으면 nil)
    var opusPercentage: Double? {
        sevenDayOpus?.utilizationPercentage
    }
}
