import AppKit
import CedricCore

/// Closing a tab with unsaved edits to a real file keeps the edits for
/// Reopen Closed Tab (ClosedTabs.swift), but the file isn't written. Once
/// per launch, the tab that comes forward says so, with Save Now.
@MainActor
enum CloseNotice {
    static var shown = false
}

extension AppDelegate {
    /// A file tab with unsaved edits was closed: the notice, once per launch.
    func noteClosedUnsaved(id: UUID, name: String) {
        guard !CloseNotice.shown else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !CloseNotice.shown, let tab = self.currentTab ?? self.tabs.last else { return }
            CloseNotice.shown = true
            tab.showNotice(String(localized: "Your changes to “\(name)” weren’t saved to the file. Reopen Closed Tab (⇧⌘T) brings them back."),
                           buttons: [(String(localized: "Save Now"), { [weak self, weak tab] in
                               tab?.noticeBar?.isHidden = true
                               self?.saveClosedTab(id)
                           })])
        }
    }

    /// Save Now: reopens the closed tab, saves it (through the ⌘S
    /// conflict check) and, if that wrote the file, closes it again.
    func saveClosedTab(_ id: UUID) {
        // Reopened already (⇧⌘T): save that tab.
        if let open = tabs.first(where: { $0.doc.id == id }) { _ = open.save(); return }
        guard let i = closedTabs.lastIndex(where: { $0.id == id }) else { NSSound.beep(); return }
        let entry = closedTabs.remove(at: i)
        closedTabs.append(entry)
        let before = tabs.count
        reopenClosedTab(nil)
        // Reopened as untitled (the file is open again in another tab): leave it for the user.
        guard tabs.count > before, let tab = tabs.last, tab.doc.id == id, tab.doc.fileURL != nil else { return }
        if tab.save() { tab.window?.performClose(nil) }
    }
}

