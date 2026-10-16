import AppKit
import SwiftUI

struct ServiceStatusPanelView: View {
    @Environment(\.colorScheme) private var scheme
    static let width: CGFloat = AppDesign.Hover.width
    let content: ServiceStatusPanelContent
    var reservesScrollerSpace = false
    var onItemFrames: ([String: CGRect]) -> Void = { _ in }

    var body: some View {
        let services = content.visibleServices
        HoverPanelWidthLayout(fixedWidth: services.isEmpty ? nil : Self.width, maximumWidth: Self.width) {
            VStack(alignment: .leading, spacing: AppDesign.Hover.incidentGap) {
                if !content.usage.providers.isEmpty {
                    MenuBarHoverUsageView(content: content.usage)
                }
                ForEach(Array(services.enumerated()), id: \.element.kind) { index, service in
                    if index > 0
                        ? service.tone != .normal || services[index - 1].tone != .normal
                        : !content.usage.providers.isEmpty
                    {
                        Divider()
                    }
                    serviceBlock(service)
                }
            }
            .padding(.trailing, reservesScrollerSpace ? AppDesign.Hover.scrollerInset : 0)
            .padding(AppDesign.Hover.inset)
        }
        .onHoverItemFrames(onItemFrames)
        .accessibilityHidden(true)
    }

    private func serviceBlock(_ service: ServiceStatusPanelContent.Service) -> some View {
        VStack(alignment: .leading, spacing: AppDesign.Hover.incidentGap) {
            HStack(spacing: AppDesign.Space.control) {
                Circle().fill(AppDesign.Text.status(Self.color(for: service.tone), scheme: scheme))
                    .frame(width: AppDesign.Hover.statusDot, height: AppDesign.Hover.statusDot)
                Text(verbatim: service.name).font(AppDesign.Typography.caption.weight(.semibold))
                Spacer(minLength: AppDesign.Space.row)
                if service.tone != .normal {
                    Text(verbatim: service.stateText).font(AppDesign.Typography.caption).foregroundStyle(.primary)
                }
            }
            .hoverPositionID("status.\(service.kind.rawValue)")
            ForEach(Array(service.rows.enumerated()), id: \.offset) { index, row in
                VStack(alignment: .leading, spacing: AppDesign.Hover.rowGap) {
                    Text(verbatim: row.title).font(AppDesign.Typography.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = row.detail {
                        ViewThatFits(in: .horizontal) {
                            metadata(detail).lineLimit(1)
                            VStack(alignment: .leading, spacing: AppDesign.Hover.rowGap) {
                                if let components = row.components {
                                    metadata(components).fixedSize(horizontal: false, vertical: true)
                                }
                                HStack(spacing: AppDesign.Space.control) {
                                    if let phase = row.phase { metadata(phase).fixedSize() }
                                    if let updated = row.updatedText { metadata(updated).fixedSize() }
                                }
                            }
                        }
                    }
                }
                .padding(.leading, AppDesign.Hover.statusDot + AppDesign.Space.control)
                .hoverPositionID(rowID(row, index: index, service: service))
            }
        }
    }

    private func metadata(_ text: String) -> some View {
        Text(verbatim: text).font(AppDesign.Typography.metadata).foregroundStyle(AppDesign.Text.secondary)
    }

    private func rowID(_ row: ServiceStatusPanelContent.Row, index: Int, service: ServiceStatusPanelContent.Service)
        -> String
    {
        let occurrence = service.rows.prefix(index).filter { $0.id == row.id }.count
        return "incident.\(service.kind.rawValue).\(row.id).\(occurrence)"
    }

    private static func color(for tone: ServiceStatusPanelContent.Tone) -> Color {
        switch tone {
        case .normal: Color(nsColor: .systemGreen)
        case .minor: Color(nsColor: .systemOrange)
        case .major: Color(nsColor: .systemRed)
        }
    }
}

/// 장애 문구는 고정 폭에서 줄을 바꾸고, 사용량만 있으면 내용 폭까지만 쓴다(고정 폭을 넘으면 고정 폭에서 줄을 바꾼다).
private struct HoverPanelWidthLayout: Layout {
    let fixedWidth: CGFloat?
    let maximumWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = fixedWidth ?? min(maximumWidth, content.sizeThatFits(.unspecified).width.rounded(.up))
        return CGSize(width: width, height: content.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

/// 스크롤을 받되 앱과 키보드 포커스를 활성화하지 않는 메뉴바 패널.
final class ServiceStatusPanelWindowPresenter: ServiceStatusPanelPresenting {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<ServiceStatusPanelView>?
    private var scrollView: NSScrollView?
    private var itemFrames: [String: CGRect] = [:]
    private var pendingScrollAnchor: HoverScrollAnchor?
    var visibleFrame: NSRect? { panel?.isVisible == true ? panel?.frame : nil }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    func show(_ content: ServiceStatusPanelContent, anchor: ServiceStatusPanelAnchor) {
        let panel = panel ?? makePanel(content: content)
        guard let hostingView, let scrollView else { return }
        if panel.isVisible {
            pendingScrollAnchor = HoverScrollAnchor.capture(top: scrollView.contentView.bounds.minY, frames: itemFrames)
        } else {
            pendingScrollAnchor = nil
            scrollView.contentView.scroll(to: .zero)
        }
        hostingView.rootView = rootView(content)
        var size = hostingView.fittingSize
        let maximumHeight = max(
            0,
            min(anchor.itemFrame.minY - ServiceStatusPanelPlacement.gap, anchor.visibleFrame.maxY)
                - anchor.visibleFrame.minY)
        if size.height > maximumHeight {
            hostingView.rootView = rootView(content, reservesScrollerSpace: true)
            size = hostingView.fittingSize
        }
        let frame = ServiceStatusPanelPlacement.frame(size: size, anchor: anchor)
        hostingView.frame = NSRect(origin: .zero, size: size)
        panel.setFrame(frame, display: true)
        scrollView.hasVerticalScroller = size.height > frame.height
        scrollView.reflectScrolledClipView(scrollView.contentView)
        if !panel.isVisible { panel.orderFrontRegardless() }
        panel.invalidateShadow()
    }

    private func rootView(_ content: ServiceStatusPanelContent, reservesScrollerSpace: Bool = false)
        -> ServiceStatusPanelView
    {
        ServiceStatusPanelView(content: content, reservesScrollerSpace: reservesScrollerSpace) { [weak self] frames in
            guard let self else { return }
            self.itemFrames = frames
            guard let pending = self.pendingScrollAnchor, let scrollView = self.scrollView else { return }
            self.pendingScrollAnchor = nil
            guard let top = pending.restoredTop(in: frames) else { return }
            let maximum = max(0, (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(maximum, max(0, top))))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel(content: ServiceStatusPanelContent) -> NSPanel {
        let panel = NonActivatingStatusPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: ServiceStatusPanelView.width, height: 1)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        // 앱이 비활성일 때 띄우는 패널이라 비활성 시 숨기는 NSPanel 기본값을 끈다.
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.setAccessibilityElement(false)

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: AppDesign.Radius.panel)

        let hostingView = NSHostingView(rootView: rootView(content))
        let scrollView = HoverStatusScrollView(frame: background.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.documentView = hostingView
        background.addSubview(scrollView)
        panel.contentView = background

        self.panel = panel
        self.hostingView = hostingView
        self.scrollView = scrollView
        return panel
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

private final class NonActivatingStatusPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class HoverStatusScrollView: NSScrollView {
    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
