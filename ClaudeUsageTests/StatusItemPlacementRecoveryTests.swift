import XCTest
@testable import ClaudeUsage

@MainActor
final class StatusItemPlacementRecoveryTests:
    XCTestCase
{
    func testExpectedItemWithoutWindowIsBlocked() {
        XCTAssertTrue(
            StatusItemPlacementRecoveryPolicy
                .isMaterializationBlocked(
                    StatusItemPlacementSnapshot(
                        expectsVisibility: true,
                        reportsVisible: true,
                        hasButton: true,
                        hasWindow: false,
                        hasScreen: false,
                        isOnCurrentScreen: false,
                        buttonWidth: 18
                    )
                )
        )
    }

    func testIntentionallyHiddenItemIsNotBlocked() {
        XCTAssertFalse(
            StatusItemPlacementRecoveryPolicy
                .isMaterializationBlocked(
                    StatusItemPlacementSnapshot(
                        expectsVisibility: false,
                        reportsVisible: false,
                        hasButton: true,
                        hasWindow: false,
                        hasScreen: false,
                        isOnCurrentScreen: false,
                        buttonWidth: 18
                    )
                )
        )
    }

    func testSystemHiddenItemWithoutWindowIsNotBlocked() {
        let evidence =
            StatusItemPlacementEvidence(
                autosaveName:
                    "claudeusage",
                visibilityDefault: false,
                snapshot:
                    StatusItemPlacementSnapshot(
                        expectsVisibility: true,
                        reportsVisible: false,
                        hasButton: true,
                        hasWindow: false,
                        hasScreen: false,
                        isOnCurrentScreen: false,
                        buttonWidth: 18
                    ),
                windowSnapshots: []
            )

        XCTAssertFalse(
            StatusItemPlacementRecoveryPolicy
                .isBlocked(
                    evidence,
                    detectTahoeBlockedStatusItem:
                        true
                )
        )
    }

    func testSystemHiddenDisplacedProxyIsNotBlocked() {
        let evidence =
            StatusItemPlacementEvidence(
                autosaveName:
                    "claudeusage",
                visibilityDefault: false,
                snapshot:
                    StatusItemPlacementSnapshot(
                        expectsVisibility: true,
                        reportsVisible: false,
                        hasButton: true,
                        hasWindow: true,
                        hasScreen: false,
                        isOnCurrentScreen: false,
                        buttonWidth: 18
                    ),
                windowSnapshots: [
                    StatusItemWindowSnapshot(
                        name:
                            "claudeusage",
                        ownerName:
                            "Control Center",
                        bounds: CGRect(
                            x: 0,
                            y: -22,
                            width: 76,
                            height: 22
                        ),
                        isOnscreen: true,
                        displayBounds: nil
                    ),
                ]
            )

        XCTAssertFalse(
            StatusItemPlacementRecoveryPolicy
                .isBlocked(
                    evidence,
                    detectTahoeBlockedStatusItem:
                        true
                )
        )
    }

    func testHealthyItemIsNotBlocked() {
        XCTAssertFalse(
            StatusItemPlacementRecoveryPolicy
                .isMaterializationBlocked(
                    StatusItemPlacementSnapshot(
                        expectsVisibility: true,
                        reportsVisible: true,
                        hasButton: true,
                        hasWindow: true,
                        hasScreen: true,
                        isOnCurrentScreen: true,
                        buttonWidth: 18
                    )
                )
        )
    }

    func testMenuBarManagerDisplacementIsNotBlocked() {
        let snapshot =
            StatusItemPlacementSnapshot(
                expectsVisibility: true,
                reportsVisible: true,
                hasButton: true,
                hasWindow: true,
                hasScreen: false,
                isOnCurrentScreen: false,
                buttonWidth: 18
            )
        let evidence =
            StatusItemPlacementEvidence(
                autosaveName:
                    "claudeusage-staging",
                visibilityDefault: true,
                snapshot: snapshot,
                windowSnapshots: []
            )

        XCTAssertFalse(
            StatusItemPlacementRecoveryPolicy
                .isBlocked(
                    evidence,
                    detectTahoeBlockedStatusItem:
                        true
                )
        )
        XCTAssertTrue(
            StatusItemPlacementRecoveryPolicy
                .isDisplaced(snapshot)
        )
    }

    func testTahoeBlockedProxyCorroboratesDisplacement() {
        let evidence =
            StatusItemPlacementEvidence(
                autosaveName:
                    "claudeusage-staging",
                visibilityDefault: true,
                snapshot:
                    StatusItemPlacementSnapshot(
                        expectsVisibility: true,
                        reportsVisible: true,
                        hasButton: true,
                        hasWindow: true,
                        hasScreen: false,
                        isOnCurrentScreen: false,
                        buttonWidth: 18
                    ),
                windowSnapshots: [
                    StatusItemWindowSnapshot(
                        name:
                            "claudeusage-staging",
                        ownerName:
                            "Control Center",
                        bounds: CGRect(
                            x: 0,
                            y: -22,
                            width: 76,
                            height: 22
                        ),
                        isOnscreen: true,
                        displayBounds: nil
                    ),
                ]
            )

        XCTAssertTrue(
            StatusItemPlacementRecoveryPolicy
                .isBlocked(
                    evidence,
                    detectTahoeBlockedStatusItem:
                        true
                )
        )
    }

    func testTahoeHiddenItemWithoutHealthyProxyIsBlocked() {
        let evidence =
            StatusItemPlacementEvidence(
                autosaveName:
                    "claudeusage-staging",
                visibilityDefault: true,
                snapshot:
                    StatusItemPlacementSnapshot(
                        expectsVisibility: true,
                        reportsVisible: false,
                        hasButton: true,
                        hasWindow: false,
                        hasScreen: false,
                        isOnCurrentScreen: false,
                        buttonWidth: 18
                    ),
                windowSnapshots: []
            )

        XCTAssertTrue(
            StatusItemPlacementRecoveryPolicy
                .isBlocked(
                    evidence,
                    detectTahoeBlockedStatusItem:
                        true
                )
        )
    }

    func testHiddenItemWithLiveWindowIsNotBlockedWithoutProxyEvidence() {
        let evidence =
            StatusItemPlacementEvidence(
                autosaveName:
                    "claudeusage-staging",
                visibilityDefault: true,
                snapshot:
                    StatusItemPlacementSnapshot(
                        expectsVisibility: true,
                        reportsVisible: false,
                        hasButton: true,
                        hasWindow: true,
                        hasScreen: true,
                        isOnCurrentScreen: true,
                        buttonWidth: 18
                    ),
                windowSnapshots: []
            )

        XCTAssertFalse(
            StatusItemPlacementRecoveryPolicy
                .isBlocked(
                    evidence,
                    detectTahoeBlockedStatusItem:
                        true
                )
        )
    }

    func testHealthyProxyPreventsHiddenItemFalsePositive() {
        let evidence =
            StatusItemPlacementEvidence(
                autosaveName:
                    "claudeusage-staging",
                visibilityDefault: true,
                snapshot:
                    StatusItemPlacementSnapshot(
                        expectsVisibility: true,
                        reportsVisible: false,
                        hasButton: true,
                        hasWindow: true,
                        hasScreen: true,
                        isOnCurrentScreen: true,
                        buttonWidth: 18
                    ),
                windowSnapshots: [
                    StatusItemWindowSnapshot(
                        name:
                            "claudeusage-staging",
                        ownerName:
                            "Control Center",
                        bounds: CGRect(
                            x: 1_800,
                            y: 0,
                            width: 76,
                            height: 24
                        ),
                        isOnscreen: true,
                        displayBounds: CGRect(
                            x: 0,
                            y: 0,
                            width: 2_056,
                            height: 1_329
                        )
                    ),
                ]
            )

        XCTAssertFalse(
            StatusItemPlacementRecoveryPolicy
                .isBlocked(
                    evidence,
                    detectTahoeBlockedStatusItem:
                        true
                )
        )
    }

    func testTahoeOnlyEvidenceIsIgnoredOnOlderMacOS() {
        let evidence =
            StatusItemPlacementEvidence(
                autosaveName:
                    "claudeusage",
                visibilityDefault: true,
                snapshot:
                    StatusItemPlacementSnapshot(
                        expectsVisibility: true,
                        reportsVisible: false,
                        hasButton: true,
                        hasWindow: true,
                        hasScreen: true,
                        isOnCurrentScreen: true,
                        buttonWidth: 18
                    ),
                windowSnapshots: []
            )

        XCTAssertFalse(
            StatusItemPlacementRecoveryPolicy
                .isBlocked(
                    evidence,
                    detectTahoeBlockedStatusItem:
                        false
                )
        )
    }

    func testWindowProbeRejectsGenericOffscreenPlacement() {
        let snapshots =
            StatusItemWindowProbe.snapshots(
                matching: [
                    "claudeusage-staging",
                ],
                windowInfo: [
                    [
                        kCGWindowName as String:
                            "claudeusage-staging",
                        kCGWindowOwnerName as String:
                            "Control Center",
                        kCGWindowIsOnscreen as String:
                            true,
                        kCGWindowBounds as String: [
                            "X": 2_023,
                            "Y": 0,
                            "Width": 71,
                            "Height": 24,
                        ],
                    ],
                ],
                displayBounds: [
                    CGRect(
                        x: 0,
                        y: 0,
                        width: 2_056,
                        height: 1_329
                    ),
                ]
            )

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertFalse(
            snapshots[0].isTahoeBlockedProxy
        )
    }

    func testWindowProbeRecognizesTahoeBlockedGeometry() {
        let snapshots =
            StatusItemWindowProbe.snapshots(
                matching: [
                    "claudeusage",
                ],
                windowInfo: [
                    [
                        kCGWindowName as String:
                            "claudeusage",
                        kCGWindowOwnerName as String:
                            "Control Center",
                        kCGWindowIsOnscreen as String:
                            true,
                        kCGWindowBounds as String: [
                            "X": 0,
                            "Y": -22,
                            "Width": 76,
                            "Height": 22,
                        ],
                    ],
                ],
                displayBounds: [
                    CGRect(
                        x: 0,
                        y: 0,
                        width: 2_056,
                        height: 1_329
                    ),
                ]
            )

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertTrue(
            snapshots[0].isTahoeBlockedProxy
        )
    }

    func testGuidanceRepeatsAfterOneDay() throws {
        let suiteName =
            "StatusItemPlacementRecoveryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer {
            defaults.removePersistentDomain(
                forName: suiteName
            )
        }
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(
            StatusItemPlacementRecoveryPolicy
                .shouldShowGuidance(
                    defaults: defaults,
                    now: now
                )
        )
        StatusItemPlacementRecoveryPolicy
            .markGuidanceShown(
                defaults: defaults,
                now: now
            )
        XCTAssertFalse(
            StatusItemPlacementRecoveryPolicy
                .shouldShowGuidance(
                    defaults: defaults,
                    now:
                        now.addingTimeInterval(
                            StatusItemPlacementRecoveryPolicy
                                .guidanceRepeatInterval
                                - 1
                        )
                )
        )
        XCTAssertTrue(
            StatusItemPlacementRecoveryPolicy
                .shouldShowGuidance(
                    defaults: defaults,
                    now:
                        now.addingTimeInterval(
                            StatusItemPlacementRecoveryPolicy
                                .guidanceRepeatInterval
                        )
                )
        )
    }

    func testClearsOnlyInvalidPreferredPositions() throws {
        let suiteName =
            "StatusItemPlacementPositionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer {
            defaults.removePersistentDomain(
                forName: suiteName
            )
        }
        let stableKey =
            StatusItemPlacementRecoveryPolicy
                .preferredPositionKey(
                    autosaveName: "claudeusage-staging"
                )
        let legacyKey =
            StatusItemPlacementRecoveryPolicy
                .preferredPositionKey(
                    autosaveName: "Item-0"
                )
        defaults.set(320, forKey: stableKey)
        defaults.set(10_000, forKey: legacyKey)

        let repaired =
            StatusItemPlacementRecoveryPolicy
                .clearInvalidPreferredPosition(
                    defaults: defaults,
                    autosaveName:
                        "claudeusage-staging",
                    legacyDefaultItemIndex: 0,
                    maximumPreferredPosition: 3_456
                )

        XCTAssertEqual(repaired, [legacyKey])
        XCTAssertEqual(
            defaults.double(forKey: stableKey),
            320
        )
        XCTAssertNil(
            defaults.object(forKey: legacyKey)
        )
    }

    func testNeverHiddenItemWithoutWindowIsBlocked() {
        let evidence =
            StatusItemPlacementEvidence(
                autosaveName:
                    "claudeusage",
                visibilityDefault: nil,
                snapshot:
                    StatusItemPlacementSnapshot(
                        expectsVisibility: true,
                        reportsVisible: false,
                        hasButton: true,
                        hasWindow: false,
                        hasScreen: false,
                        isOnCurrentScreen: false,
                        buttonWidth: 18
                    ),
                windowSnapshots: []
            )

        XCTAssertTrue(
            StatusItemPlacementRecoveryPolicy
                .isBlocked(
                    evidence,
                    detectTahoeBlockedStatusItem:
                        true
                )
        )
        XCTAssertFalse(
            StatusItemPlacementRecoveryPolicy
                .isBlocked(
                    evidence,
                    detectTahoeBlockedStatusItem:
                        false
                )
        )
    }

    func testDetachedAnchorIsBlockedEvenWhenEveryInternalSignalIsHealthy() {
        let healthy =
            StatusItemPlacementEvidence(
                autosaveName:
                    "claudeusage",
                visibilityDefault: true,
                snapshot:
                    StatusItemPlacementSnapshot(
                        expectsVisibility: true,
                        reportsVisible: true,
                        hasButton: true,
                        hasWindow: true,
                        hasScreen: true,
                        isOnCurrentScreen: true,
                        buttonWidth: 195.5
                    ),
                windowSnapshots: []
            )

        XCTAssertFalse(
            StatusItemPlacementRecoveryPolicy
                .isBlocked(
                    healthy,
                    detectTahoeBlockedStatusItem: true,
                    anchorIsUsable: true
                )
        )
        XCTAssertTrue(
            StatusItemPlacementRecoveryPolicy
                .isBlocked(
                    healthy,
                    detectTahoeBlockedStatusItem: true,
                    anchorIsUsable: false
                )
        )
    }

    func testDetachedAnchorWithoutStatusItemIsNotBlocked() {
        let noItem =
            StatusItemPlacementEvidence(
                autosaveName: "",
                visibilityDefault: nil,
                snapshot:
                    StatusItemPlacementSnapshot(
                        expectsVisibility: false,
                        reportsVisible: false,
                        hasButton: false,
                        hasWindow: false,
                        hasScreen: false,
                        isOnCurrentScreen: false,
                        buttonWidth: 0
                    ),
                windowSnapshots: []
            )

        XCTAssertFalse(
            StatusItemPlacementRecoveryPolicy
                .isBlocked(
                    noItem,
                    detectTahoeBlockedStatusItem: true,
                    anchorIsUsable: false
                )
        )
    }

    func testReopenPolicyUsesVisibleRecoveryPath() {
        XCTAssertEqual(
            ApplicationReopenPolicy.action(
                hasVisibleWindows: false,
                statusItemIsBlocked: true,
                statusItemCanAnchorPopover: true
            ),
            .showStatusItemRecovery
        )
        XCTAssertEqual(
            ApplicationReopenPolicy.action(
                hasVisibleWindows: false,
                statusItemIsBlocked: false,
                statusItemCanAnchorPopover: true
            ),
            .showPopover
        )
        XCTAssertEqual(
            ApplicationReopenPolicy.action(
                hasVisibleWindows: true,
                statusItemIsBlocked: true,
                statusItemCanAnchorPopover: false
            ),
            .useDefaultWindowHandling
        )
    }

    func testReopenPrefersRecoveryWhenPopoverHasNoAnchor() {
        XCTAssertEqual(
            ApplicationReopenPolicy.action(
                hasVisibleWindows: false,
                statusItemIsBlocked: false,
                statusItemCanAnchorPopover: false
            ),
            .showStatusItemRecovery
        )
    }

    func testAnchorIsUnusableWithoutButtonWindow() {
        XCTAssertFalse(
            StatusItemAnchorPolicy.isUsable(
                StatusItemAnchorSnapshot(
                    windowFrame: nil,
                    menuBarBands: [CGRect(x: 0, y: 1400, width: 2560, height: 40)]
                )
            )
        )
    }

    func testAnchorIsUsableInsideMenuBarBand() {
        XCTAssertTrue(
            StatusItemAnchorPolicy.isUsable(
                StatusItemAnchorSnapshot(
                    windowFrame: CGRect(x: 2100, y: 1405, width: 100, height: 24),
                    menuBarBands: [CGRect(x: 0, y: 1400, width: 2560, height: 40)]
                )
            )
        )
    }

    func testAnchorIsUnusableOutsideEveryBand() {
        XCTAssertFalse(
            StatusItemAnchorPolicy.isUsable(
                StatusItemAnchorSnapshot(
                    windowFrame: CGRect(x: 0, y: 0, width: 100, height: 24),
                    menuBarBands: [
                        CGRect(x: 0, y: 1400, width: 2560, height: 40),
                        CGRect(x: -1920, y: 1400, width: 1920, height: 40),
                    ]
                )
            )
        )
    }

    func testAnchorWithoutBandInformationDoesNotBlock() {
        XCTAssertTrue(
            StatusItemAnchorPolicy.isUsable(
                StatusItemAnchorSnapshot(
                    windowFrame: CGRect(x: 0, y: 0, width: 100, height: 24),
                    menuBarBands: []
                )
            )
        )
    }
}
