import AppKit
import SwiftUI

extension AppDelegate {
    private var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    func presentWhatsNewIfNeeded() {
        guard AppSettings.shared.welcomeState != .pending else { return }
        let defaults = UserDefaults.standard
        let pages = WhatsNewCatalog.pagesToShow(
            after: WhatsNewState.lastSeen(defaults: defaults), upTo: currentAppVersion,
            notes: UpdateNotesQueue.pending(defaults: defaults))
        presentWhatsNew(pages)
    }

    func presentLatestWhatsNew() {
        presentWhatsNew(WhatsNewCatalog.latestPages(upTo: currentAppVersion))
    }

    private func presentWhatsNew(_ pages: [WhatsNewPage]) {
        let version = currentAppVersion
        whatsNewWindowCoordinator.present(
            pages: pages,
            toggle: { action in
                guard action == .toggleResetCreditsInMenuBar else { return nil }
                let kinds: [AppProviderKind] = [.claude, .codex]
                return Binding(
                    get: { kinds.contains { AppSettings.shared.resetCreditMenuBarMode(for: $0) != .off } },
                    set: { isOn in
                        kinds.forEach { AppSettings.shared.setResetCreditMenuBarMode(isOn ? .always : .off, for: $0) }
                    })
            },
            onAction: { [weak self] action in
                switch action {
                case .openSettings(let panel, let section):
                    self?.showSettingsWindow(destination: SettingsDestination(panel: panel, section: section))
                case .toggleResetCreditsInMenuBar:
                    break
                }
            },
            onClose: { WhatsNewState.markSeen(version, defaults: .standard) })
    }
}
