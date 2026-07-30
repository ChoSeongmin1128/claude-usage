// Antigravity provider-owned display domain.
import Foundation

nonisolated enum AntigravitySettingsMigrationNotice: String, Codable, Equatable, Sendable {
    case displaySelectionUpdated = "display_selection_updated"

    var title: String {
        switch self {
        case .displaySelectionUpdated:
            return "Antigravity 표시 설정이 새로 정리되었습니다"
        }
    }

    var message: String {
        switch self {
        case .displaySelectionUpdated:
            return "간소화 보기에서 여러 사용 한도를 함께 표시할 수 있습니다. 기존 선택은 유지되며 설정에서 표시 여부와 순서를 바꿀 수 있습니다."
        }
    }
}

nonisolated struct AntigravityDisplaySettings: Codable, Equatable, Sendable {
    nonisolated static let currentSchemaVersion = 2

    enum LaneOrderingPolicy: String, Codable, CaseIterable, Sendable {
        case manual
        case mostConstrainedFirst = "most_constrained_first"
    }

    enum SingleLaneSelectionPolicy: Codable, Equatable, Sendable {
        case automaticMostConstrained
        case fixed(AntigravityQuotaLaneID)

        private enum CodingKeys: String, CodingKey {
            case mode
            case laneID
        }

        private enum Mode: String, Codable {
            case automaticMostConstrained = "automatic_most_constrained"
            case fixed
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Mode.self, forKey: .mode) {
            case .automaticMostConstrained:
                self = .automaticMostConstrained
            case .fixed:
                let rawLaneID = try container.decode(String.self, forKey: .laneID)
                let laneID = AntigravityQuotaLaneID(rawValue: rawLaneID)
                guard laneID.hasStableDisplayIdentifierShape else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .laneID,
                        in: container,
                        debugDescription: "Invalid Antigravity quota lane identifier"
                    )
                }
                self = .fixed(laneID)
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .automaticMostConstrained:
                try container.encode(
                    Mode.automaticMostConstrained,
                    forKey: .mode
                )
            case let .fixed(laneID):
                guard laneID.hasStableDisplayIdentifierShape else {
                    throw EncodingError.invalidValue(
                        laneID,
                        EncodingError.Context(
                            codingPath: encoder.codingPath,
                            debugDescription: "Invalid Antigravity quota lane identifier"
                        )
                    )
                }
                try container.encode(Mode.fixed, forKey: .mode)
                try container.encode(laneID.rawValue, forKey: .laneID)
            }
        }

        var isValid: Bool {
            switch self {
            case .automaticMostConstrained:
                return true
            case let .fixed(laneID):
                return laneID.hasStableDisplayIdentifierShape
            }
        }
    }

    struct LaneListPresentationIntent: Codable, Equatable, Sendable {
        /// Stable preferred order. IDs that are observed later are appended by
        /// the presentation adapter and are visible unless explicitly hidden.
        var orderedLaneIDs: [AntigravityQuotaLaneID]
        var hiddenLaneIDs: Set<AntigravityQuotaLaneID>
        var orderingPolicy: LaneOrderingPolicy

        var isValid: Bool {
            orderedLaneIDs.count == Set(orderedLaneIDs).count
                && orderedLaneIDs.allSatisfy(
                    \.hasStableDisplayIdentifierShape
                )
                && hiddenLaneIDs.allSatisfy(
                    \.hasStableDisplayIdentifierShape
                )
        }
    }

    struct MenuBarPresentationIntent: Codable, Equatable, Sendable {
        enum Style: String, Codable, CaseIterable, Sendable {
            case none
            case batteryBar = "battery_bar"
            case circular
        }

        enum TimeFormat: String, Codable, CaseIterable, Sendable {
            case h24 = "24h"
            case h12 = "12h"
            case remaining
        }

        enum CircularValue: String, Codable, CaseIterable, Sendable {
            case usage
            case remaining
        }

        var isVisible: Bool
        var showsProviderIcon: Bool
        var style: Style
        var laneSelection: SingleLaneSelectionPolicy
        /// 대표 한도 외에 메뉴바 텍스트에 함께 표시할 한도입니다.
        /// Optional로 두어 기존 v2 JSON에 키가 없어도 그대로 decode합니다.
        var additionalLaneIDs: [AntigravityQuotaLaneID]? = nil
        var showsSelectedLanePercentage: Bool
        var showsSelectedLaneResetTime: Bool
        var timeFormat: TimeFormat
        var showsGaugePercentage: Bool
        var circularValue: CircularValue
    }

    struct NotificationPresentationIntent: Codable, Equatable, Sendable {
        var isEnabled: Bool
    }

    let schemaVersion: Int
    var standard: LaneListPresentationIntent
    var compact: LaneListPresentationIntent
    var menuBar: MenuBarPresentationIntent
    var notifications: NotificationPresentationIntent
    var pendingNotice: AntigravitySettingsMigrationNotice?

    static let `default` = AntigravityDisplaySettings(
        schemaVersion: currentSchemaVersion,
        standard: LaneListPresentationIntent(
            orderedLaneIDs: builtInLaneIDs,
            hiddenLaneIDs: [],
            orderingPolicy: .manual
        ),
        compact: LaneListPresentationIntent(
            orderedLaneIDs: builtInLaneIDs,
            hiddenLaneIDs: [],
            orderingPolicy: .mostConstrainedFirst
        ),
        menuBar: MenuBarPresentationIntent(
            isVisible: true,
            showsProviderIcon: true,
            style: .none,
            laneSelection: .automaticMostConstrained,
            showsSelectedLanePercentage: true,
            showsSelectedLaneResetTime: false,
            timeFormat: .h24,
            showsGaugePercentage: true,
            circularValue: .usage
        ),
        notifications: NotificationPresentationIntent(isEnabled: false),
        pendingNotice: nil
    )

    var isCurrentAndValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && standard.isValid
            && compact.isValid
            && menuBar.laneSelection.isValid
            && menuBar.effectiveAdditionalLaneIDs.count
                == Set(menuBar.effectiveAdditionalLaneIDs).count
            && menuBar.effectiveAdditionalLaneIDs.allSatisfy(
                \.hasStableDisplayIdentifierShape
            )
    }

    static let builtInLaneIDs: [AntigravityQuotaLaneID] = [
        .geminiFiveHour,
        .geminiWeekly,
        .thirdPartyFiveHour,
        .thirdPartyWeekly,
    ]
}

nonisolated extension AntigravityDisplaySettings.MenuBarPresentationIntent {
    var effectiveAdditionalLaneIDs: [AntigravityQuotaLaneID] {
        additionalLaneIDs ?? []
    }
}

nonisolated extension AntigravityQuotaLaneID {
    var hasStableDisplayIdentifierShape: Bool {
        let rawValue = rawValue
        guard
            !rawValue.isEmpty,
            rawValue.utf8.count <= 256,
            rawValue == rawValue.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        else {
            return false
        }

        let components = rawValue.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard components.count >= 2 else {
            return false
        }

        return components.allSatisfy { component in
            guard let first = component.utf8.first,
                  Self.isASCIIAlphaNumeric(first)
            else {
                return false
            }
            return component.utf8.dropFirst().allSatisfy { byte in
                Self.isASCIIAlphaNumeric(byte)
                    || byte == 0x2D
                    || byte == 0x5F
            }
        }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
            || (0x41...0x5A).contains(byte)
            || (0x61...0x7A).contains(byte)
    }
}
