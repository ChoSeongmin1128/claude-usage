import AppKit
import SwiftUI

@MainActor
final class WhatsNewWindowCoordinator: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private var onClose: (() -> Void)?

    func present(
        pages: [WhatsNewPage], toggle: @escaping (WhatsNewPage.Action) -> Binding<Bool>?,
        onAction: @escaping (WhatsNewPage.Action) -> Void, onClose: @escaping () -> Void
    ) {
        guard !pages.isEmpty else { return }
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        self.onClose = onClose
        let view = WhatsNewView(
            pages: pages,
            toggle: toggle,
            onAction: { [weak self] action in
                self?.close()
                onAction(action)
            },
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

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window == self.window else { return }
        self.window = nil
        let onClose = self.onClose
        self.onClose = nil
        onClose?()
    }
}
