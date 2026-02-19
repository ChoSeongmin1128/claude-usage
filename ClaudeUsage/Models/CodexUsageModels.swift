//
//  CodexUsageModels.swift
//  ClaudeUsage
//
//  Codex (ChatGPT) API 응답 데이터 모델
//  참고: https://github.com/steipete/CodexBar
//

import Foundation

/// Codex (ChatGPT) 사용량 API 응답
struct CodexUsageResponse: Codable, Sendable {
    let planType: String?
    let rateLimit: CodexRateLimit?
    let credits: CodexCredits?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case credits
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        planType = try container.decodeIfPresent(String.self, forKey: .planType)
        rateLimit = try container.decodeIfPresent(CodexRateLimit.self, forKey: .rateLimit)
        credits = try container.decodeIfPresent(CodexCredits.self, forKey: .credits)
    }
}

/// Codex 사용량 윈도우 (5시간/7일)
struct CodexRateLimit: Codable, Sendable {
    let primaryWindow: CodexUsageWindow?
    let secondaryWindow: CodexUsageWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        primaryWindow = try container.decodeIfPresent(CodexUsageWindow.self, forKey: .primaryWindow)
        secondaryWindow = try container.decodeIfPresent(CodexUsageWindow.self, forKey: .secondaryWindow)
    }
}

/// 개별 사용량 윈도우
struct CodexUsageWindow: Codable, Sendable {
    let usedPercent: Double
    let resetAt: Double?           // Unix timestamp (Int or Double)
    let limitWindowSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetAt = "reset_at"
        case limitWindowSeconds = "limit_window_seconds"
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // usedPercent: Int 또는 Double
        if let intVal = try? container.decode(Int.self, forKey: .usedPercent) {
            usedPercent = Double(intVal)
        } else if let doubleVal = try? container.decode(Double.self, forKey: .usedPercent) {
            usedPercent = doubleVal
        } else {
            usedPercent = 0
        }

        // resetAt: Int 또는 Double
        if let intVal = try? container.decode(Int.self, forKey: .resetAt) {
            resetAt = Double(intVal)
        } else {
            resetAt = try container.decodeIfPresent(Double.self, forKey: .resetAt)
        }

        limitWindowSeconds = try container.decodeIfPresent(Int.self, forKey: .limitWindowSeconds)
    }

    /// Unix timestamp → ISO 8601 문자열 (기존 TimeFormatter 재사용용)
    nonisolated var resetAtISO: String? {
        guard let resetAt = resetAt else { return nil }
        let date = Date(timeIntervalSince1970: resetAt)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// 사용률 퍼센트 (0~100) — API가 0~100 정수를 반환
    nonisolated var utilization: Double {
        usedPercent
    }

    /// 윈도우 설명
    nonisolated var windowDescription: String {
        guard let seconds = limitWindowSeconds else { return "" }
        let hours = seconds / 3600
        if hours >= 24 {
            return "\(hours / 24)일"
        }
        return "\(hours)시간"
    }
}

/// Codex 크레딧 정보
struct CodexCredits: Codable, Sendable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: Double?

    enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case unlimited
        case balance
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasCredits = (try? container.decode(Bool.self, forKey: .hasCredits)) ?? false
        unlimited = (try? container.decode(Bool.self, forKey: .unlimited)) ?? false

        // balance: Double 또는 String (CodexBar 호환)
        if let doubleVal = try? container.decode(Double.self, forKey: .balance) {
            balance = doubleVal
        } else if let strVal = try? container.decode(String.self, forKey: .balance),
                  let parsed = Double(strVal) {
            balance = parsed
        } else {
            balance = nil
        }
    }

    /// 포맷된 잔액
    nonisolated var formattedBalance: String {
        if unlimited { return "무제한" }
        guard let balance = balance else { return "정보 없음" }
        return String(format: "$%.2f", balance)
    }
}

// MARK: - 편의 기능

extension CodexUsageResponse {
    /// 5시간 세션 퍼센트
    nonisolated var primaryPercentage: Double {
        rateLimit?.primaryWindow?.utilization ?? 0
    }

    /// 주간 퍼센트
    nonisolated var secondaryPercentage: Double {
        rateLimit?.secondaryWindow?.utilization ?? 0
    }
}
