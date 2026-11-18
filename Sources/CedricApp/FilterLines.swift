import AppKit
import CedricCore

// Edit › Line › Keep / Delete Lines Matching… and Edit › Bookmarks › Copy
// / Delete Bookmarked Lines (LineFilter in CedricCore). Each is one undo
// step; bookmarks on lines that stay follow them.

extension EditorWindowController {
    /// Keeps (or deletes) the lines matching. Returns how many lines went,
    /// or nil after a beep (nothing matched / nothing to remove) or an alert.
    @discardableResult
    func filterLines(pattern: String, regex: Bool, caseSensitive: Bool, keepMatching: Bool) -> Int? {
        guard textView.isEditable else { NSSound.beep(); return nil }
        let ns = textView.string as NSString
        do {
            guard let r = try LineFilter.filter(ns, pattern: pattern, regex: regex, caseSensitive: caseSensitive,
                                                keepMatching: keepMatching) else { NSSound.beep(); return nil }
            removeLines(r, actionName: keepMatching ? String(localized: "Keep Lines Matching") : String(localized: "Delete Lines Matching"))
            return r.removed.count
        } catch {
            let a = NSAlert()
            a.messageText = String(localized: "That isn’t a valid regular expression.")
            a.informativeText = pattern
            if let window { a.beginSheetModal(for: window) } else { a.runModal() }
            return nil
        }
    }

    private func removeLines(_ r: (edit: TextEdit, removed: [Int]), actionName: String) {
        let marks = editing.bookmarks.lines.compactMap { LineFilter.renumber($0, removed: r.removed) }
        apply(r.edit, actionName: actionName, bookmarks: Bookmarks(marks))
        onChange?(self)
    }

    /// Copies the bookmarked lines (in order) to the clipboard.
    func copyBookmarkedLines() {
        guard !editing.bookmarks.isEmpty else { NSSound.beep(); return }
        let s = LineFilter.copying(lines: editing.bookmarks.lines, in: textView.string as NSString)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    func deleteBookmarkedLines() {
        guard textView.isEditable, !editing.bookmarks.isEmpty else { NSSound.beep(); return }
        let marks = Set(editing.bookmarks.lines)
        guard let r = LineFilter.removing(in: textView.string as NSString, where: { line, _ in marks.contains(line) }) else { NSSound.beep(); return }
        removeLines(r, actionName: String(localized: "Delete Bookmarked Lines"))
    }

    /// The prompt for Keep / Delete Lines Matching: the text, "Regular
    /// expression" and "Match case" (both remembered), filled with the
    /// find bar's search or the selection.
    func filterLinesPrompt(keepMatching: Bool) {
        guard let window else { return }
        let d = UserDefaults.standard
        let a = NSAlert()
        a.messageText = keepMatching ? String(localized: "Keep Lines Matching") : String(localized: "Delete Lines Matching")
        a.informativeText = keepMatching ? String(localized: "Every line that doesn’t contain this is deleted.")
                                         : String(localized: "Every line that contains this is deleted.")
        let field = NSTextField(frame: NSRect(x: 0, y: 46, width: 280, height: 24))
        field.placeholderString = String(localized: "Text or pattern")
        let sel = textView.selectedRange()
        if sel.length > 0, sel.length < 200, (textView.string as NSString).rangeOfCharacter(from: .newlines, options: [], range: sel).location == NSNotFound {
            field.stringValue = (textView.string as NSString).substring(with: sel)
        } else if isFindBarOpen {
            field.stringValue = findBar.findField.stringValue
        } else {
            field.stringValue = d.string(forKey: "filterLinesPattern") ?? ""
        }
        let regex = NSButton(checkboxWithTitle: String(localized: "Regular expression"), target: nil, action: nil)
        regex.frame = NSRect(x: 0, y: 22, width: 280, height: 18)
        regex.state = d.bool(forKey: "filterLinesRegex") ? .on : .off
        let matchCase = NSButton(checkboxWithTitle: String(localized: "Match case"), target: nil, action: nil)
        matchCase.frame = NSRect(x: 0, y: 0, width: 280, height: 18)
        matchCase.state = d.bool(forKey: "filterLinesMatchCase") ? .on : .off
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 70))
        [field, regex, matchCase].forEach(box.addSubview)
        a.accessoryView = box
        a.addButton(withTitle: keepMatching ? String(localized: "Keep") : String(localized: "Delete"))
        a.addButton(withTitle: String(localized: "Cancel"))
        a.window.initialFirstResponder = field
        a.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .alertFirstButtonReturn, let self else { return }
            d.set(field.stringValue, forKey: "filterLinesPattern")
            d.set(regex.state == .on, forKey: "filterLinesRegex")
            d.set(matchCase.state == .on, forKey: "filterLinesMatchCase")
            self.filterLines(pattern: field.stringValue, regex: regex.state == .on, caseSensitive: matchCase.state == .on,
                             keepMatching: keepMatching)
            self.window?.makeFirstResponder(self.textView)
        }
    }
}

extension AppDelegate {
    @objc func keepLinesMatchingMenu(_ sender: Any?) { currentTab?.filterLinesPrompt(keepMatching: true) }
    @objc func deleteLinesMatchingMenu(_ sender: Any?) { currentTab?.filterLinesPrompt(keepMatching: false) }
    @objc func copyBookmarkedLinesMenu(_ sender: Any?) { currentTab?.copyBookmarkedLines() }
    @objc func deleteBookmarkedLinesMenu(_ sender: Any?) { currentTab?.deleteBookmarkedLines() }

    func validateFilterItem(_ item: NSMenuItem) -> Bool? {
        let tab = currentTab
        switch item.action {
        case #selector(keepLinesMatchingMenu(_:)), #selector(deleteLinesMatchingMenu(_:)):
            return tab?.textView.isEditable == true
        case #selector(copyBookmarkedLinesMenu(_:)): return tab?.editing.bookmarks.isEmpty == false
        case #selector(deleteBookmarkedLinesMenu(_:)): return tab?.textView.isEditable == true && tab?.editing.bookmarks.isEmpty == false
        default: return nil
        }
    }
}
