import AppKit
import SwiftUI

struct ServiceStatusPanelView: View {
    static let width: CGFloat = 300
    private static let incidentIndent = AppDesign.Space.card

    let content: ServiceStatusPanelContent

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.row) {
            Text(ServiceStatusPanelContent.caption)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(content.services.enumerated()), id: \.element.kind) { index, service in
                if index > 0 {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(height: 0.5)
                }
                serviceBlock(service)
            }
        }
        .padding(.vertical, AppDesign.Space.label)
        .padding(.horizontal, AppDesign.Space.content)
        .frame(width: Self.width, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: AppDesign.Radius.panel)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }

    private func serviceBlock(_ service: ServiceStatusPanelContent.Service) -> some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.row) {
            HStack(spacing: AppDesign.Space.control) {
                Circle()
                    .fill(Self.color(for: service.tone))
                    .frame(width: 8, height: 8)
                Text(verbatim: service.name)
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: AppDesign.Space.row)
                Text(verbatim: service.stateText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(service.tone == .normal ? HierarchicalShapeStyle.secondary : .primary)
            }
            ForEach(Array(service.rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: AppDesign.Space.tight) {
                    Text(verbatim: row.title)
                        .font(.system(size: 12))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = row.detail {
                        // 한 줄에 다 들어가지 않으면 업데이트 시각이 중간에서 갈리지 않도록 다음 줄로 내린다.
                        ViewThatFits(in: .horizontal) {
                            metadataText(detail)
                                .lineLimit(1)
                            VStack(alignment: .leading, spacing: AppDesign.Space.tight) {
                                if let components = row.components {
                                    metadataText(components)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if let updatedText = row.updatedText {
                                    metadataText(updatedText)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
                .padding(.leading, Self.incidentIndent)
            }
            if let overflow = service.overflowText {
                metadataText(overflow)
                    .padding(.leading, Self.incidentIndent)
            }
        }
    }

    private func metadataText(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }

    private static func color(for tone: ServiceStatusPanelContent.Tone) -> Color {
        switch tone {
        case .normal: Color(nsColor: .systemGreen)
        case .minor: Color(nsColor: .systemOrange)
        case .major: Color(nsColor: .systemRed)
        }
    }
}

/// 마우스와 키 입력을 받지 않고 앱을 활성화하지 않는 패널. 메뉴바 아이템 아래에 떠서 상태만 보여 준다.
final class ServiceStatusPanelWindowPresenter: ServiceStatusPanelPresenting {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<ServiceStatusPanelView>?

    var isVisible: Bool {
        panel?.isVisible == true
    }

    func show(_ content: ServiceStatusPanelContent, anchor: ServiceStatusPanelAnchor) {
        let panel = panel ?? makePanel(content: content)
        guard let hostingView else { return }
        hostingView.rootView = ServiceStatusPanelView(content: content)
        let frame = ServiceStatusPanelPlacement.frame(size: hostingView.fittingSize, anchor: anchor)
        panel.setFrame(frame, display: true)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        panel.invalidateShadow()
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
        panel.ignoresMouseEvents = true
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

        let hostingView = NSHostingView(rootView: ServiceStatusPanelView(content: content))
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = background.bounds
        background.addSubview(hostingView)
        panel.contentView = background

        self.panel = panel
        self.hostingView = hostingView
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
