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

    /// `anchorIsUsable`는 버튼 윈도우가 실제로 메뉴바 밴드 안에 있는지다. 앱 내부
    /// 신호가 모두 정상인데도 항목이 바에 없는 경우를 이 값만 구분해 냈다(측정:
    /// 정상 `anchor=true`, 미표시 `anchor=false`, 나머지 필드는 양쪽 동일).
    ///
    /// 사용자가 항목을 직접 숨기면 AppKit이 버튼 윈도우를 내리므로 앵커도 사라진다.
    /// `reportsVisible`을 함께 보지 않으면 사용자가 끈 상태를 macOS가 차단한 것으로
    /// 읽고, 항목을 되살린 뒤 차단됐다는 안내까지 띄운다.
    static func isBlocked(
        _ evidence: StatusItemPlacementEvidence,
        detectTahoeBlockedStatusItem: Bool,
        anchorIsUsable: Bool
    ) -> Bool {
        if evidence.snapshot.expectsVisibility,
           evidence.snapshot.reportsVisible,
           !anchorIsUsable
        {
            return true
        }
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
        // 키가 없으면(`nil`) 사용자가 항목을 숨긴 적이 없다는 뜻이므로 실패로 본다.
        // `== true`만 받으면 한 번도 숨겨본 적 없는 기본 상태가 이 분기에서 빠졌다.
        if evidence.snapshot.expectsVisibility,
           evidence.visibilityDefault != false,
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

/// 팝오버는 상태 아이템 버튼을 기준으로 뜬다. 버튼 윈도우가 메뉴바 밖에 있으면
/// 앵커 없는 팝오버가 엉뚱한 위치에 뜨고, 사용자는 아이콘도 없이 떠 있는 창만 본다.
struct StatusItemAnchorSnapshot: Equatable, Sendable {
    let windowFrame: CGRect?
    let menuBarBands: [CGRect]
}

enum StatusItemAnchorPolicy {
    static func isUsable(_ snapshot: StatusItemAnchorSnapshot) -> Bool {
        guard let frame = snapshot.windowFrame else { return false }
        // 밴드 정보를 못 구한 경우는 판단 근거가 없으므로 기존 동작을 막지 않는다.
        guard !snapshot.menuBarBands.isEmpty else { return true }
        return snapshot.menuBarBands.contains { $0.intersects(frame) }
    }
}

/// 한 판정 주기의 측정과 그 측정으로 내린 판정을 함께 들고 다닌다. 판정과 로그가
/// 각각 다시 측정하면 기록에 남은 상태가 실제로 행동을 결정한 상태가 아니게 된다.
struct StatusItemPlacementAssessment: Equatable, CustomStringConvertible {
    let evidence: StatusItemPlacementEvidence
    let anchorSnapshot: StatusItemAnchorSnapshot
    let anchorIsUsable: Bool
    let isBlocked: Bool

    init(
        evidence: StatusItemPlacementEvidence,
        anchorSnapshot: StatusItemAnchorSnapshot,
        detectTahoeBlockedStatusItem: Bool
    ) {
        let anchorIsUsable =
            StatusItemAnchorPolicy.isUsable(anchorSnapshot)
        self.evidence = evidence
        self.anchorSnapshot = anchorSnapshot
        self.anchorIsUsable = anchorIsUsable
        self.isBlocked =
            StatusItemPlacementRecoveryPolicy.isBlocked(
                evidence,
                detectTahoeBlockedStatusItem:
                    detectTahoeBlockedStatusItem,
                anchorIsUsable: anchorIsUsable
            )
    }

    var description: String {
        "blocked=\(isBlocked) anchor=\(anchorIsUsable) "
            + evidence.description
    }
}

enum ApplicationReopenPolicy {
    static func action(
        hasVisibleWindows: Bool,
        statusItemIsBlocked: Bool,
        statusItemCanAnchorPopover: Bool
    ) -> ApplicationReopenAction {
        if hasVisibleWindows {
            return .useDefaultWindowHandling
        }
        if statusItemIsBlocked || !statusItemCanAnchorPopover {
            return .showStatusItemRecovery
        }
        return .showPopover
    }
}
