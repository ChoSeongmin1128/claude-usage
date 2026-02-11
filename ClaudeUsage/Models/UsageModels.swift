//
//  UsageModels.swift
//  ClaudeUsage
//
//  API 응답 데이터 모델 (실제 Claude.ai API 구조 기반)
//

import Foundation

/// Claude.ai API 전체 응답 구조
struct ClaudeUsageResponse: Codable, Sendable {
    let fiveHour: UsageWindow
    let sevenDay: UsageWindow
    let sevenDaySonnet: UsageWindow?  // Max 플랜 전용
    let sevenDayOpus: UsageWindow?    // Max 플랜 전용

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOpus = "seven_day_opus"
    }
}

/// 개별 사용량 윈도우 (5시간, 주간, Sonnet, Opus)
struct UsageWindow: Codable, Sendable {
    let utilization: Double   // 0.0 ~ 100.0+
    let resetsAt: String      // ISO 8601 형식

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    /// utilization이 Int 또는 Double로 올 수 있어서 방어적 디코딩
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resetsAt = try container.decode(String.self, forKey: .resetsAt)

        // utilization: Int, Double, String 모두 처리
        if let doubleVal = try? container.decode(Double.self, forKey: .utilization) {
            utilization = doubleVal
        } else if let intVal = try? container.decode(Int.self, forKey: .utilization) {
            utilization = Double(intVal)
        } else if let strVal = try? container.decode(String.self, forKey: .utilization),
                  let parsed = Double(strVal) {
            utilization = parsed
        } else {
            utilization = 0
        }
    }
}

// MARK: - 편의 기능

extension UsageWindow {
    /// 퍼센트를 정수로 반환 (67.5% → 67)
    var percentageInt: Int {
        Int(utilization)
    }

    /// 리셋 시간을 Date로 변환
    var resetDate: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: resetsAt) {
            return date
        }
        // fractionalSeconds 없는 형식도 시도
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: resetsAt)
    }
}

extension ClaudeUsageResponse {
    /// 5시간 세션 퍼센트 (메인 표시용)
    var fiveHourPercentage: Double {
        fiveHour.utilization
    }

    /// 주간 한도 퍼센트
    var weeklyPercentage: Double {
        sevenDay.utilization
    }

    /// Sonnet 주간 퍼센트 (없으면 nil)
    var sonnetPercentage: Double? {
        sevenDaySonnet?.utilization
    }

    /// Opus 주간 퍼센트 (없으면 nil)
    var opusPercentage: Double? {
        sevenDayOpus?.utilization
    }
}
