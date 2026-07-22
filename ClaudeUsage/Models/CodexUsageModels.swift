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
    /// 모델별 추가 한도 (예: GPT-5.3-Codex-Spark 주간 한도)
    let additionalRateLimits: [CodexAdditionalRateLimit]
    /// wham/rate-limit-reset-credits 별도 엔드포인트 결과 (조회 후 주입)
    var resetCredits: CodexResetCreditsResponse?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case credits
        case additionalRateLimits = "additional_rate_limits"
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        planType = try container.decodeIfPresent(String.self, forKey: .planType)
        rateLimit = try container.decodeIfPresent(CodexRateLimit.self, forKey: .rateLimit)
        credits = try container.decodeIfPresent(CodexCredits.self, forKey: .credits)
        additionalRateLimits = Self.decodeAdditionalRateLimits(from: container)
        resetCredits = nil
    }

    /// additional_rate_limits: 항목 단위 lossy 디코딩 — 항목 하나가 깨져도 본 한도 표시를 막지 않는다.
    nonisolated private static func decodeAdditionalRateLimits(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> [CodexAdditionalRateLimit] {
        guard var array = try? container.nestedUnkeyedContainer(forKey: .additionalRateLimits) else {
            return []
        }
        var collected: [CodexAdditionalRateLimit] = []
        while !array.isAtEnd {
            if let entry = try? array.decode(CodexAdditionalRateLimit.self) {
                collected.append(entry)
            } else if (try? array.decode(CodexDecodingSink.self)) == nil {
                break
            }
        }
        return collected
    }
}

/// 임의 JSON 요소 소비용 싱크 (lossy 배열 디코딩)
private struct CodexDecodingSink: Decodable {
    nonisolated init(from decoder: Decoder) throws {}
}

/// 모델별 추가 한도 항목 (additional_rate_limits[])
struct CodexAdditionalRateLimit: Codable, Sendable {
    let limitName: String?
    let meteredFeature: String?
    let rateLimit: CodexRateLimit?

    enum CodingKeys: String, CodingKey {
        case limitName = "limit_name"
        case meteredFeature = "metered_feature"
        case rateLimit = "rate_limit"
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        limitName = (try? container.decodeIfPresent(String.self, forKey: .limitName)) ?? nil
        meteredFeature = (try? container.decodeIfPresent(String.self, forKey: .meteredFeature)) ?? nil
        rateLimit = (try? container.decodeIfPresent(CodexRateLimit.self, forKey: .rateLimit)) ?? nil
    }

    /// 대표 창 (primary 우선)
    nonisolated var window: CodexUsageWindow? {
        rateLimit?.primaryWindow ?? rateLimit?.secondaryWindow
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
            let days = hours / 24
            if days == 7 { return "주간" }
            return "\(days)일"
        }
        return "\(hours)시간"
    }

    /// limit_window_seconds가 기대값과 다르면 실제 창 길이를 라벨로 노출합니다.
    /// (예: OpenAI가 세션 창을 주간으로 개편해도 라벨이 따라감)
    nonisolated func adaptiveTitle(expectedSeconds: Int, fallback: String) -> String {
        guard let seconds = limitWindowSeconds, seconds != expectedSeconds else { return fallback }
        let description = windowDescription
        if description.isEmpty { return fallback }
        return description == "주간" ? "주간 한도" : "\(description) 한도"
    }

    /// 컴팩트 표시용 짧은 라벨 (위와 같은 규칙)
    nonisolated func adaptiveCompactLabel(expectedSeconds: Int, fallback: String) -> String {
        guard let seconds = limitWindowSeconds, seconds != expectedSeconds else { return fallback }
        let description = windowDescription
        return description.isEmpty ? fallback : description
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
    /// 하루(24시간) 기준 — 이 미만이면 세션 성격, 이상이면 주간 성격 창으로 분류
    nonisolated private static var sessionWindowMaxSeconds: Int { 24 * 3600 }

    /// 세션 성격(24시간 미만) 창.
    /// 2026-07 개편으로 주간 창이 primary 자리에 올 수 있어, 위치가 아니라
    /// limit_window_seconds 로 분류한다. 창 길이 미상이면 레거시 가정(primary=세션)을 따른다.
    nonisolated var sessionWindow: CodexUsageWindow? {
        if let primary = rateLimit?.primaryWindow {
            if let seconds = primary.limitWindowSeconds {
                if seconds < Self.sessionWindowMaxSeconds { return primary }
            } else {
                return primary
            }
        }
        if let secondary = rateLimit?.secondaryWindow,
           let seconds = secondary.limitWindowSeconds,
           seconds < Self.sessionWindowMaxSeconds {
            return secondary
        }
        return nil
    }

    /// 주간 성격(24시간 이상) 창.
    /// secondary 우선, 없으면 primary 가 주간 창인지 확인한다. 창 길이 미상 secondary 는 레거시 가정(주간).
    nonisolated var weeklyWindow: CodexUsageWindow? {
        if let secondary = rateLimit?.secondaryWindow {
            if let seconds = secondary.limitWindowSeconds {
                if seconds >= Self.sessionWindowMaxSeconds { return secondary }
            } else {
                return secondary
            }
        }
        if let primary = rateLimit?.primaryWindow,
           let seconds = primary.limitWindowSeconds,
           seconds >= Self.sessionWindowMaxSeconds {
            return primary
        }
        return nil
    }

    /// (원시 접근용) primary 창 퍼센트 — 표시용으로는 sessionPercentage/weeklyPercentage 를 쓸 것
    nonisolated var primaryPercentage: Double {
        rateLimit?.primaryWindow?.utilization ?? 0
    }

    /// (원시 접근용) secondary 창 퍼센트
    nonisolated var secondaryPercentage: Double {
        rateLimit?.secondaryWindow?.utilization ?? 0
    }

    /// 세션 창 존재 여부 — 주간 전용 개편 응답이면 false
    nonisolated var hasSessionWindow: Bool {
        sessionWindow != nil
    }

    /// 세션 퍼센트 (없으면 0)
    nonisolated var sessionPercentage: Double {
        sessionWindow?.utilization ?? 0
    }

    /// 주간 퍼센트 (없으면 0)
    nonisolated var weeklyPercentage: Double {
        weeklyWindow?.utilization ?? 0
    }

    /// 메뉴바 색상·단일 퍼센트 표시 기준 게이지.
    /// 세션 창이 없으면 0% 대신 주간 창을 기준으로 사용합니다.
    nonisolated var gaugePercentage: Double {
        sessionWindow?.utilization ?? weeklyWindow?.utilization ?? 0
    }

    /// "현재 3% · 주간 41%" 요약. 세션 창이 없으면 주간만 표기.
    nonisolated var usageSummaryText: String {
        let session = sessionWindow.map { "현재 \(Int($0.utilization.rounded()))%" }
        let weekly = weeklyWindow.map { "주간 \(Int($0.utilization.rounded()))%" }
        return [session, weekly].compactMap { $0 }.joined(separator: " · ").ifEmpty("데이터 없음")
    }
}

private extension String {
    nonisolated func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}

// MARK: - Rate Limit 초기화 크레딧 (wham/rate-limit-reset-credits)

/// 사용량 초기화 크레딧 목록 응답
struct CodexResetCreditsResponse: Codable, Sendable, Equatable {
    let credits: [CodexResetCredit]
    /// API가 내려주는 사용 가능 개수 (없으면 credits에서 계산)
    let availableCountField: Int?

    enum CodingKeys: String, CodingKey {
        case credits
        case availableCountField = "available_count"
    }

    nonisolated init(credits: [CodexResetCredit], availableCountField: Int? = nil) {
        self.credits = credits
        self.availableCountField = availableCountField
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        availableCountField = (try? container.decodeIfPresent(Int.self, forKey: .availableCountField)) ?? nil

        // credits: 항목 단위 lossy 디코딩 — 항목 하나가 깨져도 전체를 버리지 않는다.
        var collected: [CodexResetCredit] = []
        if var array = try? container.nestedUnkeyedContainer(forKey: .credits) {
            while !array.isAtEnd {
                if let entry = try? array.decode(CodexResetCredit.self) {
                    collected.append(entry)
                } else if (try? array.decode(CodexResetCreditDecodingSink.self)) == nil {
                    break
                }
            }
        }
        credits = collected
    }

    /// 현재 시점 기준 사용 가능한(미만료) 크레딧 — 만료 임박 순 정렬
    nonisolated func availableCredits(at date: Date = Date()) -> [CodexResetCredit] {
        credits
            .filter { credit in
                credit.isAvailable && (credit.expiresDate.map { $0 > date } ?? true)
            }
            .sorted { lhs, rhs in
                switch (lhs.expiresDate, rhs.expiresDate) {
                case let (l?, r?): return l < r
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return false
                }
            }
    }

    /// 사용 가능 개수 (API 필드 우선, 없으면 계산)
    nonisolated func availableCount(at date: Date = Date()) -> Int {
        availableCountField ?? availableCredits(at: date).count
    }

    /// 가장 먼저 만료되는 사용 가능 크레딧
    nonisolated func nextExpiringAvailable(at date: Date = Date()) -> CodexResetCredit? {
        availableCredits(at: date).first { $0.expiresDate != nil }
    }
}

/// 임의 JSON 요소 소비용 싱크 (lossy 배열 디코딩)
private struct CodexResetCreditDecodingSink: Decodable {
    nonisolated init(from decoder: Decoder) throws {}
}

/// 개별 초기화 크레딧
struct CodexResetCredit: Codable, Sendable, Equatable {
    let id: String?
    let resetType: String?
    let status: String
    let grantedAtISO: String?
    let expiresAtISO: String?
    let title: String?
    let detail: String?

    enum CodingKeys: String, CodingKey {
        case id
        case resetType = "reset_type"
        case status
        case grantedAt = "granted_at"
        case expiresAt = "expires_at"
        case title
        case detail = "description"
    }

    nonisolated init(
        id: String? = nil,
        resetType: String? = nil,
        status: String,
        grantedAtISO: String? = nil,
        expiresAtISO: String? = nil,
        title: String? = nil,
        detail: String? = nil)
    {
        self.id = id
        self.resetType = resetType
        self.status = status
        self.grantedAtISO = grantedAtISO
        self.expiresAtISO = expiresAtISO
        self.title = title
        self.detail = detail
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // id: 문자열 또는 숫자 방어
        if let strVal = try? container.decode(String.self, forKey: .id) {
            id = strVal
        } else if let intVal = try? container.decode(Int.self, forKey: .id) {
            id = String(intVal)
        } else {
            id = nil
        }
        resetType = (try? container.decodeIfPresent(String.self, forKey: .resetType)) ?? nil
        status = (try? container.decode(String.self, forKey: .status)) ?? "unknown"
        grantedAtISO = Self.flexibleTimestampISO(container: container, key: .grantedAt)
        expiresAtISO = Self.flexibleTimestampISO(container: container, key: .expiresAt)
        title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? nil
        detail = (try? container.decodeIfPresent(String.self, forKey: .detail)) ?? nil
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(resetType, forKey: .resetType)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(grantedAtISO, forKey: .grantedAt)
        try container.encodeIfPresent(expiresAtISO, forKey: .expiresAt)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(detail, forKey: .detail)
    }

    nonisolated var isAvailable: Bool {
        status == "available"
    }

    nonisolated var expiresDate: Date? {
        guard let expiresAtISO else { return nil }
        return TimeFormatter.parseISO8601(expiresAtISO)
    }

    /// granted_at/expires_at: ISO 문자열 또는 unix 초/밀리초 숫자 방어 → ISO 문자열로 통일
    nonisolated private static func flexibleTimestampISO(
        container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> String? {
        if let textVal = try? container.decode(String.self, forKey: key) {
            let trimmed = textVal.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let numeric = Double(trimmed) {
                return isoString(fromUnixValue: numeric)
            }
            return trimmed
        }
        if let intVal = try? container.decode(Int.self, forKey: key) {
            return isoString(fromUnixValue: Double(intVal))
        }
        if let doubleVal = try? container.decode(Double.self, forKey: key) {
            return isoString(fromUnixValue: doubleVal)
        }
        return nil
    }

    /// 밀리초/초 자동 판별 (1e10 초과면 밀리초로 간주 — orca와 동일 기준)
    nonisolated private static func isoString(fromUnixValue value: Double) -> String {
        let seconds = value > 10_000_000_000 ? value / 1000 : value
        let date = Date(timeIntervalSince1970: seconds)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
