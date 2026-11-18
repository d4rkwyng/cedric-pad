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

    func stop() {
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

// MARK: - Menu actions

extension AppDelegate {
    @objc func markAllMenu(_ sender: Any?) { currentTab?.markAll() }
    @objc func clearMarksMenu(_ sender: Any?) { currentTab?.clearMarks() }
    @objc func toggleHighlightOccurrences(_ sender: Any?) { Settings.shared.highlightOccurrences.toggle() }

    /// Validation for the editing extras; nil: not one of ours.
    func validateEditingItem(_ item: NSMenuItem) -> Bool? {
        let tab = currentTab
        switch item.action {
        case #selector(markAllMenu(_:)): return tab != nil
        case #selector(clearMarksMenu(_:)): return tab?.hasMarks == true
        case #selector(toggleHighlightOccurrences(_:)):
            item.state = Settings.shared.highlightOccurrences ? .on : .off
            return true
        default: return nil
        }
    }
}
