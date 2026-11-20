import AppKit
import CedricCore

// Code folding (View › Folding). Regions come from FoldScanner (CedricCore),
// on demand: nothing is computed for a document nobody folds, except the
// gutter's triangles for the visible lines while the pointer is over the
// gutter. A tab's FoldingController is made on its first fold; until then
// every hook below is a nil check.
//
// Hiding: the controller becomes the content storage's delegate and
// answers `shouldEnumerate` false for paragraphs in a folded range, so
// TextKit 2 neither lays them out nor numbers them (the gutter enumerates
// layout fragments). The text storage never changes: save, undo, copy,
// find and print see the whole text. Once nothing is folded the delegate
// is removed again.

/// What the gutter shows on a line's fold column.
enum FoldMark { case none, open, folded }

@MainActor
final class FoldingController: NSObject, NSTextContentStorageDelegate {
    private weak var tab: EditorWindowController?
    private(set) var state = FoldState()
    /// A copy for the layout callback (TextKit calls it on the main thread,
    /// but the protocol isn't main-actor isolated).
    nonisolated(unsafe) private var hiddenForLayout = FoldState()

    init(tab: EditorWindowController) {
        self.tab = tab
    }

    var isEmpty: Bool { state.isEmpty }

    nonisolated func textContentManager(_ textContentManager: NSTextContentManager, shouldEnumerate textElement: NSTextElement,
                                        options: NSTextContentManager.EnumerationOptions) -> Bool {
        guard let r = textElement.elementRange, !hiddenForLayout.isEmpty else { return true }
        let o = textContentManager.offset(from: textContentManager.documentRange.location, to: r.location)
        return !hiddenForLayout.isHidden(o)
    }

    // MARK: Folding and unfolding

    /// The characters a region hides: from the start of the line after its
    /// header to the end of its last line (newline included).
    func range(of r: FoldRegion, index: LineIndex) -> NSRange? {
        guard r.header + 1 < index.lineCount, r.last < index.lineCount, r.last > r.header else { return nil }
        let start = index.starts[r.header + 1]
        let end = r.last + 1 < index.lineCount ? index.starts[r.last + 1] : index.length
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    func fold(_ regions: [FoldRegion]) {
        guard let tab else { return }
        let index = tab.lineIndex
        var changed: Int?
        for r in regions {
            guard let rr = range(of: r, index: index), !state.folds.contains(rr) else { continue }
            state.add(rr)
            changed = min(changed ?? rr.location, rr.location)
        }
        if let changed { apply(from: changed) }
    }

    func unfold(_ ranges: [NSRange]) {
        guard !ranges.isEmpty else { return }
        var from = Int.max
        for r in ranges where state.folds.contains(r) {
            state.remove(r)
            from = min(from, r.location)
        }
        if from != .max { apply(from: from) }
    }

    func unfoldAll() {
        guard let first = state.folds.first?.location else { return }
        state.removeAll()
        apply(from: first)
    }

    /// The text was replaced (open, reload): folds are gone, without a relayout.
    func reset() {
        state.removeAll()
        hiddenForLayout = state
        tab?.textView.contentStorage?.delegate = nil
    }

    /// After the fold state changed: TextKit lays out again from `from`
    /// to the end (fragments below a changed fold move), and a caret
    /// that is now hidden goes to the end of its header line.
    private func apply(from: Int) {
        guard let tab, let cs = tab.primaryTextView.contentStorage else { return }
        hiddenForLayout = state
        cs.delegate = state.isEmpty ? nil : self
        let start = max(0, min(from - 1, tab.lineIndex.length))
        // Every pane: the folds are the content storage's, so a split
        // tab's two panes hide the same lines.
        for pane in tab.panes {
            let tv = pane.textView
            guard let tlm = tv.textLayoutManager else { continue }
            if let s = cs.location(cs.documentRange.location, offsetBy: start), let r = NSTextRange(location: s, end: cs.documentRange.endLocation) {
                tlm.invalidateLayout(for: r)
            }
            let sel = tv.selectedRange()
            let ns = tv.string as NSString
            let len = ns.length
            let nl = len > 0 && ns.character(at: len - 1) == 10
            if !state.isEmpty, let h = state.caretIsHidden(sel.location, length: len, endsWithNewline: nl) {
                tv.setSelectedRange(NSRange(location: max(0, h.location - 1), length: 0))
            }
            tlm.textViewportLayoutController.layoutViewport()
            tv.needsDisplay = true
            pane.gutter.needsDisplay = true
        }
        tab.foldsChanged()
    }

    // MARK: Following the text

    /// Every character edit (storageEdited): folds before it shift, a fold
    /// it touches opens.
    func textEdited(oldRange: NSRange, newLength: Int, storage: NSTextStorage) {
        guard !state.isEmpty else { return }
        let ns = storage.string as NSString
        let inserted = NSRange(location: oldRange.location, length: newLength)
        let newline = newLength > 0 && ns.rangeOfCharacter(from: .newlines, options: [], range: inserted).location != NSNotFound
        let oldLength = ns.length - newLength + oldRange.length
        let before = state.folds.first?.location ?? 0
        let opened = state.adjust(oldRange: oldRange, newLength: newLength, insertsNewline: newline, oldLength: oldLength)
        hiddenForLayout = state
        guard opened else { return }
        // TextKit is in the middle of the edit: lay out again after it.
        let from = min(before, oldRange.location)
        DispatchQueue.main.async { [weak self] in self?.apply(from: from) }
    }

    /// The text view is about to change its selection. A key move (arrows,
    /// word and page moves) skips past hidden text in the direction it
    /// went; anything else (find, go to line, bookmarks, the outline, a
    /// click) that lands in hidden text opens the folds it lands in.
    func selectionWillChange(from old: [NSValue], to new: [NSValue], byKey: Bool) -> [NSValue] {
        guard !state.isEmpty, let tv = tab?.textView else { return new }
        let ns = tv.string as NSString
        let len = ns.length
        let nl = len > 0 && ns.character(at: len - 1) == 10
        if byKey {
            let o = old.first?.rangeValue ?? NSRange(location: 0, length: 0)
            return new.map { v in
                let r = v.rangeValue
                if r.length == 0 {
                    let p = state.navigationTarget(r.location, from: o.location + (o.length > 0 && r.location >= NSMaxRange(o) ? o.length : 0),
                                                   length: len, endsWithNewline: nl)
                    return NSValue(range: NSRange(location: p, length: 0))
                }
                // A selection extended by keys: each end skips as a caret would.
                let s = state.navigationTarget(r.location, from: o.location, length: len, endsWithNewline: nl)
                let e = state.navigationTarget(NSMaxRange(r), from: NSMaxRange(o), length: len, endsWithNewline: nl)
                return NSValue(range: NSRange(location: min(s, e), length: abs(e - s)))
            }
        }
        var open: [NSRange] = []
        for v in new {
            for f in state.foldsToOpen(for: v.rangeValue, length: len, endsWithNewline: nl) where !open.contains(f) { open.append(f) }
        }
        unfold(open)
        return new
    }

    /// Opens the folds holding any of `range`'s ends (reveal, multiple carets).
    func reveal(_ range: NSRange) {
        guard !state.isEmpty, let tv = tab?.textView else { return }
        let ns = tv.string as NSString
        let len = ns.length
        let nl = len > 0 && ns.character(at: len - 1) == 10
        unfold(state.foldsToOpen(for: range, length: len, endsWithNewline: nl))
    }

    /// Multiple carets changed: one in hidden text opens its fold (on the
    /// next turn: the caret layer is mid-update).
    func carets(_ carets: [MultiCaret.Caret]) {
        guard !state.isEmpty, let tv = tab?.textView else { return }
        let ns = tv.string as NSString
        let len = ns.length
        let nl = len > 0 && ns.character(at: len - 1) == 10
        let ranges = carets.map(\.range).filter { !state.foldsToOpen(for: $0, length: len, endsWithNewline: nl).isEmpty }
        guard !ranges.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in ranges.forEach { self?.reveal($0) } }
    }

    // MARK: Lines

    /// Header line of each fold (the line before its hidden text).
    func headerLines(_ index: LineIndex) -> [Int] {
        var out: [Int] = []
        for f in state.folds where f.location > 0 {
            let l = index.line(containing: f.location - 1)
            if out.last != l { out.append(l) }
        }
        return out
    }

    /// The folds whose header is `line`.
    func folds(header line: Int, _ index: LineIndex) -> [NSRange] {
        state.folds.filter { $0.location > 0 && index.line(containing: $0.location - 1) == line }
    }

    /// The pill's label for a hidden range: "⋯ 42 lines".
    func label(for hidden: NSRange, _ index: LineIndex) -> String {
        let a = index.line(containing: hidden.location)
        let b = index.line(containing: max(hidden.location, NSMaxRange(hidden) - 1))
        let n = b - a + 1
        return n == 1 ? String(localized: "⋯ 1 line") : String(localized: "⋯ \(n) lines")
    }
}

// MARK: - The tab

extension EditorWindowController {
    /// Folding applies: a language that folds, outside large mode, not a held binary file.
    var foldingAvailable: Bool {
        doc.language.foldKind != .none && !isLargeDocument && largePending == false && binary == nil
    }

    func foldScanner() -> FoldScanner? {
        guard foldingAvailable, let storage = textView.textStorage else { return nil }
        let text = storage.string as NSString
        let index = lineIndex
        guard index.length == text.length else { return nil }
        let fences = self.fences
        return FoldScanner(language: doc.language, text: text, index: index, engine: colorizer.engine,
                           inFence: doc.language == .markdown ? { fences.isInFence(text, index: index, line: $0) } : nil,
                           tabWidth: indentation.width)
    }

    /// The tab's controller, made on the first fold.
    func makeFolding() -> FoldingController {
        if let f = folding { return f }
        let f = FoldingController(tab: self)
        folding = f
        panes.forEach { $0.textView.folding = f }
        return f
    }

    var caretLineForFolding: Int { lineIndex.line(containing: textView.selectedRange().location) }

    /// The fold column's mark for each line (the gutter, while drawing).
    func foldMarks(hovering: Bool) -> ((Int) -> FoldMark)? {
        guard foldingAvailable else { return nil }
        let folded = Set(folding?.headerLines(lineIndex) ?? [])
        let scanner = hovering ? foldScanner() : nil
        if folded.isEmpty && scanner == nil { return nil }
        return { line in
            if folded.contains(line) { return .folded }
            return scanner?.startsRegion(line) == true ? .open : .none
        }
    }

    /// A click in the gutter's fold column; false when nothing folds on that line.
    @discardableResult
    func toggleFold(line: Int) -> Bool {
        guard foldingAvailable else { return false }
        if let f = folding, case let mine = f.folds(header: line, lineIndex), !mine.isEmpty {
            f.unfold(mine)
            return true
        }
        guard let r = foldScanner()?.region(at: line) else { return false }
        makeFolding().fold([r])
        return true
    }

    /// View › Folding › Fold: the region the caret's line starts, else the
    /// innermost one around the caret not yet folded.
    func foldAtCaret() {
        guard let scanner = foldScanner() else { NSSound.beep(); return }
        let index = lineIndex
        let folded = Set(folding?.state.folds ?? [])
        let f = makeFolding()
        guard let r = scanner.enclosingRegion(of: caretLineForFolding, excluding: { f.range(of: $0, index: index).map(folded.contains) ?? true }) else {
            if folding?.isEmpty == true { dropFoldingIfEmpty() }
            NSSound.beep()
            return
        }
        f.fold([r])
    }

    /// View › Folding › Unfold: the folds on the caret's line.
    func unfoldAtCaret() {
        guard let f = folding else { NSSound.beep(); return }
        let mine = f.folds(header: caretLineForFolding, lineIndex)
        if mine.isEmpty { NSSound.beep(); return }
        f.unfold(mine)
    }

    /// Fold All; with `level`, Fold to Level N: the regions at depth N and
    /// deeper fold, the ones above them open.
    func foldAll(level: Int = 1) {
        guard let scanner = foldScanner() else { NSSound.beep(); return }
        let t0 = DispatchTime.now()
        let regions = scanner.allRegions().filter { $0.depth >= level }
        let f = makeFolding()
        f.unfoldAll()
        f.fold(regions)
        if f.isEmpty { dropFoldingIfEmpty() }
        lastFoldAllMs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
    }

    func unfoldAll() {
        folding?.unfoldAll()
    }

    private func dropFoldingIfEmpty() {
        guard let f = folding, f.isEmpty else { return }
        textView.contentStorage?.delegate = nil
        folding = nil
        panes.forEach { $0.textView.folding = nil }
    }

    /// The fold state changed (FoldingController.apply).
    func foldsChanged() {
        onChange?(self)
    }

    /// For the session: the folded regions' header lines.
    var sessionFolds: [Int]? {
        guard let f = folding, !f.isEmpty else { return nil }
        return f.headerLines(lineIndex)
    }

    /// Folds from the session, after the first frame.
    func restoreFolds(_ headers: [Int]) {
        guard !headers.isEmpty else { return }
        AfterFirstFrame.run { [weak self] in
            guard let self, let scanner = self.foldScanner() else { return }
            let regions = headers.filter { $0 >= 0 && $0 < self.lineIndex.lineCount }.compactMap { scanner.region(at: $0) }
            guard !regions.isEmpty else { return }
            self.makeFolding().fold(regions)
        }
    }

    /// A hidden line's header (scrolling to a line never opens a fold).
    func visibleLine(_ line: Int) -> Int {
        guard let f = folding, !f.isEmpty, line < lineIndex.lineCount,
              let h = f.state.hiddenRange(containing: lineIndex.starts[line]), h.location > 0 else { return line }
        return lineIndex.line(containing: h.location - 1)
    }

    /// Language or large mode changed: the old regions don't apply.
    func foldingContextChanged() {
        guard let f = folding else { return }
        f.unfoldAll()
        dropFoldingIfEmpty()
    }
}

// MARK: - The menu

extension AppDelegate {
    @objc func foldMenu(_ sender: Any?) { currentTab?.foldAtCaret() }
    @objc func unfoldMenu(_ sender: Any?) { currentTab?.unfoldAtCaret() }
    @objc func foldAllMenu(_ sender: Any?) { currentTab?.foldAll() }
    @objc func unfoldAllMenu(_ sender: Any?) { currentTab?.unfoldAll() }
    @objc func foldToLevelMenu(_ sender: Any?) {
        guard let level = (sender as? NSMenuItem)?.representedObject as? Int else { return }
        currentTab?.foldAll(level: level)
    }

    func validateFoldingItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(foldMenu(_:)), #selector(foldAllMenu(_:)), #selector(foldToLevelMenu(_:)):
            return currentTab?.foldingAvailable == true
        case #selector(unfoldMenu(_:)), #selector(unfoldAllMenu(_:)):
            return currentTab?.foldingAvailable == true && currentTab?.folding?.isEmpty == false
        default: return nil
        }
    }
}

/// View › Folding.
@MainActor
func foldingMenu() -> NSMenuItem {
    let left = String(UnicodeScalar(UInt16(NSLeftArrowFunctionKey))!)
    let right = String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!)
    return submenu(String(localized: "Folding"), [
        item(String(localized: "Fold"), #selector(AppDelegate.foldMenu(_:)), left, [.command, .option]),
        item(String(localized: "Unfold"), #selector(AppDelegate.unfoldMenu(_:)), right, [.command, .option]),
        item(String(localized: "Fold All"), #selector(AppDelegate.foldAllMenu(_:)), left, [.command, .option, .shift]),
        item(String(localized: "Unfold All"), #selector(AppDelegate.unfoldAllMenu(_:)), right, [.command, .option, .shift]),
        .separator(),
    ] + (1...3).map { (level: Int) in
        // Typed: Swift 6.1 can't pick an appendInterpolation for an untyped range literal's $0.
        item(String(localized: "Fold to Level \(level)"), #selector(AppDelegate.foldToLevelMenu(_:)), represented: level)
    })
}
