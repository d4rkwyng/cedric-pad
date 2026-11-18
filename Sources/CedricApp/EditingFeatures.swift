import AppKit
import CedricCore

/// Per-tab state for the editing extras: highlight-all, Mark All,
/// bookmarks. Created with the tab but does nothing until used (no timers
/// or scans at launch).
@MainActor
final class EditingState {
    /// Debounces highlight-all after a selection change.
    var highlightTimer: Timer?
    /// Mark All's needle (nil: no marks) and its count in the whole text
    /// (nil when not counted: no marks, or a document too big to recount
    /// on every edit).
    var markNeedle: Occurrences.Needle?
    var markCount: Int?
    var markCountTimer: Timer?
    /// Bookmarked lines; follow edits (EditorWindowController.storageEdited).
    var bookmarks = Bookmarks()

    /// Status-bar counts: debounced for big ranges; the whole document's
    /// are cached until the text changes (any storage edit drops them).
    var countsTimer: Timer?
    var documentCounts: TextCounts??

    func stop() {
        countsTimer?.invalidate()
        countsTimer = nil
        highlightTimer?.invalidate()
        highlightTimer = nil
        markCountTimer?.invalidate()
        markCountTimer = nil
    }
}

// MARK: - Highlight all occurrences, Mark All

extension EditorWindowController {
    /// Mark counts are kept up to date while typing only below this size
    /// (UTF-16 units); a bigger document is counted when Mark All runs.
    static let markRecountLimit = 2_000_000

    /// After a selection change: highlight a moment later, so a burst of
    /// typing or caret moves costs one search of the visible text.
    func scheduleHighlights() {
        editing.highlightTimer?.invalidate()
        let t = Timer(timeInterval: 0.12, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshHighlights() }
        }
        RunLoop.main.add(t, forMode: .common)
        editing.highlightTimer = t
    }

    /// The text to search for highlights: the visible text and a margin,
    /// never the whole document.
    private var highlightRange: NSRange? {
        guard let vis = textView.visibleCharacterRange else { return nil }
        let len = (textView.string as NSString).length
        let start = max(0, vis.location - 2_000)
        return NSRange(location: start, length: min(len, NSMaxRange(vis) + 2_000) - start)
    }

    /// Recomputes the occurrence and mark ranges for the visible text.
    func refreshHighlights() {
        editing.highlightTimer?.invalidate()
        editing.highlightTimer = nil
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        var occ: [NSRange] = []
        var marks: [NSRange] = []
        if let range = highlightRange {
            if Settings.shared.highlightOccurrences, !textView.hasMarkedText(),
               let needle = Occurrences.needle(selection: sel, in: ns) {
                occ = Occurrences.find(needle, in: ns, range: range)
                // Only worth tinting if it occurs somewhere else too.
                if occ.count < 2 { occ = [] }
            }
            if let m = editing.markNeedle { marks = Occurrences.find(m, in: ns, range: range) }
        }
        if occ != textView.occurrenceRanges || marks != textView.markRanges {
            textView.occurrenceRanges = occ
            textView.markRanges = marks
            textView.needsDisplay = true
        }
    }

    /// Edit › Find › Mark All: marks every occurrence of the selection (or
    /// the word under the caret) until Clear Marks. Marks follow the text
    /// as it changes: only the needle is kept, and the visible text is
    /// searched again.
    func markAll() {
        let ns = textView.string as NSString
        guard let needle = Occurrences.needle(selection: textView.selectedRange(), in: ns) else { NSSound.beep(); return }
        editing.markNeedle = needle
        editing.markCount = Occurrences.count(needle, in: ns)
        refreshHighlights()
        updateStatus()
    }

    func clearMarks() {
        editing.markNeedle = nil
        editing.markCount = nil
        editing.markCountTimer?.invalidate()
        refreshHighlights()
        updateStatus()
    }

    var hasMarks: Bool { editing.markNeedle != nil }

    /// After an edit: recount the marks a moment later (small documents
    /// only), and highlight again.
    func editingTextChanged() {
        // The ranges are stale after an edit: drop them until the pause
        // (refreshHighlights) finds them again.
        if !textView.occurrenceRanges.isEmpty || !textView.markRanges.isEmpty {
            textView.occurrenceRanges = []
            textView.markRanges = []
            textView.needsDisplay = true
        }
        if let needle = editing.markNeedle {
            editing.markCountTimer?.invalidate()
            if (textView.string as NSString).length <= Self.markRecountLimit {
                let t = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.editing.markNeedle == needle else { return }
                        self.editing.markCount = Occurrences.count(needle, in: self.textView.string as NSString)
                        self.updateStatus()
                    }
                }
                RunLoop.main.add(t, forMode: .common)
                editing.markCountTimer = t
            } else {
                editing.markCount = nil
            }
        }
        scheduleHighlights()
    }
}

// MARK: - Matching bracket

extension EditorWindowController {
    /// Boxes the bracket next to the caret and its partner (a bounded
    /// scan: AutoEdit.matchingBracket), right away on every caret move.
    func updateBracketMatch() {
        let sel = textView.selectedRange()
        var ranges: [NSRange] = []
        if sel.length == 0, !textView.hasMarkedText(),
           let (a, b) = AutoEdit.matchingBracket(in: textView.string as NSString, caret: sel.location) {
            ranges = [a, b]
        }
        if ranges != textView.bracketRanges {
            textView.bracketRanges = ranges
            textView.needsDisplay = true
        }
    }
}

// MARK: - Word, line and character counts

extension EditorWindowController {
    /// Ranges up to this many units are counted at once; longer ones a
    /// moment after typing or selecting stops.
    static let immediateCountLimit = 50_000

    /// Updates the status bar's counts: of the selection if there is one,
    /// else of the document. Past `TextStats.maxCounted` units only lines
    /// are shown (from the line index, no scan).
    func scheduleCounts() {
        editing.countsTimer?.invalidate()
        editing.countsTimer = nil
        let sel = textView.selectedRange()
        let length = sel.length > 0 ? sel.length : lineIndex.length
        let cached = sel.length == 0 && editing.documentCounts != nil
        if cached || length <= Self.immediateCountLimit || length > TextStats.maxCounted {
            updateCounts()
            return
        }
        let t = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCounts() }
        }
        RunLoop.main.add(t, forMode: .common)
        editing.countsTimer = t
    }

    func updateCounts() {
        editing.countsTimer = nil
        let sel = textView.selectedRange()
        let ns = textView.string as NSString
        func plural(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n.formatted()) \(many)" }
        let words = String(localized: "word"), wordsP = String(localized: "words")
        let line = String(localized: "line"), lines = String(localized: "lines")
        let char = String(localized: "character"), chars = String(localized: "characters")
        var s: String
        if sel.length > 0 {
            if let c = TextStats.count(ns, range: sel) {
                s = [plural(c.words, words, wordsP), plural(c.lines, line, lines), plural(c.characters, char, chars)].joined(separator: " · ")
            } else {
                let a = lineIndex.line(containing: sel.location), b = lineIndex.line(containing: max(sel.location, NSMaxRange(sel) - 1))
                s = plural(b - a + 1, line, lines)
            }
            s = String(localized: "Selected: \(s)")
        } else {
            let counts: TextCounts?
            if let cached = editing.documentCounts {
                counts = cached
            } else {
                counts = TextStats.count(ns, range: NSRange(location: 0, length: ns.length))
                editing.documentCounts = .some(counts)
            }
            if let c = counts {
                s = [plural(c.words, words, wordsP), plural(c.lines, line, lines), plural(c.characters, char, chars)].joined(separator: " · ")
            } else {
                // As TextStats counts: an empty last line (after a final newline) isn't one.
                let n = lineIndex.lineCount - (lineIndex.lineCount > 1 && lineIndex.lineLength(lineIndex.lineCount - 1) == 0 ? 1 : 0)
                s = plural(n, line, lines)
            }
        }
        statusBar.counts.stringValue = s
    }
}

// MARK: - Line operations

/// Edit › Line: what to do to the selected lines.
enum LineCommand {
    case duplicate, moveUp, moveDown, delete, toggleComment

    var actionName: String {
        switch self {
        case .duplicate: return String(localized: "Duplicate Line")
        case .moveUp: return String(localized: "Move Line Up")
        case .moveDown: return String(localized: "Move Line Down")
        case .delete: return String(localized: "Delete Line")
        case .toggleComment: return String(localized: "Toggle Comment")
        }
    }
}

extension EditorWindowController {
    /// Applies one line command to the selection as one undo step; beeps
    /// when there's nothing to do (top line up, no comments in JSON…).
    func perform(_ command: LineCommand) {
        guard textView.isEditable, !textView.hasMarkedText() else { NSSound.beep(); return }
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        let edit: TextEdit?
        switch command {
        case .duplicate: edit = LineOperations.duplicate(sel, in: ns)
        case .moveUp: edit = LineOperations.moveUp(sel, in: ns)
        case .moveDown: edit = LineOperations.moveDown(sel, in: ns)
        case .delete: edit = LineOperations.deleteLines(sel, in: ns)
        case .toggleComment: edit = LineOperations.toggleComment(sel, in: ns, syntax: doc.language.commentSyntax)
        }
        guard let edit else { NSSound.beep(); return }
        // A moved line takes its bookmark along.
        let before = editing.bookmarks
        let block = LineOperations.lineBlock(sel, in: ns)
        let firstLine = lineIndex.line(containing: block.location)
        let lastLine = block.length == 0 ? firstLine : lineIndex.line(containing: NSMaxRange(block) - 1)
        apply(edit, actionName: command.actionName)
        if command == .moveUp || command == .moveDown, !before.isEmpty {
            var moved = before
            moved.moveLines(firstLine..<(lastLine + 1), by: command == .moveUp ? -1 : 1)
            editing.bookmarks = moved
            gutter.needsDisplay = true
        }
    }

    /// One `TextEdit` as one undoable change, inserted in the theme's text
    /// colour (the highlighter recolours it), then its selection.
    func apply(_ edit: TextEdit, actionName: String) {
        guard let storage = textView.textStorage else { return }
        let um = textView.undoManager
        textView.breakUndoCoalescing()
        um?.beginUndoGrouping()
        if textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) {
            storage.beginEditing()
            storage.replaceCharacters(in: edit.range, with: NSAttributedString(string: edit.replacement, attributes: baseAttributes()))
            storage.endEditing()
            textView.didChangeText()
        }
        um?.endUndoGrouping()
        um?.setActionName(actionName)
        let len = (textView.string as NSString).length
        let s = NSRange(location: min(edit.selection.location, len), length: min(edit.selection.length, len - min(edit.selection.location, len)))
        textView.setSelectedRange(s)
        textView.scrollRangeToVisible(s)
        colorizer.scheduleViewport()
    }

    /// ⌘X with nothing selected: cuts the caret's line (with its newline).
    func cutLine() {
        guard textView.isEditable else { NSSound.beep(); return }
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        let block = LineOperations.lineBlock(sel, in: ns)
        var line = ns.substring(with: block)
        if !line.hasSuffix("\n") { line += "\n" }
        guard !(block.length == 0 && ns.length == 0) else { NSSound.beep(); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(line, forType: .string)
        apply(LineOperations.deleteLines(sel, in: ns), actionName: String(localized: "Cut Line"))
    }
}

// MARK: - Bookmarks

extension EditorWindowController {
    var caretLine: Int { lineIndex.line(containing: textView.selectedRange().location) }

    func toggleBookmark(line: Int? = nil) {
        editing.bookmarks.toggle(line ?? caretLine)
        bookmarksChanged()
    }

    func goToBookmark(next: Bool) {
        let b = editing.bookmarks
        guard let line = next ? b.next(after: caretLine) : b.previous(before: caretLine) else { NSSound.beep(); return }
        goToLine(line + 1)
    }

    func clearBookmarks() {
        editing.bookmarks.removeAll()
        bookmarksChanged()
    }

    /// Bookmarks every line with a match: the find bar's search when it is
    /// open and has one, else the selection or the word under the caret.
    /// Returns how many lines were bookmarked.
    @discardableResult
    func bookmarkAllMatches() -> Int {
        let ns = textView.string as NSString
        var ranges: [NSRange] = []
        if isFindBarOpen, !findBar.findField.stringValue.isEmpty,
           let re = try? FindEngine.regex(findBar.findField.stringValue, findBar.options) {
            ranges = FindEngine.matches(re, in: ns).map(\.range)
        } else if let needle = Occurrences.needle(selection: textView.selectedRange(), in: ns) {
            ranges = Occurrences.findAll(needle, in: ns)
        }
        guard !ranges.isEmpty else { NSSound.beep(); return 0 }
        let lines = Set(ranges.map { lineIndex.line(containing: $0.location) })
        editing.bookmarks.insert(contentsOf: lines)
        bookmarksChanged()
        return lines.count
    }

    private func bookmarksChanged() {
        gutter.needsDisplay = true
        onChange?(self) // saved with the session
    }
}

// MARK: - Menu actions

extension AppDelegate {
    @objc func markAllMenu(_ sender: Any?) { currentTab?.markAll() }
    @objc func clearMarksMenu(_ sender: Any?) { currentTab?.clearMarks() }
    @objc func toggleHighlightOccurrences(_ sender: Any?) { Settings.shared.highlightOccurrences.toggle() }
    @objc func toggleAutoCloseBrackets(_ sender: Any?) { Settings.shared.autoCloseBrackets.toggle() }
    @objc func duplicateLineMenu(_ sender: Any?) { currentTab?.perform(.duplicate) }
    @objc func moveLineUpMenu(_ sender: Any?) { currentTab?.perform(.moveUp) }
    @objc func moveLineDownMenu(_ sender: Any?) { currentTab?.perform(.moveDown) }
    @objc func deleteLineMenu(_ sender: Any?) { currentTab?.perform(.delete) }
    @objc func toggleCommentMenu(_ sender: Any?) { currentTab?.perform(.toggleComment) }
    @objc func toggleBookmarkMenu(_ sender: Any?) { currentTab?.toggleBookmark() }
    @objc func nextBookmarkMenu(_ sender: Any?) { currentTab?.goToBookmark(next: true) }
    @objc func previousBookmarkMenu(_ sender: Any?) { currentTab?.goToBookmark(next: false) }
    @objc func bookmarkAllMatchesMenu(_ sender: Any?) { currentTab?.bookmarkAllMatches() }
    @objc func clearBookmarksMenu(_ sender: Any?) { currentTab?.clearBookmarks() }

    /// Validation for the editing extras; nil: not one of ours.
    func validateEditingItem(_ item: NSMenuItem) -> Bool? {
        let tab = currentTab
        switch item.action {
        case #selector(markAllMenu(_:)): return tab != nil
        case #selector(clearMarksMenu(_:)): return tab?.hasMarks == true
        case #selector(duplicateLineMenu(_:)), #selector(moveLineUpMenu(_:)), #selector(moveLineDownMenu(_:)),
             #selector(deleteLineMenu(_:)):
            return tab?.textView.isEditable == true
        case #selector(toggleBookmarkMenu(_:)), #selector(bookmarkAllMatchesMenu(_:)): return tab != nil
        case #selector(nextBookmarkMenu(_:)), #selector(previousBookmarkMenu(_:)), #selector(clearBookmarksMenu(_:)):
            return tab?.editing.bookmarks.isEmpty == false
        case #selector(toggleCommentMenu(_:)):
            return tab?.textView.isEditable == true && tab?.doc.language.commentSyntax != nil
        case #selector(toggleAutoCloseBrackets(_:)):
            item.state = Settings.shared.autoCloseBrackets ? .on : .off
            return true
        case #selector(toggleHighlightOccurrences(_:)):
            item.state = Settings.shared.highlightOccurrences ? .on : .off
            return true
        default: return nil
        }
    }
}
