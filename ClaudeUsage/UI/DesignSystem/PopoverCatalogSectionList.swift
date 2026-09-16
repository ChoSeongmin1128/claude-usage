import SwiftUI

/// The live popover and settings preview use the same row spacing and separators.
struct PopoverCatalogSectionList: View {
    let sections: [PopoverDisplaySection]
    let density: PopoverDensity

    var body: some View {
        VStack(spacing: density.isCompact ? PopoverLayoutMetrics.compactSectionSpacing : 0) {
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                if index > 0 && !density.isCompact {
                    Divider().padding(.vertical, AppDesign.Space.row)
                }
                PopoverDisplaySectionView(section: section, density: density)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
