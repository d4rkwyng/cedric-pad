import AppKit
import CedricCore

/// Replace in Files (0.2.0): Edit › Replace in Files… (⌥⇧⌘F) opens the
/// Find in Files panel in replace mode; Edit › Undo Replace in Files puts
/// back the last operation's files. Phase 0 scaffolding: the menu items
/// exist and validate to disabled until the feature lands
/// (plan-0.2.0.md §2).
extension AppDelegate {
    @objc func replaceInFilesMenu(_ sender: Any?) {}

    @objc func undoReplaceInFilesMenu(_ sender: Any?) {}

    func validateReplaceInFilesItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(replaceInFilesMenu(_:)), #selector(undoReplaceInFilesMenu(_:)): return false
        default: return nil
        }
    }
}
