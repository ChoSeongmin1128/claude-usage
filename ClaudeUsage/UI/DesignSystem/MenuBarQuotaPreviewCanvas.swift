import AppKit
import SwiftUI

struct MenuBarQuotaPreviewLayout {
    var leadingImage: NSImage? = nil
    var units: [MenuBarQuotaRenderedUnit]
    var trailingImage: NSImage? = nil

    var width: CGFloat {
        let images = [leadingImage].compactMap { $0 } + units.map(\.image) + [trailingImage].compactMap { $0 }
        return images.reduce(0) { $0 + $1.size.width } + CGFloat(max(0, images.count - 1)) * 4
    }
}

struct MenuBarQuotaPreview: NSViewRepresentable {
    let layout: MenuBarQuotaPreviewLayout
    var onSelect: ([String]) -> Void
    var onReorder: ([[String]]) -> Void
    var onHover: (String?) -> Void = { _ in }

    func makeNSView(context: Context) -> MenuBarQuotaPreviewCanvas { MenuBarQuotaPreviewCanvas() }

    func updateNSView(_ view: MenuBarQuotaPreviewCanvas, context: Context) {
        view.update(layout: layout, onSelect: onSelect, onReorder: onReorder, onHover: onHover)
    }

    static func dismantleNSView(_ view: MenuBarQuotaPreviewCanvas, coordinator: ()) {
        view.cancelDrag()
        view.onSelect = nil
        view.onReorder = nil
        view.onHover = nil
    }
}

final class MenuBarQuotaPreviewCanvas: NSView {
    var onSelect: (([String]) -> Void)?
    var onReorder: (([[String]]) -> Void)?
    var onHover: ((String?) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?
    private var layout = MenuBarQuotaPreviewLayout(units: [])
    private var currentUnits: [MenuBarQuotaRenderedUnit] = []
    private var drag: DragState?

    private struct DragState {
        let ids: [String]
        let selectedID: String?
        let startPoint: CGPoint
        let originalFrame: CGRect
        let targets: [(ids: [String], midpoint: CGFloat)]
        var x: CGFloat
        var moved = false
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: max(1, layout.width), height: 30) }

    func update(
        layout: MenuBarQuotaPreviewLayout,
        onSelect: @escaping ([String]) -> Void,
        onReorder: @escaping ([[String]]) -> Void,
        onHover: @escaping (String?) -> Void = { _ in }
    ) {
        if self.layout.units.map(\.ids) != layout.units.map(\.ids) { cancelDrag() }
        self.layout = layout
        self.onSelect = onSelect
        self.onReorder = onReorder
        self.onHover = onHover
        if drag == nil { currentUnits = layout.units }
        invalidateIntrinsicContentSize()
        needsDisplay = true
        setAccessibilityLabel("메뉴바 미리보기")
        setAccessibilityValue(layout.units.map(\.title).joined(separator: ", "))
        setAccessibilityHelp("아이콘을 가로로 끌어 순서를 바꾸고, 눌러 표시 방식을 편집합니다.")
    }

    func frames(for units: [MenuBarQuotaRenderedUnit]) -> [CGRect] {
        var x = layout.leadingImage.map { $0.size.width + 4 } ?? 0
        return units.map { unit in
            defer { x += unit.image.size.width + 4 }
            return CGRect(
                x: x, y: (bounds.height - unit.image.size.height) / 2,
                width: unit.image.size.width, height: unit.image.size.height)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let leading = layout.leadingImage {
            draw(
                leading,
                at: CGRect(
                    x: 0, y: (bounds.height - leading.size.height) / 2,
                    width: leading.size.width, height: leading.size.height))
        }
        let positions = frames(for: currentUnits)
        for (index, unit) in currentUnits.enumerated() {
            let moving = drag?.moved == true && drag?.ids == unit.ids
            draw(unit.image, at: positions[index], opacity: moving ? 0.2 : 1)
        }
        if let drag, drag.moved, let unit = currentUnits.first(where: { $0.ids == drag.ids }) {
            let rect = CGRect(
                x: drag.x, y: drag.originalFrame.minY,
                width: drag.originalFrame.width, height: drag.originalFrame.height)
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: -3, dy: -2), xRadius: 4, yRadius: 4).fill()
            draw(unit.image, at: rect)
        }
        if let trailing = layout.trailingImage {
            let x = positions.last.map { $0.maxX + 4 } ?? (layout.leadingImage.map { $0.size.width + 4 } ?? 0)
            draw(
                trailing,
                at: CGRect(
                    x: x, y: (bounds.height - trailing.size.height) / 2,
                    width: trailing.size.width, height: trailing.size.height))
        }
    }

    private func draw(_ image: NSImage, at rect: CGRect, opacity: CGFloat = 1) {
        image.draw(
            in: rect, from: .zero, operation: .sourceOver, fraction: opacity,
            respectFlipped: true, hints: nil)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard drag == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        let positions = frames(for: currentUnits)
        guard let index = positions.firstIndex(where: { $0.contains(point) }) else {
            onHover?(nil)
            return
        }
        onHover?(
            currentUnits[index].selectedID(
                at: CGPoint(
                    x: point.x - positions[index].minX, y: point.y - positions[index].minY)))
    }

    override func mouseExited(with event: NSEvent) { onHover?(nil) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let positions = frames(for: currentUnits)
        guard let index = positions.firstIndex(where: { $0.insetBy(dx: -2, dy: -4).contains(point) }) else { return }
        let local = CGPoint(x: point.x - positions[index].minX, y: point.y - positions[index].minY)
        drag = DragState(
            ids: currentUnits[index].ids, selectedID: currentUnits[index].selectedID(at: local), startPoint: point,
            originalFrame: positions[index],
            targets: zip(currentUnits, positions).map { ($0.0.ids, $0.1.midX) }, x: positions[index].minX)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        let delta = point.x - drag.startPoint.x
        drag.moved = drag.moved || hypot(delta, point.y - drag.startPoint.y) >= 3
        guard drag.moved else { return }
        drag.x = drag.originalFrame.minX + delta
        self.drag = drag
        guard let source = currentUnits.firstIndex(where: { $0.ids == drag.ids }) else { return }
        let candidates = drag.targets.filter { $0.ids != drag.ids }
        let center = drag.x + drag.originalFrame.width / 2
        let next = candidates.firstIndex { center < $0.midpoint } ?? candidates.count
        let moving = currentUnits.remove(at: source)
        currentUnits = candidates.compactMap { candidate in currentUnits.first { $0.ids == candidate.ids } }
        currentUnits.insert(moving, at: next)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag else { return }
        self.drag = nil
        if drag.moved {
            let ids = currentUnits.map(\.ids)
            if ids != layout.units.map(\.ids) { onReorder?(ids) }
        } else if let id = drag.selectedID {
            onSelect?([id])
        }
        currentUnits = layout.units
        needsDisplay = true
    }

    override func cancelOperation(_ sender: Any?) { cancelDrag() }

    func cancelDrag() {
        drag = nil
        currentUnits = layout.units
        needsDisplay = true
    }
}
