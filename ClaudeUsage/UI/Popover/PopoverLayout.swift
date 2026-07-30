// Shared popover geometry and scroll policy.
import SwiftUI

enum PopoverLayoutMetrics {
    static let standardPopoverWidth: CGFloat = 368
    static let compactPopoverWidth: CGFloat = 296
    static let standardHeaderContainerHeight: CGFloat = 44
    static let standardFooterContainerHeight: CGFloat = 30
    static let standardShortcutFooterHeight: CGFloat = 16
    static let standardMainSectionBottomSpacing: CGFloat = 2
    static let compactHeaderHeight: CGFloat = 21
    static let compactFooterHeight: CGFloat = 31
    static let dividerHeight: CGFloat = 1
    static let standardProviderSelectorSize: CGFloat = 26
    static let compactProviderSelectorSize: CGFloat = 20
    static let standardProviderIconSize: CGFloat = 16
    static let compactProviderIconSize: CGFloat = 14
    static let standardProviderWarningDotSize: CGFloat = 6
    static let compactProviderWarningDotSize: CGFloat = 4
    static let standardProviderWarningDotInset: CGFloat = 1.5
    static let compactProviderWarningDotInset: CGFloat = 1
    static let compactBodyInsets = EdgeInsets(top: 6, leading: 10, bottom: 3, trailing: 10)
    static let standardBodyInsets = EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
    static let compactSectionSpacing: CGFloat = 3
    static let standardSectionSpacing: CGFloat = 12
    static let compactRowLabelWidth: CGFloat = 112
    static let compactRowMeterWidth: CGFloat = 150
    static let compactRowSpacing: CGFloat = 6
    static let compactUsageRowHeight: CGFloat = 18
    static let compactCreditsRowHeight: CGFloat = 18
    static let compactStatusRowHeight: CGFloat = 18
    static let compactOverageRowHeight: CGFloat = compactUsageRowHeight
    static let compactProgressBarHeight: CGFloat = 8
    static let compactStatusPanelHeight: CGFloat = 40
    static let compactInteractiveStatusPanelHeight: CGFloat = 48
    static let compactFixedContentBodyHeight: CGFloat = compactUsageRowHeight * 3 + compactSectionSpacing * 2
    static let compactMaximumVisibleRows = 5
    static let compactMinimumPopoverHeight: CGFloat = 96
    static let compactContentBottomSpacing: CGFloat = 5
    static let standardUsageRowHeight: CGFloat = 36
    static let standardSecondaryUsageRowHeight: CGFloat = 38
    static let standardCreditsRowHeight: CGFloat = 42
    static let standardAccountRowHeight: CGFloat = 58
    static let standardStatusRowHeight: CGFloat = 54
    static let standardGroupHeaderHeight: CGFloat = 18
    static let standardGroupHeaderSpacing: CGFloat = 5
    static let standardLaneSpacing: CGFloat = 4
    /// Standard 콘텐츠 사이에는 divider 1pt와 위아래 여백 8pt가 들어간다.
    static let standardContentDividerHeight: CGFloat = 17
    static let standardMaximumBodyHeight: CGFloat = 287
    static let standardStatusPanelHeight: CGFloat = 72
    static let standardInteractiveStatusPanelHeight: CGFloat = 88
    /// Claude 미인증 패널(standard)은 아이콘+제목+2줄 안내+버튼 2개짜리
    /// rich 패널이라 일반 status panel(88pt)에 들어가지 않는다. 88pt를 그대로
    /// 쓰면 본문이 뷰포트를 넘쳐 푸터와 겹쳐 그려진다(실측 재현).
    static let standardRichAuthPanelHeight: CGFloat = 192

    static func preferredPopoverWidth(compact: Bool) -> CGFloat {
        compact ? compactPopoverWidth : standardPopoverWidth
    }

    static func providerSelectorSize(compact: Bool) -> CGFloat {
        compact ? compactProviderSelectorSize : standardProviderSelectorSize
    }

    static func providerIconSize(compact: Bool) -> CGFloat {
        compact ? compactProviderIconSize : standardProviderIconSize
    }

    static func providerWarningDotSize(compact: Bool) -> CGFloat {
        compact ? compactProviderWarningDotSize : standardProviderWarningDotSize
    }

    static func providerWarningDotInset(compact: Bool) -> CGFloat {
        compact ? compactProviderWarningDotInset : standardProviderWarningDotInset
    }

    static func layoutSpec(
        density: PopoverDensity,
        phase: PopoverContentPhase,
        sections: [PopoverDisplaySection],
        rowCount: Int,
        preferredStandardBodyHeight: CGFloat? = nil,
        richAuthPanel: Bool = false
    ) -> PopoverLayoutSpec {
        let bodyInsets = density.isCompact ? compactBodyInsets : standardBodyInsets
        let sectionSpacing = density.isCompact ? compactSectionSpacing : standardSectionSpacing
        let contentBottomSpacing = density.isCompact ? compactContentBottomSpacing : 0

        if density.isCompact {
            let bodyContentHeight = compactBodyViewportHeight(phase: phase, rowCount: rowCount)
            let totalHeight = max(
                compactMinimumPopoverHeight,
                compactHeaderHeight
                    + bodyInsets.top
                    + bodyContentHeight
                    + bodyInsets.bottom
                    + contentBottomSpacing
                    + dividerHeight
                    + compactFooterHeight
            )
            return PopoverLayoutSpec(
                density: density,
                phase: phase,
                size: CGSize(width: compactPopoverWidth, height: totalHeight),
                bodyContentHeight: bodyContentHeight,
                bodyInsets: bodyInsets,
                contentBottomSpacing: contentBottomSpacing,
                sectionSpacing: sectionSpacing
            )
        }

        let bodyContentHeight = standardBodyViewportHeight(
            phase: phase,
            sections: sections,
            rowCount: rowCount,
            preferredContentHeight: preferredStandardBodyHeight,
            richAuthPanel: richAuthPanel
        )
        return PopoverLayoutSpec(
            density: density,
            phase: phase,
            size: CGSize(
                width: standardPopoverWidth,
                height: standardPopoverHeight(forBodyHeight: bodyContentHeight)
            ),
            bodyContentHeight: bodyContentHeight,
            bodyInsets: bodyInsets,
            contentBottomSpacing: contentBottomSpacing,
            sectionSpacing: sectionSpacing
        )
    }

    static func preferredPopoverHeight(
        compact: Bool,
        phase: PopoverContentPhase,
        rowCount: Int,
        richAuthPanel: Bool = false
    ) -> CGFloat {
        if compact {
            let bodyHeight = compactBodyViewportHeight(phase: phase, rowCount: rowCount)
            return max(
                compactMinimumPopoverHeight,
                compactHeaderHeight
                + compactBodyInsets.top
                + bodyHeight
                + compactBodyInsets.bottom
                + compactContentBottomSpacing
                + dividerHeight
                + compactFooterHeight
            )
        }

        switch phase {
        case .authRequired, .error:
            return standardPopoverHeight(
                forBodyHeight: richAuthPanel
                    ? standardRichAuthPanelHeight
                    : standardInteractiveStatusPanelHeight
            )
        case .loading, .empty:
            return standardPopoverHeight(forBodyHeight: standardStatusPanelHeight)
        case .content:
            return standardPopoverHeight(
                forBodyHeight: standardCatalogContentHeight(
                    sections: [],
                    fallbackRowCount: rowCount
                )
            )
        }
    }

    static func standardBodyViewportHeight(
        phase: PopoverContentPhase,
        sections: [PopoverDisplaySection] = [],
        rowCount: Int = 1,
        preferredContentHeight: CGFloat? = nil,
        richAuthPanel: Bool = false
    ) -> CGFloat {
        switch phase {
        case .authRequired, .error:
            return richAuthPanel
                ? standardRichAuthPanelHeight
                : standardInteractiveStatusPanelHeight
        case .loading, .empty:
            return standardStatusPanelHeight
        case .content:
            return min(
                preferredContentHeight
                    ?? standardCatalogContentHeight(
                        sections: sections,
                        fallbackRowCount: rowCount
                    ),
                standardMaximumBodyHeight
            )
        }
    }

    static func standardCatalogContentHeight(
        sections: [PopoverDisplaySection],
        fallbackRowCount: Int
    ) -> CGFloat {
        let heights: [CGFloat]
        if sections.isEmpty {
            heights = Array(
                repeating: standardUsageRowHeight,
                count: max(fallbackRowCount, 1)
            )
        } else {
            heights = sections.map {
                standardSectionHeight(for: $0.kind)
            }
        }
        let dividerCount = max(heights.count - 1, 0)
        return min(
            heights.reduce(0, +)
                + CGFloat(dividerCount) * standardContentDividerHeight,
            standardMaximumBodyHeight
        )
    }

    static func standardAntigravityContentHeight(
        laneCounts: [Int]
    ) -> CGFloat {
        guard !laneCounts.isEmpty else {
            return standardStatusPanelHeight
        }
        let groupHeights = laneCounts.map { laneCount in
            standardGroupHeaderHeight
                + standardGroupHeaderSpacing
                + CGFloat(max(laneCount, 1))
                    * standardUsageRowHeight
                + CGFloat(max(laneCount - 1, 0))
                    * standardLaneSpacing
        }
        return min(
            groupHeights.reduce(0, +)
                + CGFloat(max(groupHeights.count - 1, 0))
                    * standardContentDividerHeight,
            standardMaximumBodyHeight
        )
    }

    static func compactBodyViewportHeight(phase: PopoverContentPhase, rowCount: Int = compactMaximumVisibleRows) -> CGFloat {
        switch phase {
        case .content:
            return compactContentBodyHeight(rowCount: rowCount)
        case .authRequired, .error:
            return compactInteractiveStatusPanelHeight
        case .loading, .empty:
            return compactStatusPanelHeight
        }
    }

    /// 컴팩트 본문 높이 — 행 수에 맞춰 늘어나고, 최대 표시 행 수를 넘으면 스크롤로 전환됩니다.
    /// (과거에는 3행 고정이라 모델 행이 늘어나면 잘렸음)
    static func compactContentBodyHeight(rowCount: Int) -> CGFloat {
        let rows = min(max(rowCount, 1), compactMaximumVisibleRows)
        return compactUsageRowHeight * CGFloat(rows) + compactSectionSpacing * CGFloat(max(0, rows - 1))
    }

    static func standardPopoverHeight(forBodyHeight bodyHeight: CGFloat) -> CGFloat {
        standardHeaderContainerHeight
            + standardBodyInsets.top
            + bodyHeight
            + standardBodyInsets.bottom
            + standardMainSectionBottomSpacing
            + dividerHeight
            + standardFooterContainerHeight
            + standardShortcutFooterHeight
    }

    static func compactSectionHeight(for kind: PopoverDisplaySectionKind) -> CGFloat {
        switch kind {
        case .usage:
            return compactUsageRowHeight
        case .credits, .resetCredits:
            return compactCreditsRowHeight
        case .overage:
            return compactOverageRowHeight
        case .account:
            return compactOverageRowHeight
        case .status:
            return compactStatusRowHeight
        }
    }

    static func standardSectionHeight(
        for kind: PopoverDisplaySectionKind
    ) -> CGFloat {
        switch kind {
        case .usage:
            return standardUsageRowHeight
        case .resetCredits, .overage:
            return standardSecondaryUsageRowHeight
        case .credits:
            return standardCreditsRowHeight
        case .account:
            return standardAccountRowHeight
        case .status:
            return standardStatusRowHeight
        }
    }

}

struct PopoverStateContainer<Content: View>: View {
    let layoutSpec: PopoverLayoutSpec
    private let content: Content

    init(layoutSpec: PopoverLayoutSpec, @ViewBuilder content: () -> Content) {
        self.layoutSpec = layoutSpec
        self.content = content()
    }

    var body: some View {
        content
            .frame(
                maxWidth: layoutSpec.size.width,
                minHeight: layoutSpec.bodyContentHeight,
                maxHeight:
                    layoutSpec.isCompact
                        ? layoutSpec.bodyContentHeight
                        : nil,
                alignment: .topLeading
            )
            .padding(.top, layoutSpec.bodyInsets.top)
            .padding(.leading, layoutSpec.bodyInsets.leading)
            .padding(.trailing, layoutSpec.bodyInsets.trailing)
            .padding(.bottom, layoutSpec.bodyInsets.bottom + layoutSpec.contentBottomSpacing)
    }
}
