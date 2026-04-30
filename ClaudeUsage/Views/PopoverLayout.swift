import SwiftUI

enum PopoverLayoutMetrics {
    static let standardPopoverWidth: CGFloat = 368
    static let compactPopoverWidth: CGFloat = 296
    static let standardHeaderContainerHeight: CGFloat = 44
    static let standardFooterContainerHeight: CGFloat = 30
    static let standardShortcutFooterHeight: CGFloat = 16
    static let standardMainSectionBottomSpacing: CGFloat = 2
    static let compactHeaderHeight: CGFloat = 30
    static let compactFooterHeight: CGFloat = 31
    static let dividerHeight: CGFloat = 1
    static let compactBodyInsets = EdgeInsets(top: 6, leading: 10, bottom: 3, trailing: 10)
    static let standardBodyInsets = EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
    static let compactSectionSpacing: CGFloat = 3
    static let standardSectionSpacing: CGFloat = 12
    static let compactRowLabelWidth: CGFloat = 100
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
    static let compactMaximumVisibleRows = 3
    static let compactMinimumPopoverHeight: CGFloat = 96
    static let compactContentBottomSpacing: CGFloat = 5
    static let standardStatusPanelHeight: CGFloat = 72
    static let standardInteractiveStatusPanelHeight: CGFloat = 88

    static func preferredPopoverWidth(compact: Bool) -> CGFloat {
        compact ? compactPopoverWidth : standardPopoverWidth
    }

    static func layoutSpec(
        density: PopoverDensity,
        phase: PopoverContentPhase,
        sections: [PopoverDisplaySection],
        rowCount: Int
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

        let bodyContentHeight = standardBodyViewportHeight(phase: phase)
        return PopoverLayoutSpec(
            density: density,
            phase: phase,
            size: CGSize(
                width: standardPopoverWidth,
                height: preferredPopoverHeight(compact: false, phase: phase, rowCount: rowCount)
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
        rowCount: Int
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
            return standardPopoverHeight(forBodyHeight: standardInteractiveStatusPanelHeight)
        case .loading, .empty:
            return standardPopoverHeight(forBodyHeight: standardStatusPanelHeight)
        case .content:
            switch rowCount {
            case ...2:
                return 256
            case 3:
                return 300
            default:
                return 336
            }
        }
    }

    static func standardBodyViewportHeight(phase: PopoverContentPhase) -> CGFloat {
        switch phase {
        case .authRequired, .error:
            return standardInteractiveStatusPanelHeight
        case .loading, .empty:
            return standardStatusPanelHeight
        case .content:
            return 108
        }
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

    static func compactContentBodyHeight(rowCount: Int) -> CGFloat {
        compactFixedContentBodyHeight
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
        case .credits:
            return compactCreditsRowHeight
        case .overage:
            return compactOverageRowHeight
        case .account:
            return compactOverageRowHeight
        case .status:
            return compactStatusRowHeight
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
                maxHeight: layoutSpec.isCompact ? layoutSpec.bodyContentHeight : nil,
                alignment: .topLeading
            )
            .padding(.top, layoutSpec.bodyInsets.top)
            .padding(.leading, layoutSpec.bodyInsets.leading)
            .padding(.trailing, layoutSpec.bodyInsets.trailing)
            .padding(.bottom, layoutSpec.bodyInsets.bottom + layoutSpec.contentBottomSpacing)
    }
}
