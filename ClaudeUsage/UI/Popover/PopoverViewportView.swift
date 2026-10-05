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
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        margins = nil
        needsLayout = true
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
    }

    var visibleContentRect: CGRect {
        guard let superview else { return bounds }
        let parentBounds = superview.bounds
        guard !parentBounds.isEmpty else { return .zero }
        guard let margins else {
            let visible = bounds.intersection(convert(parentBounds, from: superview))
            return visible.isNull || visible.isEmpty ? .zero : visible
        }
        let content = CGRect(
            x: parentBounds.minX + margins.left, y: parentBounds.minY + margins.bottom,
            width: max(0, parentBounds.width - margins.left - margins.right),
            height: max(0, parentBounds.height - margins.top - margins.bottom))
        guard !content.isEmpty else { return .zero }
        return convert(content, from: superview)
    }

    var nativeVisibleContentSize: CGSize? {
        guard margins != nil else { return nil }
        let visible = visibleContentRect
        return visible.isEmpty ? nil : visible.size
    }

    private func captureMargins() {
        guard margins == nil, let superview, !frame.isEmpty else { return }
        let parent = superview.bounds
        let insets = NSEdgeInsets(
            top: parent.maxY - frame.maxY, left: frame.minX - parent.minX,
            bottom: frame.minY - parent.minY, right: parent.maxX - frame.maxX)
        guard min(insets.top, insets.left, insets.bottom, insets.right) >= 0 else { return }
        margins = insets
    }

    @objc private func windowDidResize(_ notification: Notification) {
        needsLayout = true
    }
}
