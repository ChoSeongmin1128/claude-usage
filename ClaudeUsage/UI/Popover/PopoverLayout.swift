import SwiftUI

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
