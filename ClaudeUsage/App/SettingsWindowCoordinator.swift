import AppKit
import SwiftUI

final class SettingsWindowCoordinator: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private var snapshot: AppSettings.Snapshot?
    var onRestoreSnapshot: ((AppSettings.Snapshot) -> Void)?

    @discardableResult
    func focusIfVisible() -> Bool {
        guard let window, window.isVisible else { return false }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func present(rootView: SettingsView, snapshot: AppSettings.Snapshot) {
        self.snapshot = snapshot

        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "ClaudeUsage 설정"
        window.styleMask = [.titled, .closable]
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close(clearSnapshot: Bool = false) {
        if clearSnapshot {
            snapshot = nil
        }
        window?.close()
    }

    func refreshSnapshot(_ snapshot: AppSettings.Snapshot) {
        self.snapshot = snapshot
    }

    func invalidate() {
        window?.delegate = nil
        window = nil
        snapshot = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window == self.window else { return }
        if let snapshot {
            onRestoreSnapshot?(snapshot)
        }
        snapshot = nil
        self.window = nil
    }
}
