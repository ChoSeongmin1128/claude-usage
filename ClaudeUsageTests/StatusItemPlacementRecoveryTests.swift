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
                        true,
                    anchorIsUsable: true
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
                        true,
                    anchorIsUsable: true
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
                        true,
                    anchorIsUsable: true
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
                        true,
                    anchorIsUsable: true
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
                        true,
                    anchorIsUsable: true
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
                        true,
                    anchorIsUsable: true
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
                        true,
                    anchorIsUsable: true
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
                        false,
                    anchorIsUsable: true
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
                        true,
                    anchorIsUsable: true
                )
        )
        XCTAssertFalse(
            StatusItemPlacementRecoveryPolicy
                .isBlocked(
                    evidence,
                    detectTahoeBlockedStatusItem:
                        false,
                    anchorIsUsable: true
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
        let blocked = makeAssessment(
            anchorSnapshot: StatusItemAnchorSnapshot(
                windowFrame: CGRect(x: 0, y: 0, width: 100, height: 24),
                menuBarBands: [CGRect(x: 0, y: 900, width: 1_000, height: 24)]
            )
        )
        let placed = makeAssessment(
            anchorSnapshot: StatusItemAnchorSnapshot(
                windowFrame: CGRect(x: 120, y: 900, width: 100, height: 24),
                menuBarBands: [CGRect(x: 0, y: 900, width: 1_000, height: 24)]
            )
        )

        XCTAssertEqual(
            ApplicationReopenPolicy.action(
                hasVisibleWindows: false,
                placement: blocked
            ),
            .showStatusItemRecovery
        )
        XCTAssertEqual(
            ApplicationReopenPolicy.action(
                hasVisibleWindows: false,
                placement: placed
            ),
            .showPopover
        )
        XCTAssertEqual(
            ApplicationReopenPolicy.action(
                hasVisibleWindows: true,
                placement: blocked
            ),
            .useDefaultWindowHandling
        )
    }

    func testReopenPrefersRecoveryWhenPopoverHasNoAnchor() {
        let assessment = makeAssessment(
            anchorSnapshot: StatusItemAnchorSnapshot(
                windowFrame: nil,
                menuBarBands: []
            ),
            reportsVisible: false
        )

        XCTAssertFalse(assessment.isBlocked)
        XCTAssertFalse(assessment.anchorIsUsable)
        XCTAssertEqual(
            ApplicationReopenPolicy.action(
                hasVisibleWindows: false,
                placement: assessment
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

    // MARK: - Assessment

    func testAssessmentTreatsDetachedAnchorAsBlocked() {
        let assessment = makeAssessment(
            anchorSnapshot: StatusItemAnchorSnapshot(
                windowFrame: CGRect(x: 0, y: 0, width: 100, height: 24),
                menuBarBands: [
                    CGRect(x: 0, y: 900, width: 1_000, height: 24)
                ]
            )
        )

        XCTAssertFalse(assessment.anchorIsUsable)
        XCTAssertTrue(assessment.isBlocked)
    }

    func testAssessmentTreatsInBandAnchorAsPlaced() {
        let assessment = makeAssessment(
            anchorSnapshot: StatusItemAnchorSnapshot(
                windowFrame: CGRect(x: 120, y: 900, width: 100, height: 24),
                menuBarBands: [
                    CGRect(x: 0, y: 900, width: 1_000, height: 24)
                ]
            )
        )

        XCTAssertTrue(assessment.anchorIsUsable)
        XCTAssertFalse(assessment.isBlocked)
    }

    func testAssessmentWithoutBandInformationDoesNotBlock() {
        let assessment = makeAssessment(
            anchorSnapshot: StatusItemAnchorSnapshot(
                windowFrame: CGRect(x: 0, y: 0, width: 100, height: 24),
                menuBarBands: []
            )
        )

        XCTAssertTrue(assessment.anchorIsUsable)
        XCTAssertFalse(assessment.isBlocked)
        XCTAssertEqual(
            ApplicationReopenPolicy.action(
                hasVisibleWindows: false,
                placement: assessment
            ),
            .showPopover
        )
    }

    /// 판정을 한곳으로 모으면서 기존 두 정책의 결과가 바뀌지 않아야 한다.
    func testAssessmentMatchesTheUnderlyingPolicies() {
        let anchorSnapshots = [
            StatusItemAnchorSnapshot(
                windowFrame: CGRect(x: 120, y: 900, width: 100, height: 24),
                menuBarBands: [
                    CGRect(x: 0, y: 900, width: 1_000, height: 24)
                ]
            ),
            StatusItemAnchorSnapshot(
                windowFrame: CGRect(x: 0, y: 0, width: 100, height: 24),
                menuBarBands: [
                    CGRect(x: 0, y: 900, width: 1_000, height: 24)
                ]
            ),
            StatusItemAnchorSnapshot(
                windowFrame: nil,
                menuBarBands: []
            ),
        ]

        for anchorSnapshot in anchorSnapshots {
            for detectTahoe in [true, false] {
                let assessment = makeAssessment(
                    anchorSnapshot: anchorSnapshot,
                    detectTahoeBlockedStatusItem: detectTahoe
                )
                let expectedAnchor =
                    StatusItemAnchorPolicy.isUsable(
                        anchorSnapshot
                    )

                XCTAssertEqual(
                    assessment.anchorIsUsable,
                    expectedAnchor
                )
                XCTAssertEqual(
                    assessment.isBlocked,
                    StatusItemPlacementRecoveryPolicy
                        .isBlocked(
                            assessment.evidence,
                            detectTahoeBlockedStatusItem:
                                detectTahoe,
                            anchorIsUsable: expectedAnchor
                        )
                )
            }
        }
    }

    // MARK: - User-hidden item

    /// 사용자가 메뉴 막대에서 항목을 끄면 AppKit이 버튼 윈도우를 내리므로 앵커도
    /// 같이 사라진다. 그 상태를 macOS 차단으로 읽으면 사용자가 끈 항목을 되살리고
    /// 차단됐다는 안내까지 띄운다. 앵커 신호는 표시 중일 때만 근거가 된다.
    func testUserHiddenItemWithDetachedAnchorIsNotBlocked() {
        let hidden = StatusItemPlacementEvidence(
            autosaveName: "claudeusage",
            visibilityDefault: false,
            snapshot: StatusItemPlacementSnapshot(
                expectsVisibility: true,
                reportsVisible: false,
                hasButton: true,
                hasWindow: false,
                hasScreen: false,
                isOnCurrentScreen: false,
                buttonWidth: 0
            ),
            windowSnapshots: []
        )

        XCTAssertFalse(
            StatusItemPlacementRecoveryPolicy.isBlocked(
                hidden,
                detectTahoeBlockedStatusItem: true,
                anchorIsUsable: false
            )
        )
    }

    func testVisibleItemWithDetachedAnchorStaysBlocked() {
        let visible = StatusItemPlacementEvidence(
            autosaveName: "claudeusage",
            visibilityDefault: true,
            snapshot: StatusItemPlacementSnapshot(
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

        XCTAssertTrue(
            StatusItemPlacementRecoveryPolicy.isBlocked(
                visible,
                detectTahoeBlockedStatusItem: true,
                anchorIsUsable: false
            )
        )
    }

    /// 실제 생산 경로인 assessment 에서도 같은 계약이 유지돼야 한다.
    func testReopenOfUserHiddenItemShowsSettingsThroughAssessment() {
        let assessment = StatusItemPlacementAssessment(
            evidence: StatusItemPlacementEvidence(
                autosaveName: "claudeusage",
                visibilityDefault: false,
                snapshot: StatusItemPlacementSnapshot(
                    expectsVisibility: true,
                    reportsVisible: false,
                    hasButton: true,
                    hasWindow: false,
                    hasScreen: false,
                    isOnCurrentScreen: false,
                    buttonWidth: 0
                ),
                windowSnapshots: []
            ),
            // 항목을 끄면 버튼 윈도우가 사라져 앵커를 만들 수 없다.
            anchorSnapshot: StatusItemAnchorSnapshot(
                windowFrame: nil,
                menuBarBands: [
                    CGRect(x: 0, y: 900, width: 1_000, height: 24)
                ]
            ),
            detectTahoeBlockedStatusItem: true
        )

        XCTAssertFalse(assessment.anchorIsUsable)
        XCTAssertFalse(assessment.isBlocked)
        XCTAssertTrue(assessment.isUserHidden)
        XCTAssertEqual(
            ApplicationReopenPolicy.action(
                hasVisibleWindows: false,
                placement: assessment
            ),
            .showSettings
        )
        XCTAssertEqual(
            ApplicationReopenPolicy.action(
                hasVisibleWindows: true,
                placement: assessment
            ),
            .useDefaultWindowHandling
        )
    }

    func testReopenDoesNotTreatMissingOrEnabledVisibilityPreferenceAsUserHidden() {
        let visibilityDefaults: [Bool?] = [nil, true]
        for visibilityDefault in visibilityDefaults {
            let assessment = makeAssessment(
                anchorSnapshot: StatusItemAnchorSnapshot(
                    windowFrame: nil,
                    menuBarBands: []
                ),
                visibilityDefault: visibilityDefault,
                reportsVisible: false,
                hasWindow: false
            )

            XCTAssertFalse(assessment.isUserHidden)
            XCTAssertTrue(assessment.isBlocked)
            XCTAssertEqual(
                ApplicationReopenPolicy.action(
                    hasVisibleWindows: false,
                    placement: assessment
                ),
                .showStatusItemRecovery
            )
        }
    }

    func testReopenOfVisibleDetachedItemDoesNotUseOldHiddenPreference() {
        let assessment = makeAssessment(
            anchorSnapshot: StatusItemAnchorSnapshot(
                windowFrame: CGRect(x: 0, y: 0, width: 100, height: 24),
                menuBarBands: [CGRect(x: 0, y: 900, width: 1_000, height: 24)]
            ),
            visibilityDefault: false
        )

        XCTAssertFalse(assessment.isUserHidden)
        XCTAssertTrue(assessment.isBlocked)
        XCTAssertEqual(
            ApplicationReopenPolicy.action(
                hasVisibleWindows: false,
                placement: assessment
            ),
            .showStatusItemRecovery
        )
    }

    /// 기록이 실제로 행동을 결정한 상태여야 하므로 판정과 근거를 함께 담는다.
    func testAssessmentDescriptionCarriesJudgementAndEvidence() {
        let assessment = makeAssessment(
            anchorSnapshot: StatusItemAnchorSnapshot(
                windowFrame: CGRect(x: 0, y: 0, width: 100, height: 24),
                menuBarBands: [
                    CGRect(x: 0, y: 900, width: 1_000, height: 24)
                ]
            )
        )

        XCTAssertEqual(
            assessment.description,
            "blocked=true anchor=false "
                + assessment.evidence.description
        )
    }

    private func makeAssessment(
        anchorSnapshot: StatusItemAnchorSnapshot,
        detectTahoeBlockedStatusItem: Bool = true,
        visibilityDefault: Bool? = true,
        reportsVisible: Bool = true,
        hasWindow: Bool = true
    ) -> StatusItemPlacementAssessment {
        StatusItemPlacementAssessment(
            evidence: StatusItemPlacementEvidence(
                autosaveName: "claudeusage",
                visibilityDefault: visibilityDefault,
                snapshot: StatusItemPlacementSnapshot(
                    expectsVisibility: true,
                    reportsVisible: reportsVisible,
                    hasButton: true,
                    hasWindow: hasWindow,
                    hasScreen: true,
                    isOnCurrentScreen: true,
                    buttonWidth: 195.5
                ),
                windowSnapshots: []
            ),
            anchorSnapshot: anchorSnapshot,
            detectTahoeBlockedStatusItem:
                detectTahoeBlockedStatusItem
        )
    }
}
