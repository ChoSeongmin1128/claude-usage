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
        XCTAssertEqual(PopoverLayoutMetrics.compactRowLabelWidth, 100)
        XCTAssertEqual(PopoverLayoutMetrics.compactRowMeterWidth, 150)
        XCTAssertEqual(PopoverLayoutMetrics.compactRowSpacing, 6)
    }

    func testStandardPopoverHeightShrinksForShortOrEmptyStates() {
        XCTAssertEqual(
            PopoverLayoutMetrics.preferredPopoverHeight(compact: false, phase: .authRequired, rowCount: 0),
            216
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

    func testCompactPopoverHeightUsesShorterStatusVariant() {
        XCTAssertEqual(
            PopoverLayoutMetrics.preferredPopoverHeight(compact: true, phase: .empty, rowCount: 0),
            104
        )
        XCTAssertEqual(
            PopoverLayoutMetrics.preferredPopoverHeight(compact: true, phase: .content, rowCount: 2),
            116
        )
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
                .preferredPopoverSize(for: .claude, settings: settings)
                .width

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
            let loadingWidth = loadingViewModel.preferredPopoverSize(for: .claude, settings: settings).width

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
            let errorWidth = errorViewModel.preferredPopoverSize(for: .claude, settings: settings).width

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
            let contentWidth = contentViewModel.preferredPopoverSize(for: .claude, settings: settings).width

            settings.setProviderEnabled(false, for: .claude)
            let emptyWidth = PopoverViewModel()
                .preferredPopoverSize(for: .claude, settings: settings)
                .width

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
