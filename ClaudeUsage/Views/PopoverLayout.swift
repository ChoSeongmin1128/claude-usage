import SwiftUI

enum PopoverLayoutMetrics {
    static let standardPopoverWidth: CGFloat = 368
    static let compactPopoverWidth: CGFloat = 296
    static let compactHeaderHeight: CGFloat = 30
    static let compactFooterHeight: CGFloat = 31
    static let dividerHeight: CGFloat = 1
    static let compactBodyInsets = EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10)
    static let standardBodyInsets = EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
    static let compactSectionSpacing: CGFloat = 3
    static let standardSectionSpacing: CGFloat = 12
    static let compactRowLabelWidth: CGFloat = 100
    static let compactRowMeterWidth: CGFloat = 150
    static let compactRowSpacing: CGFloat = 6
    static let compactUsageRowHeight: CGFloat = 18
    static let compactCreditsRowHeight: CGFloat = 18
    static let compactStatusRowHeight: CGFloat = 18
    static let compactOverageRowHeight: CGFloat = 22
    static let compactProgressBarHeight: CGFloat = 8
    static let compactStatusPanelHeight: CGFloat = 40
    static let compactInteractiveStatusPanelHeight: CGFloat = 48
    static let compactMinimumPopoverHeight: CGFloat = 96
    static let compactContentBottomSpacing: CGFloat = 5

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
            let bodyContentHeight = compactBodyContentHeight(phase: phase, sections: sections)
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

        let bodyContentHeight = minimumBodyHeight(compact: false, phase: phase)
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
            if phase == .content {
                let contentHeight = compactUsageRowHeight * CGFloat(max(rowCount, 1))
                    + compactSectionSpacing * CGFloat(max(0, rowCount - 1))
                return max(
                    compactMinimumPopoverHeight,
                    compactHeaderHeight
                        + compactBodyInsets.top
                        + contentHeight
                        + compactBodyInsets.bottom
                        + compactContentBottomSpacing
                        + dividerHeight
                        + compactFooterHeight
                )
            }
            let statusHeight = phase == .authRequired || phase == .error
                ? compactInteractiveStatusPanelHeight
                : compactStatusPanelHeight
            return compactHeaderHeight
                + compactBodyInsets.top
                + statusHeight
                + compactBodyInsets.bottom
                + compactContentBottomSpacing
                + dividerHeight
                + compactFooterHeight
        }

        switch phase {
        case .authRequired, .loading, .error, .empty:
            return 216
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

    static func minimumBodyHeight(
        compact: Bool,
        phase: PopoverContentPhase
    ) -> CGFloat {
        if compact {
            switch phase {
            case .content:
                return 44
            case .authRequired, .loading, .error, .empty:
                return 36
            }
        }

        switch phase {
        case .content:
            return 108
        case .authRequired, .loading, .error, .empty:
            return 72
        }
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

    static func compactBodyContentHeight(
        phase: PopoverContentPhase,
        sections: [PopoverDisplaySection]
    ) -> CGFloat {
        guard phase == .content else {
            return phase == .authRequired || phase == .error
                ? compactInteractiveStatusPanelHeight
                : compactStatusPanelHeight
        }

        let sectionHeights = sections.map { compactSectionHeight(for: $0.kind) }
        guard !sectionHeights.isEmpty else { return 1 }
        return sectionHeights.reduce(0, +)
            + compactSectionSpacing * CGFloat(max(0, sectionHeights.count - 1))
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
                maxWidth: .infinity,
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
