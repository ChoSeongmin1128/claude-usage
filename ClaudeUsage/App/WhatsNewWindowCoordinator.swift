import AppKit
import SwiftUI

@MainActor
final class WhatsNewWindowCoordinator: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private var onClose: (() -> Void)?
    private var onAction: ((WhatsNewPage.Action) -> Void)?

    func present(
        pages: [WhatsNewPage], toggle: @escaping (WhatsNewPage.Action) -> Binding<Bool>?,
        onAction: @escaping (WhatsNewPage.Action) -> Void, onClose: @escaping () -> Void
    ) {
        guard !pages.isEmpty else { return }
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        self.onClose = onClose
        self.onAction = onAction
        let view = WhatsNewView(
            pages: pages,
            toggle: toggle,
            onAction: { [weak self] action in self?.performAction(action) },
            onClose: { [weak self] in self?.close() })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "새 기능"
        window.styleMask = [.titled, .closable]
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // 설정으로 이동한 뒤 같은 안내로 돌아올 수 있어야 한다.
    func performAction(_ action: WhatsNewPage.Action) {
        onAction?(action)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window == self.window else { return }
        self.window = nil
        let onClose = self.onClose
        self.onClose = nil
        self.onAction = nil
        onClose?()
    }
}
