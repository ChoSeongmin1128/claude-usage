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
    let sevenDay: UsageWindow?
    let sevenDaySonnet: UsageWindow?  // 레거시 필드 (limits[]로 대체 중)
    let sevenDayOpus: UsageWindow?    // 레거시 필드 (limits[]로 대체 중)
    let scopedLimits: [ClaudeScopedLimit]

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOpus = "seven_day_opus"
        case scopedLimits = "limits"
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try container.decode(UsageWindow.self, forKey: .fiveHour)
        sevenDay = try container.decodeIfPresent(UsageWindow.self, forKey: .sevenDay)
        sevenDaySonnet = try container.decodeIfPresent(UsageWindow.self, forKey: .sevenDaySonnet)
        sevenDayOpus = try container.decodeIfPresent(UsageWindow.self, forKey: .sevenDayOpus)
        scopedLimits = Self.decodeScopedLimits(from: container)
    }

    nonisolated init(
        fiveHour: UsageWindow,
        sevenDay: UsageWindow?,
        sevenDaySonnet: UsageWindow? = nil,
        sevenDayOpus: UsageWindow? = nil,
        scopedLimits: [ClaudeScopedLimit] = [])
    {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDaySonnet = sevenDaySonnet
        self.sevenDayOpus = sevenDayOpus
        self.scopedLimits = scopedLimits
    }

    /// limits 배열은 항목 단위로 관대하게 디코딩합니다.
    /// 잘못된 항목 하나가 전체 사용량 파싱을 깨뜨리면 안 됩니다.
    nonisolated private static func decodeScopedLimits(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> [ClaudeScopedLimit] {
        guard var array = try? container.nestedUnkeyedContainer(forKey: .scopedLimits) else {
            return []
        }
        var collected: [ClaudeScopedLimit] = []
        while !array.isAtEnd {
            if let entry = try? array.decode(ClaudeScopedLimit.self) {
                collected.append(entry)
            } else if (try? array.decode(DecodingSink.self)) == nil {
                break
            }
        }
        return collected
    }
}

/// 임의 JSON 요소를 소비만 하는 싱크 (lossy 배열 디코딩용)
private struct DecodingSink: Decodable {
    nonisolated init(from decoder: Decoder) throws {}
}

/// `limits[]` 배열의 개별 한도 항목.
/// 현재 확인된 형태: `kind: "weekly_scoped"` + `scope.model.display_name` (예: "Fable")
struct ClaudeScopedLimit: Codable, Sendable, Equatable {
    let kind: String?
    let group: String?
    let percent: Double?
    let resetsAt: String?
    let modelID: String?
    let modelName: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case group
        case percent
        case resetsAt = "resets_at"
        case scope
    }

    private enum ScopeKeys: String, CodingKey {
        case model
    }

    private enum ModelKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }

    nonisolated init(
        kind: String?,
        group: String? = nil,
        percent: Double?,
        resetsAt: String? = nil,
        modelID: String? = nil,
        modelName: String?)
    {
        self.kind = kind
        self.group = group
        self.percent = percent
        self.resetsAt = resetsAt
        self.modelID = modelID
        self.modelName = modelName
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? container.decodeIfPresent(String.self, forKey: .kind)) ?? nil
        group = (try? container.decodeIfPresent(String.self, forKey: .group)) ?? nil

        // percent: Int/Double/String 방어 (UsageWindow.utilization과 동일 원칙)
        if let doubleVal = try? container.decode(Double.self, forKey: .percent) {
            percent = doubleVal
        } else if let intVal = try? container.decode(Int.self, forKey: .percent) {
            percent = Double(intVal)
        } else if let strVal = try? container.decode(String.self, forKey: .percent),
                  let parsed = Double(strVal) {
            percent = parsed
        } else {
            percent = nil
        }

        // resets_at: 문자열(ISO) 외에 숫자(unix seconds) 변형 방어 (UsageWindow와 동일)
        if let textVal = try? container.decode(String.self, forKey: .resetsAt),
           !textVal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmed = textVal.trimmingCharacters(in: .whitespacesAndNewlines)
            if let unix = Double(trimmed) {
                resetsAt = UsageWindow.isoString(fromUnixSeconds: unix)
            } else {
                resetsAt = trimmed
            }
        } else if let intVal = try? container.decode(Int.self, forKey: .resetsAt) {
            resetsAt = UsageWindow.isoString(fromUnixSeconds: Double(intVal))
        } else if let doubleVal = try? container.decode(Double.self, forKey: .resetsAt) {
            resetsAt = UsageWindow.isoString(fromUnixSeconds: doubleVal)
        } else {
            resetsAt = nil
        }

        if let scope = try? container.nestedContainer(keyedBy: ScopeKeys.self, forKey: .scope),
           let model = try? scope.nestedContainer(keyedBy: ModelKeys.self, forKey: .model) {
            modelID = (try? model.decodeIfPresent(String.self, forKey: .id)) ?? nil
            modelName = (try? model.decodeIfPresent(String.self, forKey: .displayName)) ?? nil
        } else {
            modelID = nil
            modelName = nil
        }
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(kind, forKey: .kind)
        try container.encodeIfPresent(group, forKey: .group)
        try container.encodeIfPresent(percent, forKey: .percent)
        try container.encodeIfPresent(resetsAt, forKey: .resetsAt)
    }
}

/// 팝오버에 표시하는 모델별 주간 한도 창 (limits[] + 레거시 필드 병합 결과)
struct ClaudeModelWeeklyWindow: Sendable, Equatable {
    let slug: String        // 표시 ID용 (예: "fable", "sonnet")
    let modelName: String   // 표시 이름 (예: "Fable")
    let utilization: Double
    let resetsAt: String?
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
        // resets_at: 문자열(ISO) 외에 숫자(unix seconds)로 내려오는 변형도 방어
        if let textVal = try? container.decode(String.self, forKey: .resetsAt),
           !textVal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmed = textVal.trimmingCharacters(in: .whitespacesAndNewlines)
            if let unix = Double(trimmed) {
                resetsAt = Self.isoString(fromUnixSeconds: unix)
            } else {
                resetsAt = trimmed
            }
        } else if let intVal = try? container.decode(Int.self, forKey: .resetsAt) {
            resetsAt = Self.isoString(fromUnixSeconds: Double(intVal))
        } else if let doubleVal = try? container.decode(Double.self, forKey: .resetsAt) {
            resetsAt = Self.isoString(fromUnixSeconds: doubleVal)
        } else {
            resetsAt = nil
        }

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

    nonisolated init(utilization: Double, resetsAt: String?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    nonisolated static func isoString(fromUnixSeconds seconds: Double) -> String {
        let date = Date(timeIntervalSince1970: seconds)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

// MARK: - 편의 기능

extension UsageWindow {
    /// 퍼센트를 정수로 반환 (67.5% → 67)
    nonisolated var percentageInt: Int {
        Int(utilization)
    }

    /// 갱신 예상 시간을 Date로 변환
    nonisolated var resetDate: Date? {
        guard let resetsAt = resetsAt else { return nil }
        return TimeFormatter.parseISO8601(resetsAt)
    }
}

extension ClaudeUsageResponse {
    /// 5시간 세션 퍼센트 (메인 표시용)
    nonisolated var fiveHourPercentage: Double {
        fiveHour.utilization
    }

    /// 주간 한도 퍼센트
    nonisolated var weeklyPercentage: Double {
        sevenDay?.utilization ?? 0
    }

    /// Sonnet 주간 퍼센트 (없으면 nil)
    nonisolated var sonnetPercentage: Double? {
        sevenDaySonnet?.utilization
    }

    /// Opus 주간 퍼센트 (없으면 nil)
    nonisolated var opusPercentage: Double? {
        sevenDayOpus?.utilization
    }

    /// 표시용 모델별 주간 한도 목록.
    /// limits[]의 weekly_scoped 항목(신형, 예: Fable)을 우선 사용하고,
    /// 레거시 seven_day_sonnet/seven_day_opus는 신형에 같은 모델이 없을 때만 보충합니다.
    nonisolated var modelWeeklyWindows: [ClaudeModelWeeklyWindow] {
        var windows: [ClaudeModelWeeklyWindow] = []
        var seenSlugs: Set<String> = []

        for limit in scopedLimits {
            guard limit.kind == "weekly_scoped" else { continue }
            if let group = limit.group, group != "weekly" { continue }
            guard let percent = limit.percent, percent.isFinite else { continue }
            guard let rawName = limit.modelName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawName.isEmpty else { continue }
            // 전체 모델 합산 스코프는 seven_day 주간 한도와 중복이므로 제외
            guard !Self.isAllModelsScope(modelID: limit.modelID, modelName: rawName) else { continue }

            let identity = limit.modelID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let slug = Self.modelSlug((identity?.isEmpty == false ? identity! : rawName))
            guard !slug.isEmpty, seenSlugs.insert(slug).inserted else { continue }

            windows.append(ClaudeModelWeeklyWindow(
                slug: slug,
                modelName: rawName,
                utilization: percent,
                resetsAt: limit.resetsAt
            ))
        }

        // 레거시 필드 보충 (신형 limits에 같은 모델이 없을 때만)
        let coveredText = seenSlugs.joined(separator: " ")
        if let sonnet = sevenDaySonnet, !coveredText.contains("sonnet") {
            windows.append(ClaudeModelWeeklyWindow(
                slug: "sonnet",
                modelName: "Sonnet",
                utilization: sonnet.utilization,
                resetsAt: sonnet.resetsAt
            ))
        }
        if let opus = sevenDayOpus, !coveredText.contains("opus") {
            windows.append(ClaudeModelWeeklyWindow(
                slug: "opus",
                modelName: "Opus",
                utilization: opus.utilization,
                resetsAt: opus.resetsAt
            ))
        }

        return windows
    }

    /// 소문자 영숫자 + 대시 슬러그 (모델 ID/이름 → 안정적인 표시 ID)
    nonisolated private static func modelSlug(_ value: String) -> String {
        var result = ""
        var lastWasDash = false
        for scalar in value.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    nonisolated private static func isAllModelsScope(modelID: String?, modelName: String) -> Bool {
        if modelSlug(modelName) == "all-models" { return true }
        guard let modelID, !modelID.isEmpty else { return false }
        let idSlug = modelSlug(modelID)
        return idSlug == "all-models" || idSlug.hasSuffix("-all-models")
    }
}

// MARK: - 추가 사용량 (Extra Usage / Overage)

/// 추가 사용량 API 응답 (금액은 센트 단위로 수신)
struct OverageSpendLimitResponse: Codable, Sendable, Equatable {
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

    nonisolated init(
        monthlyCreditLimitCents: Double,
        usedCreditsCents: Double,
        isEnabled: Bool,
        outOfCredits: Bool,
        currency: String
    ) {
        self.monthlyCreditLimitCents = monthlyCreditLimitCents
        self.usedCreditsCents = usedCreditsCents
        self.isEnabled = isEnabled
        self.outOfCredits = outOfCredits
        self.currency = currency
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

    /// Claude API가 확정적으로 제공하는 추가 사용량 값만 표시합니다.
    nonisolated var formattedUsageLimitSummary: String {
        "\(formattedUsedCredits) 사용 / \(formattedCreditLimit) 한도"
    }
}
