import AppKit
import Foundation

struct StatusItemPlacementSnapshot: Equatable, CustomStringConvertible {
    let expectsVisibility: Bool
    let reportsVisible: Bool
    let hasButton: Bool
    let hasWindow: Bool
    let hasScreen: Bool
    let isOnCurrentScreen: Bool
    let buttonWidth: CGFloat

    var description: String {
        "expected=\(expectsVisibility),visible=\(reportsVisible),"
            + "button=\(hasButton),window=\(hasWindow),"
            + "screen=\(hasScreen),currentScreen=\(isOnCurrentScreen),"
            + "width=\(String(format: "%.1f", Double(buttonWidth)))"
    }
}

struct StatusItemPlacementEvidence:
    Equatable,
    CustomStringConvertible
{
    let autosaveName: String
    let visibilityDefault: Bool?
    let snapshot: StatusItemPlacementSnapshot
    let windowSnapshots:
        [StatusItemWindowSnapshot]

    var description: String {
        let windows =
            windowSnapshots.isEmpty
            ? "none"
            : windowSnapshots
                .map(\.description)
                .joined(separator: " | ")
        return "name=\(autosaveName),"
            + "default=\(visibilityDefault.map(String.init) ?? "unset"),"
            + "\(snapshot),windows=\(windows)"
    }
}

enum StatusItemPlacementRecoveryPolicy {
    static let startupCheckDelay: Duration = .seconds(2)
    static let recreationSettleDelay: Duration = .milliseconds(750)
    static let guidanceRepeatInterval: TimeInterval = 24 * 60 * 60
    static let guidanceLastShownAtKey =
        "statusItemPlacementGuidanceLastShownAt"
    static let preferredPositionPrefix =
        "NSStatusItem Preferred Position "
    static let suspiciousPreferredPositionPadding: Double = 512

    static let visibilityPrefix =
        "NSStatusItem VisibleCC "

    static func isMaterializationBlocked(
        _ snapshot: StatusItemPlacementSnapshot
    ) -> Bool {
        guard
            snapshot.expectsVisibility,
            snapshot.reportsVisible
        else {
            return false
        }
        return !snapshot.hasButton
            || !snapshot.hasWindow
            || snapshot.buttonWidth <= 0
    }

    static func isDisplaced(
        _ snapshot: StatusItemPlacementSnapshot
    ) -> Bool {
        guard
            snapshot.expectsVisibility,
            snapshot.reportsVisible,
            snapshot.hasButton,
            snapshot.hasWindow,
            snapshot.buttonWidth > 0
        else {
            return false
        }
        return !snapshot.hasScreen
            || !snapshot.isOnCurrentScreen
    }

    static func isBlocked(
        _ evidence: StatusItemPlacementEvidence,
        detectTahoeBlockedStatusItem: Bool
    ) -> Bool {
        if isMaterializationBlocked(
            evidence.snapshot
        ) {
            return true
        }
        guard detectTahoeBlockedStatusItem else {
            return false
        }

        let hasHealthyProxy =
            evidence.windowSnapshots.contains {
                $0.isOnscreen
                    && $0.isWithinDisplayBounds
            }
        if evidence.snapshot.expectsVisibility,
           evidence.visibilityDefault == true,
           !evidence.snapshot.reportsVisible,
           !evidence.snapshot.hasWindow,
           !hasHealthyProxy
        {
            return true
        }

        return isDisplaced(evidence.snapshot)
            && evidence.windowSnapshots
                .contains(where: \.isTahoeBlockedProxy)
    }

    static func visibilityDefault(
        defaults: UserDefaults,
        autosaveName: String
    ) -> Bool? {
        guard !autosaveName.isEmpty else {
            return nil
        }
        let value = defaults.object(
            forKey:
                visibilityPrefix + autosaveName
        )
        switch value {
        case let number as NSNumber:
            return number.boolValue
        case let bool as Bool:
            return bool
        default:
            return nil
        }
    }

    static func shouldShowGuidance(
        defaults: UserDefaults,
        now: Date = Date()
    ) -> Bool {
        let lastShownAt = defaults.double(
            forKey: guidanceLastShownAtKey
        )
        guard lastShownAt > 0 else {
            return true
        }
        return now.timeIntervalSince1970
            - lastShownAt
            >= guidanceRepeatInterval
    }

    static func markGuidanceShown(
        defaults: UserDefaults,
        now: Date = Date()
    ) {
        defaults.set(
            now.timeIntervalSince1970,
            forKey: guidanceLastShownAtKey
        )
    }

    static func preferredPositionKey(
        autosaveName: String
    ) -> String {
        preferredPositionPrefix + autosaveName
    }

    @discardableResult
    static func clearInvalidPreferredPosition(
        defaults: UserDefaults,
        autosaveName: String,
        legacyDefaultItemIndex: Int? = nil,
        maximumPreferredPosition: Double?
    ) -> [String] {
        var repairedKeys: [String] = []
        var names = [autosaveName]
        if let legacyDefaultItemIndex {
            names.append(
                "Item-\(legacyDefaultItemIndex)"
            )
        }

        for name in names {
            let key = preferredPositionKey(
                autosaveName: name
            )
            guard let value = defaults.object(forKey: key),
                  shouldClearPreferredPosition(
                      value,
                      maximumPreferredPosition:
                          maximumPreferredPosition
                  )
            else {
                continue
            }
            defaults.removeObject(forKey: key)
            repairedKeys.append(key)
        }
        return repairedKeys
    }

    static func shouldClearPreferredPosition(
        _ value: Any,
        maximumPreferredPosition: Double?
    ) -> Bool {
        guard let number = value as? NSNumber else {
            return true
        }
        let position = number.doubleValue
        guard position > 0 else {
            return true
        }
        guard let maximumPreferredPosition else {
            return false
        }
        return position
            > maximumPreferredPosition
                + suspiciousPreferredPositionPadding
    }
}

enum ApplicationReopenAction: Equatable {
    case useDefaultWindowHandling
    case showStatusItemRecovery
    case showPopover
}

enum ApplicationReopenPolicy {
    static func action(
        hasVisibleWindows: Bool,
        statusItemIsBlocked: Bool
    ) -> ApplicationReopenAction {
        if hasVisibleWindows {
            return .useDefaultWindowHandling
        }
        if statusItemIsBlocked {
            return .showStatusItemRecovery
        }
        return .showPopover
    }
}
