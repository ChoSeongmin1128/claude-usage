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

    func testHealthySignalsDoNotRequireRecreationWithoutSystemEvidence() {
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
                    detectTahoeBlockedStatusItem: true
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
                    detectTahoeBlockedStatusItem: true
                )
        )
    }

    func testReopenPolicyUsesVisibleRecoveryPath() {
        let blocked = makeAssessment(
            anchorSnapshot: StatusItemAnchorSnapshot(
                windowFrame: nil,
                menuBarBands: [CGRect(x: 0, y: 900, width: 1_000, height: 24)]
            ),
            hasWindow: false
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

    func testReopenShowsSettingsWhenPopoverHasNoAnchorWithoutRecoveryEvidence() {
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
            .showSettings
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

    func testAssessmentDoesNotRecreateHealthyItemOutsideMenuBarBands() {
        let assessment = makeAssessment(
            anchorSnapshot: StatusItemAnchorSnapshot(
                windowFrame: CGRect(x: 0, y: 0, width: 100, height: 24),
                menuBarBands: [
                    CGRect(x: 0, y: 900, width: 1_000, height: 24)
                ]
            )
        )

        XCTAssertFalse(assessment.anchorIsUsable)
        XCTAssertFalse(assessment.isBlocked)
        XCTAssertEqual(
            ApplicationReopenPolicy.action(hasVisibleWindows: false, placement: assessment),
            .showSettings
        )
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
                                detectTahoe
                        )
                )
            }
        }
    }

    // MARK: - User-hidden item

    /// 사용자가 메뉴 막대에서 항목을 끄면 AppKit이 버튼 윈도우를 내리므로 앵커도
    /// 같이 사라진다. 그 상태를 macOS 차단으로 읽으면 사용자가 끈 항목을 되살리고
    /// 차단됐다는 안내까지 띄운다. 숨김 선택은 생성 실패와 구분한다.
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
                detectTahoeBlockedStatusItem: true
            )
        )
    }

    func testVisibleOffBandItemPreservesPlacementRegardlessOfVisibilityPreference() {
        let visibilityDefaults: [Bool?] = [true, nil]
        for visibilityDefault in visibilityDefaults {
            // A menu bar manager can preserve every AppKit visibility flag while
            // moving an item outside the expected bands. Its exact placement is
            // not evidence that the application's registration needs repair.
            let assessment = makeAssessment(
                anchorSnapshot: StatusItemAnchorSnapshot(
                    windowFrame: CGRect(x: -200, y: 0, width: 195.5, height: 24),
                    menuBarBands: [
                        CGRect(x: 0, y: 1083, width: 1728, height: 34),
                        CGRect(x: 1728, y: 1248, width: 2560, height: 34),
                    ]
                ),
                visibilityDefault: visibilityDefault
            )

            XCTAssertFalse(assessment.anchorIsUsable)
            XCTAssertFalse(assessment.isUserHidden)
            XCTAssertFalse(assessment.isBlocked, "Startup must not recreate an off-band item with healthy signals")
            XCTAssertEqual(
                ApplicationReopenPolicy.action(hasVisibleWindows: false, placement: assessment),
                .showSettings
            )
        }
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
        XCTAssertFalse(assessment.isBlocked)
        XCTAssertEqual(
            ApplicationReopenPolicy.action(
                hasVisibleWindows: false,
                placement: assessment
            ),
            .showSettings
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
            "blocked=false anchor=false "
                + assessment.evidence.description
                + " windowFrame={{0, 0}, {100, 24}} menuBarBands=[{{0, 900}, {1000, 24}}]"
        )
    }

    func testAnchorDescriptionIncludesEveryBandAndFractionalWindowCoordinates() {
        let snapshot = StatusItemAnchorSnapshot(
            windowFrame: CGRect(x: -200.5, y: 0, width: 195.5, height: 24),
            menuBarBands: [
                CGRect(x: 0, y: 1083, width: 1728, height: 34),
                CGRect(x: 1728, y: 1248, width: 2560, height: 34),
            ]
        )
        XCTAssertEqual(
            snapshot.description,
            "windowFrame={{-200.5, 0}, {195.5, 24}} "
                + "menuBarBands=[{{0, 1083}, {1728, 34}} | {{1728, 1248}, {2560, 34}}]"
        )
        XCTAssertEqual(
            StatusItemAnchorSnapshot(windowFrame: nil, menuBarBands: []).description,
            "windowFrame=none menuBarBands=[]"
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
