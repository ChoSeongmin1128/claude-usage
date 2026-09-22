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

    /// 생성 실패와 기존 시스템 지문만 복구 근거로 사용한다. 메뉴바 관리 앱의
    /// 숨김 배치도 앵커를 화면 밖으로 옮길 수 있으므로 위치만으로 재생성하지 않는다.
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
    case showSettings
    case showStatusItemRecovery
    case showPopover
}

/// 팝오버는 상태 아이템 버튼을 기준으로 뜬다. 버튼 윈도우가 메뉴바 밖에 있으면
/// 앵커 없는 팝오버가 엉뚱한 위치에 뜨고, 사용자는 아이콘도 없이 떠 있는 창만 본다.
struct StatusItemAnchorSnapshot: Equatable, Sendable, CustomStringConvertible {
    let windowFrame: CGRect?
    let menuBarBands: [CGRect]

    var description: String {
        let frame = windowFrame.map { NSStringFromRect($0) } ?? "none"
        let bands = menuBarBands.map { NSStringFromRect($0) }.joined(separator: " | ")
        return "windowFrame=\(frame) menuBarBands=[\(bands)]"
    }
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

    /// 저장된 숨김 선택과 현재 비표시 상태가 함께 있어야 사용자 의도로 본다.
    /// 키가 없거나 실제로 표시 중이면 앵커 실패를 숨김 선택으로 덮지 않는다.
    var isUserHidden: Bool {
        evidence.visibilityDefault == false
            && !evidence.snapshot.reportsVisible
    }

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
                    detectTahoeBlockedStatusItem
            )
    }

    var description: String {
        "blocked=\(isBlocked) anchor=\(anchorIsUsable) "
            + evidence.description
            + " " + anchorSnapshot.description
    }
}

enum ApplicationReopenPolicy {
    static func action(
        hasVisibleWindows: Bool,
        placement: StatusItemPlacementAssessment
    ) -> ApplicationReopenAction {
        if hasVisibleWindows {
            return .useDefaultWindowHandling
        }
        if placement.isUserHidden {
            return .showSettings
        }
        if placement.isBlocked {
            return .showStatusItemRecovery
        }
        if !placement.anchorIsUsable {
            return .showSettings
        }
        return .showPopover
    }
}
