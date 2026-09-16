import AppKit
import SwiftUI

/// NSPopover sets its content view's final size before its native frame finishes resizing.
/// Keep our hosted content inside the currently visible viewport, without changing AppKit's views.
@MainActor
final class PopoverViewportView: NSView {
    let hostingView: NSHostingView<PopoverView>
    private var margins: NSEdgeInsets?
    private weak var observedWindow: NSWindow?

    init(rootView: PopoverView) {
        hostingView = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        hostingView.sizingOptions = []
        addSubview(hostingView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(rootView:)") }

    func prepareForResize() {
        captureMargins()
    }

    func finishResize() {
        captureMargins()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observedWindow {
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didResizeNotification, object: observedWindow)
        }
        observedWindow = window
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowDidResize), name: NSWindow.didResizeNotification, object: window)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        if margins == nil { captureMargins() }
        let viewport = visibleContentRect
        if hostingView.frame != viewport { hostingView.frame = viewport }
        hostingView.layoutSubtreeIfNeeded()
    }

    var visibleContentRect: CGRect {
        guard let superview, let margins else { return bounds }
        let parentBounds = superview.bounds
        let content = CGRect(
            x: parentBounds.minX + margins.left, y: parentBounds.minY + margins.bottom,
            width: max(0, parentBounds.width - margins.left - margins.right),
            height: max(0, parentBounds.height - margins.top - margins.bottom))
        let visible = convert(content, from: superview).intersection(bounds)
        return visible.isNull ? .zero : visible
    }

    private func captureMargins() {
        guard let superview, !frame.isEmpty else { return }
        let parent = superview.bounds
        let insets = NSEdgeInsets(
            top: parent.maxY - frame.maxY, left: frame.minX - parent.minX,
            bottom: frame.minY - parent.minY, right: parent.maxX - frame.maxX)
        guard min(insets.top, insets.left, insets.bottom, insets.right) >= 0 else { return }
        margins = insets
    }

    @objc private func windowDidResize(_ notification: Notification) {
        needsLayout = true
        layoutSubtreeIfNeeded()
    }
}
