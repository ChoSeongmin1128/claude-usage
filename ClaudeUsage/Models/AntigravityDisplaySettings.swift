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
            return "이제 남은 여유가 가장 적은 사용 한도를 우선 보여줍니다. 설정에서 언제든 표시 기준을 바꿀 수 있습니다."
        }
    }
}

nonisolated struct AntigravityDisplaySettings: Codable, Equatable, Sendable {
    nonisolated static let currentSchemaVersion = 1

    enum MultiLaneSelectionPolicy: String, Codable, CaseIterable, Sendable {
        case allKnown = "all_known"
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
                guard Self.hasStableLaneIDShape(laneID) else {
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
                guard Self.hasStableLaneIDShape(laneID) else {
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
                return Self.hasStableLaneIDShape(laneID)
            }
        }

        private static func hasStableLaneIDShape(
            _ laneID: AntigravityQuotaLaneID
        ) -> Bool {
            let rawValue = laneID.rawValue
            guard
                !rawValue.isEmpty,
                rawValue.utf8.count <= 256,
                rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
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
                guard let first = component.utf8.first, Self.isASCIIAlphaNumeric(first) else {
                    return false
                }
                return component.utf8.dropFirst().allSatisfy { byte in
                    Self.isASCIIAlphaNumeric(byte) || byte == 0x2D || byte == 0x5F
                }
            }
        }

        private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
            (0x30...0x39).contains(byte)
                || (0x41...0x5A).contains(byte)
                || (0x61...0x7A).contains(byte)
        }
    }

    struct MultiLanePresentationIntent: Codable, Equatable, Sendable {
        var laneSelection: MultiLaneSelectionPolicy
    }

    struct SingleLanePresentationIntent: Codable, Equatable, Sendable {
        var laneSelection: SingleLaneSelectionPolicy
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
    var standard: MultiLanePresentationIntent
    var compact: SingleLanePresentationIntent
    var menuBar: MenuBarPresentationIntent
    var notifications: NotificationPresentationIntent
    var pendingNotice: AntigravitySettingsMigrationNotice?

    static let `default` = AntigravityDisplaySettings(
        schemaVersion: currentSchemaVersion,
        standard: MultiLanePresentationIntent(laneSelection: .allKnown),
        compact: SingleLanePresentationIntent(
            laneSelection: .automaticMostConstrained
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
            && compact.laneSelection.isValid
            && menuBar.laneSelection.isValid
    }
}
