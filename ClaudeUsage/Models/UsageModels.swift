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

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try container.decode(UsageWindow.self, forKey: .fiveHour)
        sevenDay = try container.decode(UsageWindow.self, forKey: .sevenDay)
        sevenDaySonnet = try container.decodeIfPresent(UsageWindow.self, forKey: .sevenDaySonnet)
        sevenDayOpus = try container.decodeIfPresent(UsageWindow.self, forKey: .sevenDayOpus)
    }
}

/// 개별 사용량 윈도우 (5시간, 주간, Sonnet, Opus)
struct UsageWindow: Codable, Sendable {
    let utilization: Double   // 0.0 ~ 100.0+
    let resetsAt: String?     // ISO 8601 형식 (Pro 플랜은 null)

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    /// utilization이 Int 또는 Double로 올 수 있어서 방어적 디코딩
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resetsAt = try container.decodeIfPresent(String.self, forKey: .resetsAt)

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
    nonisolated var percentageInt: Int {
        Int(utilization)
    }

    /// 리셋 시간을 Date로 변환
    nonisolated var resetDate: Date? {
        guard let resetsAt = resetsAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: resetsAt) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: resetsAt)
    }
}

extension ClaudeUsageResponse {
    /// 5시간 세션 퍼센트 (메인 표시용)
    nonisolated var fiveHourPercentage: Double {
        fiveHour.utilization
    }

    /// 주간 한도 퍼센트
    nonisolated var weeklyPercentage: Double {
        sevenDay.utilization
    }

    /// Sonnet 주간 퍼센트 (없으면 nil)
    nonisolated var sonnetPercentage: Double? {
        sevenDaySonnet?.utilization
    }

    /// Opus 주간 퍼센트 (없으면 nil)
    nonisolated var opusPercentage: Double? {
        sevenDayOpus?.utilization
    }
}

// MARK: - 추가 사용량 (Extra Usage / Overage)

/// 추가 사용량 API 응답 (금액은 센트 단위로 수신)
struct OverageSpendLimitResponse: Codable, Sendable {
    let monthlyCreditLimitCents: Double  // 월별 한도 (센트)
    let usedCreditsCents: Double         // 사용한 금액 (센트)
    let isEnabled: Bool                  // Extra Usage 활성 여부
    let outOfCredits: Bool               // 크레딧 소진 여부
    let currency: String                 // 통화 (USD)

    enum CodingKeys: String, CodingKey {
        case monthlyCreditLimitCents = "monthly_credit_limit"
        case usedCreditsCents = "used_credits"
        case isEnabled = "is_enabled"
        case outOfCredits = "out_of_credits"
        case currency
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let doubleVal = try? container.decode(Double.self, forKey: .monthlyCreditLimitCents) {
            monthlyCreditLimitCents = doubleVal
        } else if let intVal = try? container.decode(Int.self, forKey: .monthlyCreditLimitCents) {
            monthlyCreditLimitCents = Double(intVal)
        } else {
            monthlyCreditLimitCents = 0
        }

        if let doubleVal = try? container.decode(Double.self, forKey: .usedCreditsCents) {
            usedCreditsCents = doubleVal
        } else if let intVal = try? container.decode(Int.self, forKey: .usedCreditsCents) {
            usedCreditsCents = Double(intVal)
        } else {
            usedCreditsCents = 0
        }

        isEnabled = (try? container.decode(Bool.self, forKey: .isEnabled)) ?? false
        outOfCredits = (try? container.decode(Bool.self, forKey: .outOfCredits)) ?? false
        currency = (try? container.decode(String.self, forKey: .currency)) ?? "USD"
    }
}

extension OverageSpendLimitResponse {
    /// 달러 단위 한도
    nonisolated var monthlyCreditLimit: Double {
        monthlyCreditLimitCents / 100.0
    }

    /// 달러 단위 사용 금액
    nonisolated var usedCredits: Double {
        usedCreditsCents / 100.0
    }

    /// 사용률 퍼센트 (0~100)
    nonisolated var usagePercentage: Double {
        guard monthlyCreditLimitCents > 0 else { return 0 }
        return (usedCreditsCents / monthlyCreditLimitCents) * 100
    }

    /// 통화 포맷된 사용 금액
    nonisolated var formattedUsedCredits: String {
        String(format: "$%.2f", usedCredits)
    }

    /// 통화 포맷된 한도
    nonisolated var formattedCreditLimit: String {
        String(format: "$%.2f", monthlyCreditLimit)
    }

    /// 잔액
    nonisolated var remainingCredits: Double {
        max(0, monthlyCreditLimit - usedCredits)
    }

    /// 통화 포맷된 잔액
    nonisolated var formattedRemainingCredits: String {
        String(format: "$%.2f", remainingCredits)
    }
}
