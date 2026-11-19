import AppKit
import CedricCore

/// Multiple carets and column selection (0.2.0): Edit › Selection › Add
/// Next Occurrence (⌘D), Select All Occurrences (⌃⌘G), Add Caret Above
/// (⌃⇧↑), Add Caret Below (⌃⇧↓) and Single Caret. The multi-caret editing
/// path lives here as an EditorTextView extension, so EditorTextView's own
/// diff stays small (plan-0.2.0.md §3). Phase 0 scaffolding: the menu
/// items exist and validate to disabled until the feature lands.
///
/// Single Caret carries no key equivalent on purpose: ⎋ stays the text
/// view's (complete:, the find bar), and the multi path takes it only
/// while there are 2 or more carets. Help › Keyboard Shortcuts lists ⎋,
/// ⌥-drag and ⌘-click from `MenuShortcuts.extraRows`.
extension AppDelegate {
    @objc func addNextOccurrenceMenu(_ sender: Any?) {}

    @objc func selectAllOccurrencesMenu(_ sender: Any?) {}

    @objc func addCaretAboveMenu(_ sender: Any?) {}

    @objc func addCaretBelowMenu(_ sender: Any?) {}

    @objc func singleCaretMenu(_ sender: Any?) {}

    func validateMultiCaretItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(addNextOccurrenceMenu(_:)), #selector(selectAllOccurrencesMenu(_:)),
             #selector(addCaretAboveMenu(_:)), #selector(addCaretBelowMenu(_:)), #selector(singleCaretMenu(_:)):
            return false
        default: return nil
        }
    }
}
