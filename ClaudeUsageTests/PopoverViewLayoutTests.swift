import XCTest
@testable import ClaudeUsage

final class PopoverViewLayoutTests: XCTestCase {
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
        XCTAssertEqual(
            PopoverLayoutMetrics.preferredPopoverHeight(compact: false, phase: .loading, rowCount: 0),
            185
        )
        XCTAssertEqual(
            PopoverLayoutMetrics.preferredPopoverHeight(compact: false, phase: .content, rowCount: 2),
            256
        )
        XCTAssertEqual(
            PopoverLayoutMetrics.preferredPopoverHeight(compact: false, phase: .content, rowCount: 3),
            300
        )
    }

    func testStandardLayoutSpecUsesTallerInteractiveStatusBodyHeight() async {
        let expectedHeights = await MainActor.run {
            (
                PopoverLayoutMetrics.standardInteractiveStatusPanelHeight,
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
            116
        )
        // 행 수 기반 높이: 1행은 최소 높이(96)에 걸리고, 이후 행마다 21pt씩 커진다.
        // 최대 표시 행 수(5)를 넘으면 고정 + 내부 스크롤.
        XCTAssertEqual(
            PopoverLayoutMetrics.preferredPopoverHeight(compact: true, phase: .content, rowCount: 1),
            96
        )
        XCTAssertEqual(
            PopoverLayoutMetrics.preferredPopoverHeight(compact: true, phase: .content, rowCount: 2),
            115
        )
        XCTAssertEqual(
            PopoverLayoutMetrics.preferredPopoverHeight(compact: true, phase: .content, rowCount: 3),
            136
        )
        XCTAssertEqual(
            PopoverLayoutMetrics.preferredPopoverHeight(compact: true, phase: .content, rowCount: 4),
            157
        )
        XCTAssertEqual(
            PopoverLayoutMetrics.preferredPopoverHeight(compact: true, phase: .content, rowCount: 5),
            178
        )
        XCTAssertEqual(
            PopoverLayoutMetrics.preferredPopoverHeight(compact: true, phase: .content, rowCount: 6),
            178
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
        XCTAssertEqual(result.2, 115)
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

        // Claude 3행(현재+주간+Sonnet) → 136, Codex 2행 → 115
        XCTAssertEqual(result.0, 136)
        XCTAssertEqual(result.1, 115)
    }

    func testStandardShownContentUsesMeasuredHeightInsteadOfFallbackBucket() {
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
        XCTAssertEqual(targetSize.height, 223)
    }

    func testStandardInitialContentKeepsFallbackHeightBeforePresentation() {
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

        XCTAssertEqual(targetSize.height, 256)
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
        XCTAssertEqual(targetSize.height, 115)
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
