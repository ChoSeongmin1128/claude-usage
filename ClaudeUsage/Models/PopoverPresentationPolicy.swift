import AppKit

struct PopoverPresentationPolicy {
    let layoutSpec: PopoverLayoutSpec
    let isShown: Bool
    let measuredContentSize: CGSize?
    let screenVisibleFrame: CGRect?

    func targetSize() -> CGSize {
        guard layoutSpec.density == .standard, layoutSpec.phase == .content, isShown else {
            return layoutSpec.size
        }

        guard let measuredContentSize, measuredContentSize.height > 0 else {
            return layoutSpec.size
        }

        let visibleScreenHeight = screenVisibleFrame?.height ?? (layoutSpec.size.height + 100)
        let maximumHeight = max(layoutSpec.size.height, visibleScreenHeight - 100)

        return CGSize(
            width: layoutSpec.size.width,
            height: min(measuredContentSize.height, maximumHeight)
        )
    }
}
