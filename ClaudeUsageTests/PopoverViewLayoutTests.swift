import SwiftUI
import XCTest
@testable import ClaudeUsage

final class PopoverViewLayoutTests: XCTestCase {
    func testCompactHeaderHidesNormalSingleAccountMetadata() {
        let account = makeClaudeAccount(
            email: "nathan@example.com",
            organizationName: "Glorang",
            planLabel: "team"
        )

        XCTAssertNil(
            CompactPopoverHeaderPresentationPolicy.resolve(
                accountCount: 1,
                activeAccount: account,
                isLoading: false,
                isAuthenticationRequired: false,
                hasRefreshError: false
            )
        )
    }

    func testCompactHeaderShowsActualIdentityOnlyForMultipleAccounts() {
        let account = makeClaudeAccount(
            email: "nathan@example.com",
            organizationName: "Glorang",
            planLabel: "team"
        )

        let context = CompactPopoverHeaderPresentationPolicy.resolve(
            accountCount: 2,
            activeAccount: account,
            isLoading: false,
            isAuthenticationRequired: false,
            hasRefreshError: false
        )

        XCTAssertEqual(context?.labels, ["nathan@example.com"])
    }

    func testCompactHeaderDoesNotUsePlanAsAccountIdentity() {
        let account = makeClaudeAccount(
            email: nil,
            organizationName: nil,
            planLabel: "team"
        )

        XCTAssertNil(
            CompactPopoverHeaderPresentationPolicy.resolve(
                accountCount: 2,
                activeAccount: account,
                isLoading: false,
                isAuthenticationRequired: false,
                hasRefreshError: false
            )
        )
    }

    func testCompactHeaderShowsOnlyActionableRuntimeStates() {
        XCTAssertEqual(
            CompactPopoverHeaderPresentationPolicy.resolve(
                accountCount: 0,
                activeAccount: nil,
                isLoading: true,
                isAuthenticationRequired: false,
                hasRefreshError: false
            )?.labels,
            ["갱신 중"]
        )
        XCTAssertEqual(
            CompactPopoverHeaderPresentationPolicy.resolve(
                accountCount: 0,
                activeAccount: nil,
                isLoading: false,
                isAuthenticationRequired: true,
                hasRefreshError: false
            )?.labels,
            ["로그인 필요"]
        )
        XCTAssertEqual(
            CompactPopoverHeaderPresentationPolicy.resolve(
                accountCount: 0,
                activeAccount: nil,
                isLoading: false,
                isAuthenticationRequired: false,
                hasRefreshError: true
            )?.labels,
            ["갱신 실패"]
        )
    }

    func testRelativeTimestampAvoidsSecondLevelPseudoPrecision() {
        let reference = Date(timeIntervalSince1970: 10_000)

        XCTAssertEqual(PopoverViewModel.relativeTimestamp(for: reference, relativeTo: reference), "방금")
        XCTAssertEqual(
            PopoverViewModel.relativeTimestamp(for: reference.addingTimeInterval(-59), relativeTo: reference),
            "방금"
        )
        XCTAssertEqual(
            PopoverViewModel.relativeTimestamp(for: reference.addingTimeInterval(-60), relativeTo: reference),
            "1분 전"
        )
        XCTAssertEqual(
            PopoverViewModel.relativeTimestamp(for: reference.addingTimeInterval(15), relativeTo: reference),
            "방금"
        )
    }

    func testProviderStatusRailAlwaysIdentifiesSelectedProvider() {
        XCTAssertEqual(
            PopoverView.providerStatusRailLabels(
                serviceName: "Claude",
                account: nil,
                source: nil,
                status: "로그인 필요"
            ),
            ["Claude", "로그인 필요"]
        )
        XCTAssertEqual(
            PopoverView.providerStatusRailLabels(
                serviceName: "Claude",
                account: "nathan@example.com",
                source: "Chrome",
                status: "방금 갱신"
            ),
            ["Claude", "nathan@example.com", "Chrome", "방금 갱신"]
        )
    }

    func testProviderSelectorGeometryKeepsWarningDotInsideSelectionBackground() {
        XCTAssertEqual(PopoverLayoutMetrics.providerSelectorSize(compact: false), 26)
        XCTAssertEqual(PopoverLayoutMetrics.providerIconSize(compact: false), 16)
        XCTAssertEqual(PopoverLayoutMetrics.providerWarningDotSize(compact: false), 6)
        XCTAssertGreaterThan(
            PopoverLayoutMetrics.providerSelectorSize(compact: false),
            PopoverLayoutMetrics.providerIconSize(compact: false)
        )
        XCTAssertGreaterThanOrEqual(
            PopoverLayoutMetrics.providerSelectorSize(compact: false),
            PopoverLayoutMetrics.providerWarningDotSize(compact: false)
                + PopoverLayoutMetrics.providerWarningDotInset(compact: false) * 2
        )

        XCTAssertEqual(PopoverLayoutMetrics.providerSelectorSize(compact: true), 20)
        XCTAssertEqual(PopoverLayoutMetrics.providerIconSize(compact: true), 14)
        XCTAssertEqual(PopoverLayoutMetrics.providerWarningDotSize(compact: true), 4)
        XCTAssertGreaterThanOrEqual(
            PopoverLayoutMetrics.providerSelectorSize(compact: true),
            PopoverLayoutMetrics.providerWarningDotSize(compact: true)
                + PopoverLayoutMetrics.providerWarningDotInset(compact: true) * 2
        )
    }

    func testProviderSelectorWarningNeverAnnouncesAvailability() {
        let warningState =
            PopoverViewModel.RuntimeServiceState(
                service: .antigravity,
                summary: "일부 확인 필요",
                meta: nil,
                lastUpdated: nil,
                isLoading: false,
                error: nil,
                hasContent: true,
                isAuthRequired: false,
                shouldShowWarningDot: true,
                freshness: .fresh,
                sourceLabel: nil,
                accountID: nil
            )

        XCTAssertEqual(
            warningState
                .providerSelectorAccessibilityValue(
                    isSelected: false
                ),
            "확인 필요"
        )
        XCTAssertEqual(
            warningState
                .providerSelectorAccessibilityValue(
                    isSelected: true
                ),
            "선택됨, 확인 필요"
        )
    }

    func testCompactDisplayModeDoesNotShowPersistentIdentityRail() {
        XCTAssertTrue(
            PopoverDisplayEditorMode.standard
                .showsPersistentIdentityRail
        )
        XCTAssertFalse(
            PopoverDisplayEditorMode.compact
                .showsPersistentIdentityRail
        )
    }

    @MainActor
    func testSelectedProviderWarningVisualRendersAtExpectedSize() throws {
        let preview = ProviderSelectorButtonLabel(
            provider: .claude,
            isSelected: true,
            showsWarning: true,
            compact: false
        )
        .padding(6)
        .background(Color(NSColor.windowBackgroundColor))
        .preferredColorScheme(.dark)

        let renderer = ImageRenderer(content: preview)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertEqual(image.size.width, 38, accuracy: 0.1)
        XCTAssertEqual(image.size.height, 38, accuracy: 0.1)

        let attachment = XCTAttachment(image: image)
        attachment.name = "Selected Claude provider with contained warning badge"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testStandardPopoverWidthIsReducedTo368() {
        XCTAssertEqual(PopoverView.preferredPopoverWidth(compact: false), 368)
        XCTAssertEqual(PopoverLayoutMetrics.preferredPopoverWidth(compact: false), 368)
        XCTAssertEqual(PopoverLayoutMetrics.standardPopoverWidth, 368)
    }

    func testCompactPopoverWidthRemainsUnchanged() {
        XCTAssertEqual(PopoverView.preferredPopoverWidth(compact: true), 296)
        XCTAssertEqual(PopoverLayoutMetrics.preferredPopoverWidth(compact: true), 296)
        XCTAssertEqual(PopoverLayoutMetrics.compactPopoverWidth, 296)
    }

    func testCompactUsageRowMetricsAreFixed() {
        XCTAssertEqual(PopoverLayoutMetrics.compactRowLabelWidth, 112)
        XCTAssertEqual(PopoverLayoutMetrics.compactRowMeterWidth, 150)
        XCTAssertEqual(PopoverLayoutMetrics.compactRowSpacing, 6)
        XCTAssertEqual(PopoverLayoutMetrics.compactUsageRowHeight, 18)
        XCTAssertEqual(PopoverLayoutMetrics.compactCreditsRowHeight, 18)
        XCTAssertEqual(PopoverLayoutMetrics.compactStatusRowHeight, 18)
        XCTAssertEqual(PopoverLayoutMetrics.compactOverageRowHeight, 18)
        XCTAssertEqual(PopoverLayoutMetrics.compactProgressBarHeight, 8)
        XCTAssertEqual(PopoverLayoutMetrics.compactContentBottomSpacing, 5)
    }

    func testStandardPopoverHeightUsesStatusVariants() {
        XCTAssertEqual(
            PopoverLayoutMetrics.preferredPopoverHeight(compact: false, phase: .authRequired, rowCount: 0),
            201
        )
        // Claude 미인증 rich 패널(아이콘+2줄 안내+버튼 2개)은 88pt 뷰포트에
        // 들어가지 않아 푸터와 겹쳤다. rich 플래그가 본문 192pt를 확보해야 한다.
        XCTAssertEqual(
            PopoverLayoutMetrics.preferredPopoverHeight(
                compact: false, phase: .authRequired, rowCount: 0, richAuthPanel: true
            ),
            305
        )
        XCTAssertEqual(
            PopoverLayoutMetrics.standardBodyViewportHeight(phase: .authRequired, richAuthPanel: true),
            PopoverLayoutMetrics.standardRichAuthPanelHeight
        )
        XCTAssertEqual(
            PopoverLayoutMetrics.preferredPopoverHeight(compact: false, phase: .loading, rowCount: 0),
            185
        )
        XCTAssertEqual(
            PopoverLayoutMetrics.preferredPopoverHeight(compact: false, phase: .content, rowCount: 2),
            202
        )
        XCTAssertEqual(
            PopoverLayoutMetrics.preferredPopoverHeight(compact: false, phase: .content, rowCount: 3),
            255
        )
    }

    func testStandardLayoutSpecUsesTallerInteractiveStatusBodyHeight() async {
        // Claude 미인증은 rich 패널이므로 일반 interactive 패널(88pt)이 아니라
        // rich 전용 높이를 받아야 한다. 88pt를 기대하던 이전 버전은 겹침 버그를
        // 고정하고 있었다.
        let expectedHeights = await MainActor.run {
            (
                PopoverLayoutMetrics.standardRichAuthPanelHeight,
                PopoverLayoutMetrics.standardStatusPanelHeight
            )
        }

        let result = await MainActor.run { () -> (CGFloat, CGFloat) in
            let settings = AppSettings.shared
            let snapshot = settings.createSnapshot()
            defer { settings.restore(from: snapshot) }

            settings.popoverCompact = false
            settings.setProviderEnabled(true, for: .claude)

            let authRequiredLayout = PopoverViewModel().layoutSpec(for: .claude, settings: settings)

            let loadingViewModel = PopoverViewModel()
            loadingViewModel.update(
                snapshots: [
                    RuntimeProviderSnapshot(
                        service: .claude,
                        payload: nil,
                        error: nil,
                        isLoading: true,
                        lastUpdated: nil,
                        nextRefreshAllowedAt: nil,
                        credentialState: .usable,
                        isDetected: true,
                        canAttemptRefresh: true,
                        hasAuthError: false
                    )
                ]
            )
            let loadingLayout = loadingViewModel.layoutSpec(for: .claude, settings: settings)
            return (authRequiredLayout.bodyContentHeight, loadingLayout.bodyContentHeight)
        }

        XCTAssertEqual(result.0, expectedHeights.0)
        XCTAssertEqual(result.1, expectedHeights.1)
    }

    func testCompactPopoverHeightUsesShorterStatusVariant() {
        XCTAssertEqual(
            PopoverLayoutMetrics.preferredPopoverHeight(compact: true, phase: .empty, rowCount: 0),
            107
        )
        // 행 수 기반 높이: 1행은 최소 높이(96)에 걸리고, 이후 행마다 21pt씩 커진다.
        // 최대 표시 행 수(5)를 넘으면 고정 + 내부 스크롤.
        XCTAssertEqual(
            PopoverLayoutMetrics.preferredPopoverHeight(compact: true, phase: .content, rowCount: 1),
            96
        )
        XCTAssertEqual(
            PopoverLayoutMetrics.preferredPopoverHeight(compact: true, phase: .content, rowCount: 2),
            106
        )
        XCTAssertEqual(
            PopoverLayoutMetrics.preferredPopoverHeight(compact: true, phase: .content, rowCount: 3),
            127
        )
        XCTAssertEqual(
            PopoverLayoutMetrics.preferredPopoverHeight(compact: true, phase: .content, rowCount: 4),
            148
        )
        XCTAssertEqual(
            PopoverLayoutMetrics.preferredPopoverHeight(compact: true, phase: .content, rowCount: 5),
            169
        )
        XCTAssertEqual(
            PopoverLayoutMetrics.preferredPopoverHeight(compact: true, phase: .content, rowCount: 6),
            169
        )
    }

    private func makeClaudeAccount(
        email: String?,
        organizationName: String?,
        planLabel: String?
    ) -> ClaudeAccount {
        ClaudeAccount(
            id: "test-account",
            kind: .webSession,
            displayName: planLabel ?? "브라우저 계정",
            identity: ClaudeAccountIdentity(
                email: email,
                organizationName: organizationName,
                planLabel: planLabel
            ),
            lastValidationState: .verified
        )
    }

    func testCompactLayoutSpecSizesViewportByVisibleRowCount() async {
        let result = await MainActor.run { () -> (CGFloat, CGFloat, CGFloat) in
            let settings = AppSettings.shared
            let snapshot = settings.createSnapshot()
            defer { settings.restore(from: snapshot) }

            settings.popoverCompact = true
            settings.separateCompactConfig = true
            settings.setProviderEnabled(true, for: .claude)
            settings.setCompactPopoverItems(
                makePopoverItems(
                    ("currentSession", true),
                    ("weeklyLimit", true),
                    ("modelUsage", false),
                    ("overageUsage", false)
                ),
                for: .claude
            )

            let viewModel = PopoverViewModel()
            viewModel.update(
                snapshots: [
                    RuntimeProviderSnapshot(
                        service: .claude,
                        payload: layoutTestClaudePayload,
                        error: nil,
                        isLoading: false,
                        lastUpdated: Date(),
                        nextRefreshAllowedAt: nil,
                        credentialState: .usable,
                        isDetected: true,
                        canAttemptRefresh: true,
                        hasAuthError: false
                    )
                ]
            )

            let layoutSpec = viewModel.layoutSpec(for: .claude, settings: settings)
            return (layoutSpec.bodyContentHeight, layoutSpec.contentBottomSpacing, layoutSpec.size.height)
        }

        // 표시 행 2개(currentSession, weeklyLimit) → 2행 크기 뷰포트
        let expectedBodyHeight = await MainActor.run {
            PopoverLayoutMetrics.compactContentBodyHeight(rowCount: 2)
        }

        XCTAssertEqual(result.0, expectedBodyHeight)
        XCTAssertEqual(result.1, 5)
        XCTAssertEqual(result.2, 106)
    }

    func testCompactPopoverContentHeightFollowsVisibleRowCounts() async {
        let result = await MainActor.run { () -> (CGFloat, CGFloat) in
            let settings = AppSettings.shared
            let snapshot = settings.createSnapshot()
            defer { settings.restore(from: snapshot) }

            settings.popoverCompact = true
            settings.separateCompactConfig = true
            settings.setProviderEnabled(true, for: .claude)
            settings.setProviderEnabled(true, for: .codex)
            settings.setCompactPopoverItems(
                makePopoverItems(
                    ("currentSession", true),
                    ("weeklyLimit", true),
                    ("modelUsage", true),
                    ("overageUsage", false)
                ),
                for: .claude
            )
            settings.setCompactPopoverItems(
                makePopoverItems(
                    ("codexPrimary", true),
                    ("codexSecondary", true),
                    ("codexCredits", false)
                ),
                for: .codex
            )

            let viewModel = PopoverViewModel()
            viewModel.update(
                snapshots: [
                    RuntimeProviderSnapshot(
                        service: .claude,
                        payload: layoutTestClaudeThreeRowPayload,
                        error: nil,
                        isLoading: false,
                        lastUpdated: Date(),
                        nextRefreshAllowedAt: nil,
                        credentialState: .usable,
                        isDetected: true,
                        canAttemptRefresh: true,
                        hasAuthError: false
                    ),
                    RuntimeProviderSnapshot(
                        service: .codex,
                        payload: layoutTestCodexTwoRowPayload,
                        error: nil,
                        isLoading: false,
                        lastUpdated: Date(),
                        nextRefreshAllowedAt: nil,
                        credentialState: .usable,
                        isDetected: true,
                        canAttemptRefresh: true,
                        hasAuthError: false
                    ),
                ]
            )

            let claudeHeight = viewModel.layoutSpec(for: .claude, settings: settings).size.height
            let codexHeight = viewModel.layoutSpec(for: .codex, settings: settings).size.height
            return (claudeHeight, codexHeight)
        }

        // Claude 3행(현재+주간+Sonnet) → 127, Codex 2행 → 106
        XCTAssertEqual(result.0, 127)
        XCTAssertEqual(result.1, 106)
    }

    func testStandardShownContentKeepsContentDerivedLayoutInsteadOfMeasuredHostFrame() {
        let layoutSpec = PopoverLayoutMetrics.layoutSpec(
            density: .standard,
            phase: .content,
            sections: [],
            rowCount: 2
        )

        let targetSize = PopoverPresentationPolicy(
            layoutSpec: layoutSpec,
            isShown: true,
            measuredContentSize: CGSize(width: 368, height: 223),
            screenVisibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        ).targetSize()

        XCTAssertEqual(targetSize.width, 368)
        XCTAssertEqual(targetSize.height, 202)
    }

    func testStandardInitialContentUsesSameContentDerivedHeightBeforePresentation() {
        let layoutSpec = PopoverLayoutMetrics.layoutSpec(
            density: .standard,
            phase: .content,
            sections: [],
            rowCount: 2
        )

        let targetSize = PopoverPresentationPolicy(
            layoutSpec: layoutSpec,
            isShown: false,
            measuredContentSize: CGSize(width: 368, height: 223),
            screenVisibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        ).targetSize()

        XCTAssertEqual(targetSize.height, 202)
    }

    func testStandardAntigravityHeightUsesGroupsAndLanesWithoutPhantomRows() {
        XCTAssertEqual(
            PopoverLayoutMetrics.standardAntigravityContentHeight(
                laneCounts: [2]
            ),
            99
        )
        XCTAssertEqual(
            PopoverLayoutMetrics.standardAntigravityContentHeight(
                laneCounts: [2, 2]
            ),
            215
        )
        XCTAssertEqual(
            PopoverLayoutMetrics.standardPopoverHeight(
                forBodyHeight:
                    PopoverLayoutMetrics
                        .standardAntigravityContentHeight(
                            laneCounts: [2, 2]
                        )
            ),
            328
        )
    }

    func testStandardAntigravityHeightClampsAndScrollsLargePayload() {
        XCTAssertEqual(
            PopoverLayoutMetrics.standardAntigravityContentHeight(
                laneCounts: [3, 3, 3]
            ),
            PopoverLayoutMetrics.standardMaximumBodyHeight
        )
        XCTAssertEqual(
            PopoverLayoutMetrics.standardPopoverHeight(
                forBodyHeight:
                    PopoverLayoutMetrics
                        .standardMaximumBodyHeight
            ),
            400
        )
    }

    func testCompactContentKeepsLayoutShellEvenWhenMeasuredHeightIsSmaller() {
        let layoutSpec = PopoverLayoutMetrics.layoutSpec(
            density: .compact,
            phase: .content,
            sections: [],
            rowCount: 2
        )

        let targetSize = PopoverPresentationPolicy(
            layoutSpec: layoutSpec,
            isShown: true,
            measuredContentSize: CGSize(width: 296, height: 112),
            screenVisibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        ).targetSize()

        XCTAssertEqual(targetSize.width, 296)
        XCTAssertEqual(targetSize.height, 106)
    }

    func testPopoverCompactStateIsGlobalAcrossProviders() async {
        let result = await MainActor.run { () -> (Bool, Bool) in
            let settings = AppSettings.shared
            let snapshot = settings.createSnapshot()
            defer { settings.restore(from: snapshot) }

            settings.popoverCompact = true
            let enabled = settings.popoverCompact

            settings.popoverCompact = false
            let disabled = settings.popoverCompact

            return (enabled, disabled)
        }

        XCTAssertTrue(result.0)
        XCTAssertFalse(result.1)
    }

    func testMenuBarServiceIsIndependentFromActivePopoverSelectionState() async {
        let services = await MainActor.run { () -> (PopoverService?, PopoverService?, PopoverService?, PopoverService?) in
            let settings = AppSettings.shared
            let snapshot = settings.createSnapshot()
            defer { settings.restore(from: snapshot) }

            settings.setProviderEnabled(true, for: .claude)
            settings.setProviderEnabled(true, for: .codex)
            settings.setProviderMenuBarVisible(true, for: .claude)
            settings.setProviderMenuBarVisible(true, for: .codex)
            settings.setActiveMenuBarService(.claude)

            ServiceSelectionHelper.setActivePopoverService(.codex, settings: settings)
            let codexPopover = ServiceSelectionHelper.resolvedPopoverService(settings: settings)
            let codexMenuBar = ServiceSelectionHelper.resolvedMenuBarService(settings: settings)

            settings.setActiveMenuBarService(.codex)
            ServiceSelectionHelper.setActivePopoverService(.claude, settings: settings)
            let claudePopover = ServiceSelectionHelper.resolvedPopoverService(settings: settings)
            let claudeMenuBar = ServiceSelectionHelper.resolvedMenuBarService(settings: settings)

            return (codexPopover, codexMenuBar, claudePopover, claudeMenuBar)
        }

        XCTAssertEqual(services.0, .codex)
        XCTAssertEqual(services.1, .claude)
        XCTAssertEqual(services.2, .claude)
        XCTAssertEqual(services.3, .codex)
    }

    func testCompactPopoverBodyHeightFollowsRowCountPerProvider() async {
        let expectedBodyHeights = await MainActor.run {
            (
                claude: PopoverLayoutMetrics.compactContentBodyHeight(rowCount: 3),
                codex: PopoverLayoutMetrics.compactContentBodyHeight(rowCount: 2)
            )
        }

        let result = await MainActor.run { () -> (CGFloat, CGFloat) in
            let settings = AppSettings.shared
            let snapshot = settings.createSnapshot()
            defer { settings.restore(from: snapshot) }

            settings.popoverCompact = true
            settings.separateCompactConfig = true
            settings.setProviderEnabled(true, for: .claude)
            settings.setProviderEnabled(true, for: .codex)
            settings.setCompactPopoverItems(
                makePopoverItems(
                    ("currentSession", true),
                    ("weeklyLimit", true),
                    ("modelUsage", true),
                    ("overageUsage", false)
                ),
                for: .claude
            )
            settings.setCompactPopoverItems(
                makePopoverItems(
                    ("codexPrimary", true),
                    ("codexSecondary", true),
                    ("codexCredits", false)
                ),
                for: .codex
            )

            let viewModel = PopoverViewModel()
            viewModel.update(
                snapshots: [
                    RuntimeProviderSnapshot(
                        service: .claude,
                        payload: layoutTestClaudeThreeRowPayload,
                        error: nil,
                        isLoading: false,
                        lastUpdated: Date(),
                        nextRefreshAllowedAt: nil,
                        credentialState: .usable,
                        isDetected: true,
                        canAttemptRefresh: true,
                        hasAuthError: false
                    ),
                    RuntimeProviderSnapshot(
                        service: .codex,
                        payload: layoutTestCodexTwoRowPayload,
                        error: nil,
                        isLoading: false,
                        lastUpdated: Date(),
                        nextRefreshAllowedAt: nil,
                        credentialState: .usable,
                        isDetected: true,
                        canAttemptRefresh: true,
                        hasAuthError: false
                    ),
                ]
            )

            let claudeHeight = viewModel.layoutSpec(for: .claude, settings: settings).bodyContentHeight
            let codexHeight = viewModel.layoutSpec(for: .codex, settings: settings).bodyContentHeight
            return (claudeHeight, codexHeight)
        }

        XCTAssertEqual(result.0, expectedBodyHeights.claude)
        XCTAssertEqual(result.1, expectedBodyHeights.codex)
    }

    func testStandardWidthStaysFixedAcrossAllPopoverPhases() async {
        let widths = await widthsForAllPhases(compact: false)

        XCTAssertEqual(widths.authRequired, 368)
        XCTAssertEqual(widths.loading, 368)
        XCTAssertEqual(widths.error, 368)
        XCTAssertEqual(widths.content, 368)
        XCTAssertEqual(widths.empty, 368)
    }

    func testCompactWidthStaysFixedAcrossAllPopoverPhases() async {
        let widths = await widthsForAllPhases(compact: true)

        XCTAssertEqual(widths.authRequired, 296)
        XCTAssertEqual(widths.loading, 296)
        XCTAssertEqual(widths.error, 296)
        XCTAssertEqual(widths.content, 296)
        XCTAssertEqual(widths.empty, 296)
    }

    private func widthsForAllPhases(compact: Bool) async -> (
        authRequired: CGFloat,
        loading: CGFloat,
        error: CGFloat,
        content: CGFloat,
        empty: CGFloat
    ) {
        await MainActor.run {
            let settings = AppSettings.shared
            let snapshot = settings.createSnapshot()
            defer { settings.restore(from: snapshot) }

            settings.popoverCompact = compact
            settings.setProviderEnabled(true, for: .claude)

            let authRequiredWidth = PopoverViewModel()
                .layoutSpec(for: .claude, settings: settings)
                .size.width

            let loadingViewModel = PopoverViewModel()
            loadingViewModel.update(
                snapshots: [
                    RuntimeProviderSnapshot(
                        service: .claude,
                        payload: nil,
                        error: nil,
                        isLoading: true,
                        lastUpdated: nil,
                        nextRefreshAllowedAt: nil,
                        credentialState: .usable,
                        isDetected: true,
                        canAttemptRefresh: true,
                        hasAuthError: false
                    )
                ]
            )
            let loadingWidth = loadingViewModel.layoutSpec(for: .claude, settings: settings).size.width

            let errorViewModel = PopoverViewModel()
            errorViewModel.update(
                snapshots: [
                    RuntimeProviderSnapshot(
                        service: .claude,
                        payload: nil,
                        error: .networkError("offline"),
                        isLoading: false,
                        lastUpdated: nil,
                        nextRefreshAllowedAt: nil,
                        credentialState: .usable,
                        isDetected: true,
                        canAttemptRefresh: true,
                        hasAuthError: false
                    )
                ]
            )
            let errorWidth = errorViewModel.layoutSpec(for: .claude, settings: settings).size.width

            let contentViewModel = PopoverViewModel()
            contentViewModel.update(
                snapshots: [
                    RuntimeProviderSnapshot(
                        service: .claude,
                        payload: layoutTestClaudePayload,
                        error: nil,
                        isLoading: false,
                        lastUpdated: Date(),
                        nextRefreshAllowedAt: nil,
                        credentialState: .usable,
                        isDetected: true,
                        canAttemptRefresh: true,
                        hasAuthError: false
                    )
                ]
            )
            let contentWidth = contentViewModel.layoutSpec(for: .claude, settings: settings).size.width

            settings.setProviderEnabled(false, for: .claude)
            let emptyWidth = PopoverViewModel()
                .layoutSpec(for: .claude, settings: settings)
                .size.width

            return (
                authRequired: authRequiredWidth,
                loading: loadingWidth,
                error: errorWidth,
                content: contentWidth,
                empty: emptyWidth
            )
        }
    }
}

private let layoutTestClaudePayload: RuntimeProviderPayload = .claude(
    ClaudeUsageResponse(
        fiveHour: UsageWindow(utilization: 24, resetsAt: nil),
        sevenDay: UsageWindow(utilization: 35, resetsAt: nil)
    )
)

private let layoutTestClaudeThreeRowPayload: RuntimeProviderPayload = .claude(
    ClaudeUsageResponse(
        fiveHour: UsageWindow(utilization: 2, resetsAt: nil),
        sevenDay: UsageWindow(utilization: 47, resetsAt: nil),
        sevenDaySonnet: UsageWindow(utilization: 5, resetsAt: nil)
    )
)

private let layoutTestCodexTwoRowPayload: RuntimeProviderPayload = .codex(
    decodeCodexUsageResponse(
        """
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": {
              "used_percent": 2,
              "reset_at": 1735689600,
              "limit_window_seconds": 18000
            },
            "secondary_window": {
              "used_percent": 69,
              "reset_at": 1736294400,
              "limit_window_seconds": 604800
            }
          }
        }
        """
    )
)

private func decodeCodexUsageResponse(_ json: String) -> CodexUsageResponse {
    let data = Data(json.utf8)
    return try! JSONDecoder().decode(CodexUsageResponse.self, from: data)
}

private func makePopoverItems(_ items: (String, Bool)...) -> [PopoverItemConfig] {
    items.map { PopoverItemConfig(id: $0.0, visible: $0.1) }
}
