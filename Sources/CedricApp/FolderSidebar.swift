import AppKit
import CedricCore

/// The folder sidebar (0.2.0): File › Open Folder… (⇧⌘O) and View › Show
/// Folder Sidebar (⌃⌘1). One app-wide sidebar, docked at the left of the
/// selected tab's split (plan-0.2.0.md §6). Phase 0 scaffolding: the menu
/// items exist and validate to disabled until the feature lands; nothing
/// is built until a folder is opened.
extension AppDelegate {
    @objc func openFolderMenu(_ sender: Any?) {}

    @objc func toggleFolderSidebarMenu(_ sender: Any?) {}

    func validateFolderItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(openFolderMenu(_:)): return false
        case #selector(toggleFolderSidebarMenu(_:)):
            item.state = .off
            return false
        default: return nil
        }
    }
}
