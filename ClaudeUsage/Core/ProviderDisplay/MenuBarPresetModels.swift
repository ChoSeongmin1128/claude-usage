import Foundation

nonisolated enum MenuBarBuiltinPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case number, battery, circle, twoLimits, concentric

    var id: String { rawValue }
    var title: String {
        switch self {
        case .number: "숫자"
        case .battery: "배터리"
        case .circle: "원형"
        case .twoLimits: "두 한도"
        case .concentric: "동심원"
        }
    }

    func supports(_ provider: AppProviderKind) -> Bool {
        provider != .antigravity || self == .number || self == .battery || self == .concentric
    }
}

nonisolated struct CatalogMenuBarPresetDisplay: Codable, Equatable, Sendable {
    var showsLogo: Bool
    var style: MenuBarStyle
    var percentage: PercentageDisplay
    var gaugeNumber: Bool
    var resetTime: ResetTimeDisplay
    var iconMetric: IconMetric
    var selection: MenuBarQuotaSelection?
    var gauges: MenuBarGaugeSelection?
    var resetCredits: String

    @MainActor init(config: ProviderMenuBarDisplayConfig, resetCredits: ResetCreditMenuBarMode) {
        showsLogo = config.showIcon
        style = config.style
        percentage = config.percentageDisplay
        gaugeNumber = config.showBatteryPercent
        resetTime = config.resetTimeDisplay
        iconMetric = config.iconMetric
        selection = config.quotaSelection
        gauges = config.gaugeSelection
        self.resetCredits = resetCredits.rawValue
    }

    @MainActor func config(preserving current: ProviderMenuBarDisplayConfig) -> ProviderMenuBarDisplayConfig {
        ProviderMenuBarDisplayConfig(
            kind: current.kind, showIcon: showsLogo, style: style, percentageDisplay: percentage,
            showBatteryPercent: gaugeNumber, resetTimeDisplay: resetTime, timeFormat: current.timeFormat,
            circularDisplayMode: current.circularDisplayMode, iconMetric: iconMetric,
            colorMode: current.colorMode, design: current.design, basisOverride: current.basisOverride,
            quotaSelection: selection, gaugeSelection: gauges)
    }

    var isValid: Bool {
        ResetCreditMenuBarMode(rawValue: resetCredits) != nil
            && (selection?.arrangement?.isValid ?? true)
            && [selection?.percentageIDs, selection?.resetIDs, selection?.gaugeIDs, gauges?.ids]
                .compactMap { $0 }.allSatisfy { $0.count == Set($0).count && $0.allSatisfy { !$0.isEmpty } }
    }
}

// Existing live settings decode leniently; saved preset definitions must never silently repair themselves.
nonisolated extension CatalogMenuBarPresetDisplay {
    private enum CodingKeys: String, CodingKey {
        case showsLogo, style, percentage, gaugeNumber, resetTime, iconMetric, selection, gauges, resetCredits
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        showsLogo = try values.decode(Bool.self, forKey: .showsLogo)
        style = try values.decode(MenuBarStyle.self, forKey: .style)
        percentage = try values.decode(PercentageDisplay.self, forKey: .percentage)
        gaugeNumber = try values.decode(Bool.self, forKey: .gaugeNumber)
        resetTime = try values.decode(ResetTimeDisplay.self, forKey: .resetTime)
        iconMetric = try values.decode(IconMetric.self, forKey: .iconMetric)
        selection = try values.decodeIfPresent(StrictPresetQuotaSelection.self, forKey: .selection)?.value
        gauges = try values.decodeIfPresent(StrictPresetGaugeSelection.self, forKey: .gauges)?.value
        resetCredits = try values.decode(String.self, forKey: .resetCredits)
    }
}

private nonisolated struct StrictPresetQuotaSelection: Decodable {
    let value: MenuBarQuotaSelection
    private enum CodingKeys: String, CodingKey {
        case percentageIDs, resetIDs, gaugeIDs, titles, arrangement, legacyPercentageDisplay, legacyResetTimeDisplay
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let arrangement = try values.decodeIfPresent(MenuBarQuotaArrangement.self, forKey: .arrangement)
        guard arrangement?.isValid != false else {
            throw DecodingError.dataCorruptedError(
                forKey: .arrangement, in: values, debugDescription: "Invalid preset arrangement")
        }
        value = MenuBarQuotaSelection(
            percentageIDs: try values.decode([String].self, forKey: .percentageIDs),
            resetIDs: try values.decode([String].self, forKey: .resetIDs),
            gaugeIDs: try values.decode([String].self, forKey: .gaugeIDs),
            titles: try values.decode([String: String].self, forKey: .titles), arrangement: arrangement,
            legacyPercentageDisplay: try values.decodeIfPresent(
                PercentageDisplay.self, forKey: .legacyPercentageDisplay),
            legacyResetTimeDisplay: try values.decodeIfPresent(ResetTimeDisplay.self, forKey: .legacyResetTimeDisplay))
    }
}

private nonisolated struct StrictPresetGaugeSelection: Decodable {
    let value: MenuBarGaugeSelection
    private enum CodingKeys: String, CodingKey { case ids, titles, layout, showsLabels }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        value = MenuBarGaugeSelection(
            ids: try values.decodeIfPresent([String].self, forKey: .ids),
            titles: try values.decode([String: String].self, forKey: .titles),
            layout: try values.decode(MenuBarGaugeLayout.self, forKey: .layout),
            showsLabels: try values.decodeIfPresent(Bool.self, forKey: .showsLabels))
    }
}

nonisolated struct AntigravityMenuBarPresetDisplay: Codable, Equatable, Sendable {
    var showsLogo: Bool
    var style: AntigravityDisplaySettings.MenuBarPresentationIntent.Style
    var laneSelection: AntigravityDisplaySettings.SingleLaneSelectionPolicy
    var additionalIDs: [AntigravityQuotaLaneID]?
    var percentageIDs: [AntigravityQuotaLaneID]?
    var resetIDs: [AntigravityQuotaLaneID]?
    var gaugeIDs: [AntigravityQuotaLaneID]?
    var gaugeTitles: [String: String]?
    var showsGaugeLabels: Bool?
    var arrangement: MenuBarQuotaArrangement?
    var primaryPercentage: Bool
    var primaryReset: Bool
    var gaugeNumber: Bool

    init(_ menuBar: AntigravityDisplaySettings.MenuBarPresentationIntent) {
        showsLogo = menuBar.showsProviderIcon
        style = menuBar.style
        laneSelection = menuBar.laneSelection
        additionalIDs = menuBar.additionalLaneIDs
        percentageIDs = menuBar.percentageLaneIDs
        resetIDs = menuBar.resetLaneIDs
        gaugeIDs = menuBar.gaugeLaneIDs
        gaugeTitles = menuBar.gaugeTitles
        showsGaugeLabels = menuBar.showsGaugeLabels
        arrangement = menuBar.arrangement
        primaryPercentage = menuBar.showsSelectedLanePercentage
        primaryReset = menuBar.showsSelectedLaneResetTime
        gaugeNumber = menuBar.showsGaugePercentage
    }

    func applying(to current: AntigravityDisplaySettings) -> AntigravityDisplaySettings {
        var result = current
        result.menuBar.showsProviderIcon = showsLogo
        result.menuBar.style = style
        result.menuBar.laneSelection = laneSelection
        result.menuBar.additionalLaneIDs = additionalIDs
        result.menuBar.percentageLaneIDs = percentageIDs
        result.menuBar.resetLaneIDs = resetIDs
        result.menuBar.gaugeLaneIDs = gaugeIDs
        result.menuBar.gaugeTitles = gaugeTitles
        result.menuBar.showsGaugeLabels = showsGaugeLabels
        result.menuBar.arrangement = arrangement
        result.menuBar.showsSelectedLanePercentage = primaryPercentage
        result.menuBar.showsSelectedLaneResetTime = primaryReset
        result.menuBar.showsGaugePercentage = gaugeNumber
        return result
    }

    var isValid: Bool {
        applying(to: .default).isCurrentAndValid
    }
}

nonisolated enum MenuBarPresetDisplay: Codable, Equatable, Sendable {
    case catalog(CatalogMenuBarPresetDisplay)
    case antigravity(AntigravityMenuBarPresetDisplay)

    func isValid(for provider: AppProviderKind) -> Bool {
        switch self {
        case .catalog(let value): provider != .antigravity && value.isValid
        case .antigravity(let value): provider == .antigravity && value.isValid
        }
    }
}

nonisolated struct MenuBarUserPreset: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let provider: AppProviderKind
    var name: String
    var display: MenuBarPresetDisplay

    var isValid: Bool {
        MenuBarPresetName.normalized(name) == name && display.isValid(for: provider)
    }
}

nonisolated struct MenuBarPresetReference: Codable, Equatable, Sendable {
    enum Origin: String, Codable, Sendable { case builtin, user }
    let origin: Origin
    let id: String
    var selectedQuotaIDs: [String]? = nil

    static func builtin(_ preset: MenuBarBuiltinPreset, selectedQuotaIDs: [String]? = nil) -> Self {
        Self(origin: .builtin, id: preset.id, selectedQuotaIDs: selectedQuotaIDs)
    }

    static func user(_ preset: MenuBarUserPreset) -> Self {
        Self(origin: .user, id: preset.id.uuidString)
    }

    var isValid: Bool {
        (origin == .builtin ? MenuBarBuiltinPreset(rawValue: id) != nil : UUID(uuidString: id) != nil)
            && (selectedQuotaIDs.map { $0.count == Set($0).count && $0.allSatisfy { !$0.isEmpty } } ?? true)
    }
}

nonisolated enum MenuBarPresetName {
    static let maximumLength = 32

    static func normalized(_ name: String) -> String? {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...maximumLength).contains(value.count) ? value : nil
    }

    static func comparisonKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }
}
