import AppKit
import SwiftUI

final class SettingsWindowCoordinator: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?

    @discardableResult
    func focusIfVisible() -> Bool {
        guard let window, window.isVisible else { return false }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func present(rootView: SettingsView) {
        let windowSize = NSSize(width: 760, height: 600)
        let hostingController = NSHostingController(rootView: rootView)
        hostingController.view.frame = NSRect(origin: .zero, size: windowSize)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = "ClaudeUsage 설정"
        window.contentMinSize = windowSize
        window.setContentSize(windowSize)
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

    func invalidate() {
        window?.delegate = nil
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window == self.window else { return }
        self.window = nil
    }
}
