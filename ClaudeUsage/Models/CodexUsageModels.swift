//
//  CodexUsageModels.swift
//  ClaudeUsage
//
//  Codex (ChatGPT) API 응답 데이터 모델
//  참고: https://github.com/steipete/CodexBar
//

import Foundation

/// Codex (ChatGPT) 사용량 API 응답
nonisolated struct CodexUsageResponse: Codable, Sendable {
    let accountID: String?
    let planType: String?
    let rateLimit: CodexRateLimit?
    let credits: CodexCredits?
    /// 모델별 추가 한도 (예: GPT-5.3-Codex-Spark 주간 한도)
    let additionalRateLimits: [CodexAdditionalRateLimit]
    /// Business/Enterprise 좌석의 월 크레딧 한도
    let spendControl: CodexSpendControl?
    /// 한도에 걸린 이유(workspace_member_credits_depleted 등). 공식 backend 모델 기준
    let rateLimitReachedType: String?
    /// 사용량 수량과 별도 HTTP 상세 조회 결과.
    var resetCredits: CodexResetCreditsResponse?
    var resetCreditMetadata: CodexResetCreditMetadata? = nil

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case credits
        case additionalRateLimits = "additional_rate_limits"
        case spendControl = "spend_control"
        case rateLimitReachedType = "rate_limit_reached_type"
        case resetCredits = "rate_limit_reset_credits"
    }

    private struct ReachedType: Decodable {
        let type: String?
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 창이 없거나 크레딧만 있는 요금제(Enterprise/Edu 유연 요금제)가 있다. 필드 하나가 전체를 깨지 않게 한다.
        accountID = (try? container.decodeIfPresent(String.self, forKey: .accountID)) ?? nil
        planType = (try? container.decodeIfPresent(String.self, forKey: .planType)) ?? nil
        rateLimit = (try? container.decodeIfPresent(CodexRateLimit.self, forKey: .rateLimit)) ?? nil
        credits = (try? container.decodeIfPresent(CodexCredits.self, forKey: .credits)) ?? nil
        additionalRateLimits = Self.decodeAdditionalRateLimits(from: container)
        spendControl = (try? container.decodeIfPresent(CodexSpendControl.self, forKey: .spendControl)) ?? nil
        rateLimitReachedType =
            ((try? container.decodeIfPresent(ReachedType.self, forKey: .rateLimitReachedType)) ?? nil)?
            .type
        if let summary = try? container.decode(CodexResetCreditsResponse.self, forKey: .resetCredits),
            let count = summary.availableCountField, count >= 0
        {
            resetCredits = summary
        } else {
            resetCredits = nil
        }
        let hasMalformedLimits =
            rateLimit?.hasMalformedWindow == true
            || (rateLimit == nil && container.contains(.rateLimit)
                && (try? container.decodeNil(forKey: .rateLimit)) != true)
        if hasMalformedLimits, rateLimit?.primaryWindow == nil, rateLimit?.secondaryWindow == nil,
            credits == nil, additionalRateLimits.isEmpty, spendControl == nil
        {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Codex rate limits are malformed"))
        }
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

/// spend_control. 공식 backend 모델은 금액을 문자열로, 비율과 시각을 정수로 준다.
nonisolated struct CodexSpendControl: Codable, Sendable {
    let reached: Bool
    let individualLimit: CodexSpendLimit?

    enum CodingKeys: String, CodingKey {
        case reached
        case individualLimit = "individual_limit"
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reached = (try? container.decode(Bool.self, forKey: .reached)) ?? false
        individualLimit = (try? container.decodeIfPresent(CodexSpendLimit.self, forKey: .individualLimit)) ?? nil
    }
}

nonisolated struct CodexSpendLimit: Codable, Sendable {
    let limit: Double?
    let used: Double?
    let usedPercent: Double?
    let resetAt: Double?

    enum CodingKeys: String, CodingKey {
        case limit
        case used
        case usedPercent = "used_percent"
        case resetAt = "reset_at"
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func number(_ key: CodingKeys) -> Double? {
            if let value = try? container.decode(Double.self, forKey: key) { return value }
            if let text = try? container.decode(String.self, forKey: key) { return Double(text) }
            return nil
        }
        limit = number(.limit)
        used = number(.used)
        usedPercent = number(.usedPercent).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        resetAt = number(.resetAt)
    }

    nonisolated var resetAtISO: String? {
        guard let resetAt, resetAt > 0 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date(timeIntervalSince1970: resetAt))
    }
}

/// 임의 JSON 요소 소비용 싱크 (lossy 배열 디코딩)
private struct CodexDecodingSink: Decodable {
    nonisolated init(from decoder: Decoder) throws {}
}

/// 모델별 추가 한도 항목 (additional_rate_limits[])
nonisolated struct CodexAdditionalRateLimit: Codable, Sendable {
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

}

/// Codex 사용량 윈도우 (5시간/7일)
nonisolated struct CodexRateLimit: Codable, Sendable {
    let primaryWindow: CodexUsageWindow?
    let secondaryWindow: CodexUsageWindow?
    /// 형식이 깨져 버린 창이 있었는지. 인코딩하지 않는다.
    let hasMalformedWindow: Bool

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var malformed = false
        func window(_ key: CodingKeys) -> CodexUsageWindow? {
            guard container.contains(key), (try? container.decodeNil(forKey: key)) != true else { return nil }
            if let decoded = try? container.decode(CodexUsageWindow.self, forKey: key) { return decoded }
            malformed = true
            return nil
        }
        primaryWindow = window(.primaryWindow)
        secondaryWindow = window(.secondaryWindow)
        hasMalformedWindow = malformed
    }
}

/// 개별 사용량 윈도우
nonisolated struct CodexUsageWindow: Codable, Sendable {
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
            throw DecodingError.dataCorruptedError(
                forKey: .usedPercent, in: container, debugDescription: "numeric_usage_required"
            )
        }

        // resetAt: Int, Double 또는 숫자 문자열. 읽지 못하면 초기화 시각만 비운다.
        if let number = try? container.decode(Double.self, forKey: .resetAt) {
            resetAt = number
        } else if let text = try? container.decode(String.self, forKey: .resetAt), let number = Double(text) {
            resetAt = number
        } else {
            resetAt = nil
        }

        limitWindowSeconds = (try? container.decodeIfPresent(Int.self, forKey: .limitWindowSeconds)) ?? nil
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

    /// 창 길이 이름. 한도 목록 제목과 같은 규칙을 쓴다.
    nonisolated var windowDescription: String {
        guard let seconds = limitWindowSeconds, seconds > 0 else { return "" }
        return UsageLimitCatalog.periodTitle(seconds)
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
nonisolated struct CodexCredits: Codable, Sendable {
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
        return MoneyFormatter.credits(balance)
    }
}

// MARK: - 편의 기능

extension CodexUsageResponse {
    /// 하루(24시간) 기준 — 이 미만이면 세션 성격, 이상이면 주간 성격 창으로 분류
    nonisolated private static var sessionWindowMaxSeconds: Int { 24 * 3600 }

    /// 세션 성격(24시간 미만) 창.
    /// 2026-07 개편으로 주간 창이 primary 자리에 올 수 있어, 위치가 아니라
    /// limit_window_seconds 로 분류한다. 창 길이 미상이면 레거시 가정(primary=세션)을 따른다.
    nonisolated var sessionWindow: CodexUsageWindow? { sessionWindowWithSourceSlot?.window }

    nonisolated var sessionWindowWithSourceSlot: (window: CodexUsageWindow, slot: String)? {
        if let primary = rateLimit?.primaryWindow {
            if let seconds = primary.limitWindowSeconds {
                if seconds < Self.sessionWindowMaxSeconds { return (primary, "primary") }
            } else {
                return (primary, "primary")
            }
        }
        if let secondary = rateLimit?.secondaryWindow,
           let seconds = secondary.limitWindowSeconds,
           seconds < Self.sessionWindowMaxSeconds {
            return (secondary, "secondary")
        }
        return nil
    }

    /// 주간 성격(24시간 이상) 창.
    /// secondary 우선, 없으면 primary 가 주간 창인지 확인한다. 창 길이 미상 secondary 는 레거시 가정(주간).
    nonisolated var weeklyWindow: CodexUsageWindow? { weeklyWindowWithSourceSlot?.window }

    nonisolated var weeklyWindowWithSourceSlot: (window: CodexUsageWindow, slot: String)? {
        if let secondary = rateLimit?.secondaryWindow {
            if let seconds = secondary.limitWindowSeconds {
                if seconds >= Self.sessionWindowMaxSeconds { return (secondary, "secondary") }
            } else {
                return (secondary, "secondary")
            }
        }
        if let primary = rateLimit?.primaryWindow,
           let seconds = primary.limitWindowSeconds,
           seconds >= Self.sessionWindowMaxSeconds {
            return (primary, "primary")
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
    /// 세션 창이 없으면 0% 대신 주간 창을 기준으로 사용하고, 둘 다 없으면 nil.
    nonisolated var gaugePercentage: Double? {
        sessionWindow?.utilization ?? weeklyWindow?.utilization
    }

    /// 한도에 걸린 이유를 사용자가 할 일 기준으로 짧게. 공식 TUI 문구의 뜻을 따른다.
    nonisolated var workspaceLimitNotice: String? {
        switch rateLimitReachedType {
        case "workspace_owner_credits_depleted": return "워크스페이스 크레딧 소진 · 크레딧 추가 필요"
        case "workspace_member_credits_depleted": return "워크스페이스 크레딧 소진 · 소유자에게 추가 요청"
        case "workspace_owner_usage_limit_reached": return "워크스페이스 사용 한도 도달"
        case "workspace_member_usage_limit_reached": return "사용 한도 도달 · 소유자에게 한도 상향 요청"
        default: return supportsMonthlyLimit && spendControl?.reached == true ? "월 사용 한도 도달" : nil
        }
    }

    /// "현재 3% · 주간 41%" 요약. 세션 창이 없으면 주간만 표기.
    nonisolated var usageSummaryText: String {
        let session = sessionWindow.map { "5시간 \(PercentageText.string($0.utilization))" }
        let weekly = weeklyWindow.map { "주간 \(PercentageText.string($0.utilization))" }
        return [session, weekly].compactMap { $0 }.joined(separator: " · ").ifEmpty("데이터 없음")
    }
}

private extension String {
    nonisolated func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}

// MARK: - Rate Limit 초기화 크레딧 (app-server rateLimitResetCredits)

/// 사용량 초기화 크레딧 목록 응답
nonisolated struct CodexResetCreditsResponse: Codable, Sendable, Equatable {
    let credits: [CodexResetCredit]
    /// API가 내려주는 사용 가능 개수 (없으면 credits에서 계산)
    let availableCountField: Int?
    var accountID: String? = nil

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
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
        accountID = try container.decodeIfPresent(String.self, forKey: .accountID)

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

    nonisolated var hasCompleteExpirationDetails: Bool {
        let available = availableCredits()
        return available.count >= availableCount() && available.allSatisfy { $0.expiresDate != nil || $0.doesNotExpire }
    }

    /// Missing or capped IDs must not prevent a later refresh from obtaining them.
    nonisolated var hasCompleteDetails: Bool {
        hasCompleteExpirationDetails && Set(availableCredits().compactMap(\.id)).count >= availableCount()
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
nonisolated struct CodexResetCredit: Codable, Sendable, Equatable {
    let id: String?
    let resetType: String?
    let status: String
    let grantedAtISO: String?
    let expiresAtISO: String?
    let doesNotExpire: Bool
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
        doesNotExpire: Bool = false,
        title: String? = nil,
        detail: String? = nil)
    {
        self.id = id
        self.resetType = resetType
        self.status = status
        self.grantedAtISO = grantedAtISO
        self.expiresAtISO = expiresAtISO
        self.doesNotExpire = doesNotExpire
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
        doesNotExpire = container.contains(.expiresAt) && ((try? container.decodeNil(forKey: .expiresAt)) == true)
        title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? nil
        detail = (try? container.decodeIfPresent(String.self, forKey: .detail)) ?? nil
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(resetType, forKey: .resetType)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(grantedAtISO, forKey: .grantedAt)
        if doesNotExpire {
            try container.encodeNil(forKey: .expiresAt)
        } else {
            try container.encodeIfPresent(expiresAtISO, forKey: .expiresAt)
        }
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

extension CodexUsageResponse {
    nonisolated var isPersonalPlan: Bool {
        let personalPlans: Set<String> = ["guest", "free", "go", "plus", "pro", "prolite", "promax"]
        return planType.map { personalPlans.contains($0.lowercased()) } ?? false
    }

    nonisolated var supportsMonthlyLimit: Bool {
        !isPersonalPlan && spendControl?.individualLimit?.usedPercent != nil
    }

    /// 크레딧 요금표는 자주 바뀌어 앱에 담지 않고 공식 도움말로 연결한다. 워크스페이스 요금제에만 해당한다.
    nonisolated var workspaceRateCardURL: URL? {
        guard planType != nil, !isPersonalPlan else { return nil }
        return URL(
            string:
                "https://help.openai.com/en/articles/11481834-chatgpt-rate-card-business-enterpriseedu-credit-based-pricing"
        )
    }
}
