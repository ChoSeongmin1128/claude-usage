//
//  UsageModels.swift
//  ClaudeUsage
//
//  API 응답 데이터 모델 (실제 Claude.ai API 구조 기반)
//

import Foundation

/// Claude.ai API 전체 응답 구조
nonisolated struct ClaudeUsageResponse: Codable, Sendable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDaySonnet: UsageWindow?  // 레거시 필드 (limits[]로 대체 중)
    let sevenDayOpus: UsageWindow?    // 레거시 필드 (limits[]로 대체 중)
    let scopedLimits: [ClaudeScopedLimit]
    let extraUsage: OverageSpendLimitResponse?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOpus = "seven_day_opus"
        case scopedLimits = "limits"
    }

    private enum ExtraUsageKeys: String, CodingKey {
        case extraUsage = "extra_usage"
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 없거나 null인 창은 그 요금제에 없는 창이다(사용량 기반 Enterprise 등).
        // 형식이 깨진 창은 그 창만 버리고, 그릴 창이 하나도 안 남을 때만 형식 오류로 본다.
        var hasMalformedWindow = false
        func window(_ key: CodingKeys) -> UsageWindow? {
            guard container.contains(key), (try? container.decodeNil(forKey: key)) != true else { return nil }
            if let decoded = try? container.decode(UsageWindow.self, forKey: key) { return decoded }
            hasMalformedWindow = true
            return nil
        }
        let limits = Self.decodeScopedLimits(from: container)
        // limits[]는 서버가 그리라고 주는 목록이다. 전용 필드가 없으면 kind로 같은 창을 찾는다.
        fiveHour = window(.fiveHour) ?? Self.unscopedWindow(kind: "session", in: limits)
        sevenDay = window(.sevenDay) ?? Self.unscopedWindow(kind: "weekly_all", in: limits)
        sevenDaySonnet = window(.sevenDaySonnet)
        sevenDayOpus = window(.sevenDayOpus)
        scopedLimits = limits
        extraUsage =
            (try? decoder.container(keyedBy: ExtraUsageKeys.self))
            .flatMap { try? $0.decodeIfPresent(ClaudeExtraUsage.self, forKey: .extraUsage) }?.overage
        if hasMalformedWindow, fiveHour == nil, sevenDay == nil, sevenDaySonnet == nil, sevenDayOpus == nil,
            scopedLimits.isEmpty
        {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Claude usage windows are malformed"))
        }
    }

    nonisolated init(
        fiveHour: UsageWindow?,
        sevenDay: UsageWindow?,
        sevenDaySonnet: UsageWindow? = nil,
        sevenDayOpus: UsageWindow? = nil,
        scopedLimits: [ClaudeScopedLimit] = [],
        extraUsage: OverageSpendLimitResponse? = nil
    )
    {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDaySonnet = sevenDaySonnet
        self.sevenDayOpus = sevenDayOpus
        self.scopedLimits = scopedLimits
        self.extraUsage = extraUsage
    }

    nonisolated private static func unscopedWindow(kind: String, in limits: [ClaudeScopedLimit]) -> UsageWindow? {
        guard let limit = limits.first(where: { $0.kind == kind && $0.isUnscoped }),
            let percent = limit.percent, percent.isFinite, percent >= 0
        else { return nil }
        return UsageWindow(utilization: percent, resetsAt: limit.resetsAt)
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
nonisolated struct ClaudeScopedLimit: Codable, Sendable, Equatable {
    let kind: String?
    let group: String?
    let percent: Double?
    let resetsAt: String?
    let modelID: String?
    let modelName: String?
    var surfaceID: String? = nil
    var surfaceName: String? = nil

    enum CodingKeys: String, CodingKey {
        case kind
        case group
        case percent
        case resetsAt = "resets_at"
        case scope
    }

    private enum ScopeKeys: String, CodingKey {
        case model
        case surface
    }

    nonisolated var isUnscoped: Bool {
        modelID == nil && modelName == nil && surfaceID == nil && surfaceName == nil
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

        let scope = try? container.nestedContainer(keyedBy: ScopeKeys.self, forKey: .scope)
        if let model = try? scope?.nestedContainer(keyedBy: ModelKeys.self, forKey: .model) {
            modelID = (try? model.decodeIfPresent(String.self, forKey: .id)) ?? nil
            modelName = (try? model.decodeIfPresent(String.self, forKey: .displayName)) ?? nil
        } else {
            modelID = nil
            modelName = nil
        }
        if let surface = try? scope?.nestedContainer(keyedBy: ModelKeys.self, forKey: .surface) {
            surfaceID = (try? surface.decodeIfPresent(String.self, forKey: .id)) ?? nil
            surfaceName = (try? surface.decodeIfPresent(String.self, forKey: .displayName)) ?? nil
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
nonisolated struct ClaudeModelWeeklyWindow: Sendable, Equatable {
    let slug: String        // 표시 ID용 (예: "fable", "sonnet")
    let modelName: String   // 표시 이름 (예: "Fable")
    let utilization: Double
    let resetsAt: String?
    var sourceID: String? = nil
}

/// 개별 사용량 윈도우 (5시간, 주간, Sonnet, Opus)
nonisolated struct UsageWindow: Codable, Sendable {
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
            throw DecodingError.dataCorruptedError(
                forKey: .utilization, in: container, debugDescription: "numeric_usage_required")
        }
        guard utilization.isFinite, utilization >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .utilization, in: container, debugDescription: "valid_numeric_usage_required")
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
    /// 5시간 세션 퍼센트. 창이 없으면 nil
    nonisolated var fiveHourPercentage: Double? {
        fiveHour?.utilization
    }

    /// 주간 한도 퍼센트. 창이 없으면 nil
    nonisolated var weeklyPercentage: Double? {
        sevenDay?.utilization
    }

    nonisolated var hasSessionWindow: Bool {
        fiveHour != nil
    }

    /// 메뉴바 색상과 단일 퍼센트 기준. 5시간 창이 없으면 0% 대신 주간 창을 쓴다.
    nonisolated var gaugePercentage: Double? {
        fiveHour?.utilization ?? sevenDay?.utilization
    }

    /// "현재 3% · 주간 41%" 요약. 없는 창은 빼고, 둘 다 없으면 "데이터 없음".
    nonisolated var usageSummaryText: String {
        let session = fiveHour.map { "5시간 \(PercentageText.string($0.utilization))" }
        let weekly = sevenDay.map { "주간 \(PercentageText.string($0.utilization))" }
        let parts = [session, weekly].compactMap { $0 }
        return parts.isEmpty ? "데이터 없음" : parts.joined(separator: " · ")
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
        // Preserve source duplicates for the common catalog's collision check.
        var windows = scopedLimits.compactMap(\.modelWeeklyWindow)

        // 레거시 필드 보충 (신형 limits에 같은 모델이 없을 때만)
        let coveredText = windows.map { $0.slug + " " + $0.modelName.lowercased() }.joined(separator: " ")
        if let sonnet = sevenDaySonnet, !coveredText.contains("sonnet") {
            windows.append(ClaudeModelWeeklyWindow(
                slug: "sonnet",
                modelName: "Sonnet",
                utilization: sonnet.utilization,
                    resetsAt: sonnet.resetsAt, sourceID: "legacy-seven-day-sonnet"
            ))
        }
        if let opus = sevenDayOpus, !coveredText.contains("opus") {
            windows.append(ClaudeModelWeeklyWindow(
                slug: "opus",
                modelName: "Opus",
                utilization: opus.utilization,
                    resetsAt: opus.resetsAt, sourceID: "legacy-seven-day-opus"
            ))
        }

        return windows
    }

    /// 소문자 영숫자 + 대시 슬러그 (모델 ID/이름 → 안정적인 표시 ID)
    nonisolated static func modelSlug(_ value: String) -> String {
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

    nonisolated static func isAllModelsScope(modelID: String?, modelName: String) -> Bool {
        if modelSlug(modelName) == "all-models" { return true }
        guard let modelID, !modelID.isEmpty else { return false }
        let idSlug = modelSlug(modelID)
        return idSlug == "all-models" || idSlug.hasSuffix("-all-models")
    }
}

// MARK: - 추가 사용량 (Extra Usage / Overage)

/// 추가 사용량 API 응답 (금액은 센트 단위로 수신)
nonisolated struct OverageSpendLimitResponse: Codable, Sendable, Equatable {
    let monthlyCreditLimitCents: Double?  // 월별 한도 (최소 단위). null이면 한도 없음
    let usedCreditsCents: Double  // 사용한 금액 (최소 단위)
    let isEnabled: Bool                  // Extra Usage 활성 여부
    let outOfCredits: Bool               // 크레딧 소진 여부
    let currency: String  // 통화 코드
    let decimalPlaces: Int?  // 서버가 준 소수 자릿수

    enum CodingKeys: String, CodingKey {
        case monthlyCreditLimitCents = "monthly_credit_limit"
        case usedCreditsCents = "used_credits"
        case isEnabled = "is_enabled"
        case outOfCredits = "out_of_credits"
        case currency
        case decimalPlaces = "decimal_places"
    }

    nonisolated init(
        monthlyCreditLimitCents: Double?,
        usedCreditsCents: Double,
        isEnabled: Bool,
        outOfCredits: Bool,
        currency: String,
        decimalPlaces: Int? = nil
    ) {
        self.monthlyCreditLimitCents = monthlyCreditLimitCents
        self.usedCreditsCents = usedCreditsCents
        self.isEnabled = isEnabled
        self.outOfCredits = outOfCredits
        self.currency = currency
        self.decimalPlaces = decimalPlaces
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let doubleVal = try? container.decode(Double.self, forKey: .monthlyCreditLimitCents) {
            monthlyCreditLimitCents = doubleVal
        } else if let intVal = try? container.decode(Int.self, forKey: .monthlyCreditLimitCents) {
            monthlyCreditLimitCents = Double(intVal)
        } else {
            monthlyCreditLimitCents = nil
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
        decimalPlaces = (try? container.decode(Int.self, forKey: .decimalPlaces)) ?? nil
    }
}

/// 사용량 응답의 `extra_usage`. 추가 사용량 API와 키 이름이 달라 따로 읽는다.
nonisolated struct ClaudeExtraUsage: Decodable, Sendable {
    let overage: OverageSpendLimitResponse

    private enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case currency
        case decimalPlaces = "decimal_places"
        case spendLimitReached = "spend_limit_reached"
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func number(_ key: CodingKeys) -> Double? {
            (try? container.decode(Double.self, forKey: key))
                ?? (try? container.decode(String.self, forKey: key)).flatMap(Double.init)
        }
        overage = OverageSpendLimitResponse(
            monthlyCreditLimitCents: number(.monthlyLimit),
            usedCreditsCents: number(.usedCredits) ?? 0,
            isEnabled: (try? container.decode(Bool.self, forKey: .isEnabled)) ?? false,
            outOfCredits: (try? container.decode(Bool.self, forKey: .spendLimitReached)) ?? false,
            currency: (try? container.decode(String.self, forKey: .currency)) ?? "USD",
            decimalPlaces: try? container.decode(Int.self, forKey: .decimalPlaces))
    }
}

extension OverageSpendLimitResponse {
    nonisolated static let notEnabled = OverageSpendLimitResponse(
        monthlyCreditLimitCents: nil, usedCreditsCents: 0, isEnabled: false, outOfCredits: false, currency: "USD")

    private nonisolated var minorUnitDivisor: Double {
        pow(10, Double(decimalPlaces ?? 2))
    }

    /// 통화 단위 한도. 한도가 없으면 nil
    nonisolated var monthlyCreditLimit: Double? {
        monthlyCreditLimitCents.map { $0 / minorUnitDivisor }
    }

    /// 통화 단위 사용 금액
    nonisolated var usedCredits: Double {
        usedCreditsCents / minorUnitDivisor
    }

    /// 사용률 퍼센트 (0~100). 한도가 없으면 nil
    nonisolated var usagePercentage: Double? {
        guard let limit = monthlyCreditLimitCents, limit > 0 else { return nil }
        return (usedCreditsCents / limit) * 100
    }

    nonisolated var formattedUsedCredits: String {
        MoneyFormatter.string(minorUnits: usedCreditsCents, currency: currency, decimalPlaces: decimalPlaces)
    }

    nonisolated var formattedCreditLimit: String {
        guard let limit = monthlyCreditLimitCents else { return "한도 없음" }
        return MoneyFormatter.string(minorUnits: limit, currency: currency, decimalPlaces: decimalPlaces)
    }

    /// Claude API가 확정적으로 제공하는 추가 사용량 값만 표시합니다.
    nonisolated var formattedUsageLimitSummary: String {
        let limit = monthlyCreditLimitCents == nil ? formattedCreditLimit : "\(formattedCreditLimit) 한도"
        let summary = "\(formattedUsedCredits) 사용 / \(limit)"
        return outOfCredits ? summary + " · 크레딧 소진" : summary
    }

    /// 헤드라인 값. 한도가 있으면 사용률, 없으면 사용 금액
    nonisolated var headlineText: String {
        usagePercentage.map(PercentageText.string) ?? formattedUsedCredits
    }
}


extension ClaudeScopedLimit {
    /// Decode one known scope shape without deduplicating distinct source IDs.
    nonisolated var modelWeeklyWindow: ClaudeModelWeeklyWindow? {
        guard kind == "weekly_scoped", group == nil || group == "weekly",
            let percent, percent.isFinite,
            let name = (modelName ?? surfaceName)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
            !ClaudeUsageResponse.isAllModelsScope(modelID: modelID, modelName: name)
        else { return nil }
        // 모델이 아닌 사용처(surface) 한도도 서버가 준 이름 그대로 그린다. 모델 ID와 겹치지 않게 구분한다.
        let rawIdentity = modelName != nil ? modelID : surfaceID.map { "surface:\($0)" }
        let identity = rawIdentity?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceID = identity?.isEmpty == false ? identity : nil
        let slug = ClaudeUsageResponse.modelSlug(sourceID ?? name)
        guard !slug.isEmpty else { return nil }
        return ClaudeModelWeeklyWindow(
            slug: slug, modelName: name, utilization: percent,
            resetsAt: resetsAt, sourceID: sourceID)
    }
}
