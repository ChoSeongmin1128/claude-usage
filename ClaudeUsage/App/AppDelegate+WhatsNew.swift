import AppKit

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
            onAction: { [weak self] action in
                switch action {
                case .openSettings(let panel):
                    self?.showSettingsWindow(settingsPanelRawValue: panel.rawValue)
                }
            },
            onClose: { WhatsNewState.markSeen(version, defaults: .standard) })
    }
}
