import AppKit
import CedricCore

/// Multiple carets and column selection (0.2.0): Text › Selection › Add
/// Next Occurrence (⌘D), Select All Occurrences (⌃⌘G), Add Caret Above
/// (⌃⇧↑), Add Caret Below (⌃⇧↓) and Single Caret; ⌥-drag for a column,
/// ⌘-click to add or remove a caret, ⎋ back to one caret.
///
/// NSTextView's own multi-range editing isn't used: on TextKit 2 it drops
/// empty ranges, types only into the first range, and its multi-range undo
/// restored the wrong text (plan-0.2.0.md §0). So the editor keeps its own
/// caret list (`EditorTextView.multiCarets`, nil with one caret) and
/// applies every edit itself: worked out per caret by `MultiCaret` and
/// `AutoEdit`, applied from the last caret to the first, each as its own
/// storage edit, in one undo group that also restores the carets.
///
/// Single Caret carries no key equivalent on purpose: ⎋ stays the text
/// view's (complete:, the find bar), and the multi path takes it only
/// while there are 2 or more carets. Help › Keyboard Shortcuts lists ⎋,
/// ⌥-drag and ⌘-click from `MenuShortcuts.extraRows`.
extension AppDelegate {
    @objc func addNextOccurrenceMenu(_ sender: Any?) { currentTab?.textView.addNextOccurrence() }

    @objc func selectAllOccurrencesMenu(_ sender: Any?) { currentTab?.textView.selectAllOccurrences() }

    @objc func addCaretAboveMenu(_ sender: Any?) { currentTab?.textView.addCaret(below: false) }

    @objc func addCaretBelowMenu(_ sender: Any?) { currentTab?.textView.addCaret(below: true) }

    @objc func singleCaretMenu(_ sender: Any?) { currentTab?.textView.collapseToPrimary() }

    func validateMultiCaretItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(addNextOccurrenceMenu(_:)), #selector(selectAllOccurrencesMenu(_:)),
             #selector(addCaretAboveMenu(_:)), #selector(addCaretBelowMenu(_:)):
            guard let tv = currentTab?.textView else { return false }
            return tv.window?.firstResponder === tv && !tv.hasMarkedText()
        case #selector(singleCaretMenu(_:)):
            return currentTab?.textView.multiCarets != nil
        default: return nil
        }
    }
}

extension EditorWindowController {
    /// "N carets" in place of Ln/Col while there are several.
    func showMultiCaretStatus() {
        if let n = textView.multiCarets?.count {
            statusBar.position.stringValue = String(localized: "\(n) carets")
        } else {
            updateStatus()
        }
    }
}

extension EditorTextView {
    typealias Caret = MultiCaret.Caret

    private var tab: EditorWindowController? { delegate as? EditorWindowController }

    /// Every caret and the primary's index (one caret: the selection).
    var allCarets: (carets: [Caret], primary: Int) {
        if let m = multiCarets { return (m, multiPrimary) }
        return ([Caret(selectedRange())], 0)
    }

    private var caretCap: Int { tab?.isLargeDocument == true ? MultiCaret.maxCaretsLarge : MultiCaret.maxCarets }

    private var tabWidth: Int { indentation?().width ?? 4 }

    private var lines: LineIndex { tab?.lineIndex ?? LineIndex(string as NSString) }

    // MARK: Setting the carets

    /// Sets the carets (normalised; one caret leaves multi-caret mode) and
    /// makes the primary NSTextView's selection.
    func setCarets(_ carets: [Caret], primary: Int, reveal: Bool = true) {
        guard !carets.isEmpty else { return }
        var (list, p) = MultiCaret.normalize(carets, primary: min(primary, carets.count - 1))
        if list.count > caretCap {
            list = Array(list.prefix(caretCap))
            p = min(p, list.count - 1)
            NSSound.beep()
        }
        let primaryRange = list[p].range
        if list.count == 1 {
            let wasMulti = multiCarets != nil
            multiCarets = nil
            multiPrimary = 0
            multiOwnsSelection = true
            setSelectedRange(primaryRange)
            multiOwnsSelection = false
            if wasMulti { needsDisplay = true; tab?.showMultiCaretStatus() }
        } else {
            multiCarets = list
            multiPrimary = p
            multiOwnsSelection = true
            setSelectedRange(primaryRange)
            multiOwnsSelection = false
            // Occurrence highlighting is paused while there are several carets.
            if !occurrenceRanges.isEmpty { occurrenceRanges = [] }
            needsDisplay = true
            tab?.showMultiCaretStatus()
        }
        if reveal { scrollRangeToVisible(primaryRange) }
    }

    /// Leaves multi-caret mode, keeping NSTextView's selection (called when
    /// something else sets the selection).
    func endMultiCarets() {
        multiCarets = nil
        multiPrimary = 0
        needsDisplay = true
    }

    /// ⎋ / Text › Selection › Single Caret: back to the primary caret.
    func collapseToPrimary() {
        guard let m = multiCarets else { return }
        setCarets([m[multiPrimary]], primary: 0)
    }

    // MARK: Adding carets

    /// ⌃⇧↑ / ⌃⇧↓: a caret on the line above the topmost caret or below the
    /// bottommost, at the same visual column.
    func addCaret(below: Bool) {
        let (carets, _) = allCarets
        let ns = string as NSString
        guard let c = MultiCaret.caretBeside(carets, below: below, in: ns, lines: lines, tabWidth: tabWidth) else { NSSound.beep(); return }
        // The goal column stays with the caret it came from too, so ⌃⇧↓ again keeps the column.
        var list = carets
        if let i = list.indices.max(by: { below ? list[$0].head < list[$1].head : list[$0].head > list[$1].head }), list[i].goalColumn == nil {
            list[i].goalColumn = c.goalColumn
        }
        list.append(c)
        setCarets(list, primary: list.count - 1)
    }

    /// ⌘D: with a bare caret, selects the word there (whole-word search);
    /// with a selection, adds the next occurrence of it as a selection.
    func addNextOccurrence() {
        let ns = string as NSString
        var (carets, primary) = allCarets
        let p = carets[primary].range
        if p.length == 0 {
            guard let w = Occurrences.word(at: p.location, in: ns) else { NSSound.beep(); return }
            multiNeedle = (ns.substring(with: w), true)
            // Every bare caret selects its word (several carets: each one).
            carets = carets.map { c in c.isEmpty ? (Occurrences.word(at: c.head, in: ns).map { Caret($0) } ?? c) : c }
            setCarets(carets, primary: primary)
            return
        }
        guard NSMaxRange(p) <= ns.length else { return }
        let text = ns.substring(with: p)
        let whole = multiNeedle?.text == text ? multiNeedle!.wholeWord : false
        multiNeedle = (text, whole)
        guard carets.count < caretCap,
              let r = MultiCaret.nextOccurrence(of: text, wholeWord: whole, in: ns, after: NSMaxRange(p), existing: carets.map(\.range))
        else { NSSound.beep(); return }
        carets.append(Caret(r))
        setCarets(carets, primary: carets.count - 1)
    }

    /// ⌃⌘G: every occurrence of the selection (or of the word at the caret).
    func selectAllOccurrences() {
        let ns = string as NSString
        let (carets, primary) = allCarets
        var p = carets[primary].range
        var whole = false
        if p.length == 0 {
            guard let w = Occurrences.word(at: p.location, in: ns) else { NSSound.beep(); return }
            p = w
            whole = true
        } else if let n = multiNeedle, NSMaxRange(p) <= ns.length, n.text == ns.substring(with: p) {
            whole = n.wholeWord
        }
        let text = ns.substring(with: p)
        multiNeedle = (text, whole)
        let found = MultiCaret.allOccurrences(of: text, wholeWord: whole, in: ns, limit: caretCap)
        guard !found.ranges.isEmpty else { NSSound.beep(); return }
        if found.capped { NSSound.beep() }
        let list = found.ranges.map { Caret($0) }
        let at = found.ranges.firstIndex { $0.location == p.location } ?? 0
        setCarets(list, primary: at)
    }

    // MARK: Editing at every caret

    /// Applies one edit per caret (from `allCarets`, same order) as one
    /// undo step that also puts the carets back on undo and redo.
    func applyMulti(_ edits: [MultiCaret.Edit], primary: Int, actionName: String, afterEdits: (([NSRange]) -> Void)? = nil) {
        guard isEditable, let storage = textStorage, let um = undoManager else { NSSound.beep(); return }
        let before = allCarets
        breakUndoCoalescing()
        um.beginUndoGrouping()
        registerCaretUndo(before.carets, primary: before.primary, setNow: true)
        let result = MultiCaret.resolve(edits)
        multiApplying = true
        multiOwnsSelection = true
        let attrs = typingAttributes
        // Each caret's edit is its own storage edit (exact line index, colouring,
        // bookmarks and git bars), but the text view hears about the change
        // once: didChangeText per caret ran the window's whole text-changed
        // path k times and cost 8x more at 800 carets (518 vs 62 ms a key).
        // One beginEditing bracket was faster still (27 ms) but hands
        // storageEdited the union of all the edits (see docs/architecture.md).
        var changed = false
        for e in result.edits.reversed() where !e.isNoOp {
            guard shouldChangeText(in: e.range, replacementString: e.replacement) else { continue }
            storage.replaceCharacters(in: e.range, with: NSAttributedString(string: e.replacement, attributes: attrs))
            changed = true
        }
        if changed { didChangeText() }
        multiApplying = false
        multiOwnsSelection = false
        afterEdits?(result.selections)
        let n = MultiCaret.normalize(result.selections.map { Caret($0) }, primary: primary)
        setCarets(n.carets, primary: n.primary)
        registerCaretUndo(n.carets, primary: n.primary, setNow: false)
        um.endUndoGrouping()
        um.setActionName(actionName)
        breakUndoCoalescing()
    }

    /// An undo record for the carets inside an undo group (the same
    /// pattern as the bookmarks': a record made before the text change runs
    /// after the text's own undo, one made after it after the text's redo).
    private func registerCaretUndo(_ carets: [Caret], primary: Int, setNow: Bool) {
        undoManager?.registerUndo(withTarget: self) { tv in
            MainActor.assumeIsolated {
                if setNow {
                    let len = (tv.string as NSString).length
                    let clamped = carets.map { Caret(anchor: min($0.anchor, len), head: min($0.head, len)) }
                    tv.setCarets(clamped, primary: primary)
                }
                tv.registerCaretUndo(carets, primary: primary, setNow: !setNow)
            }
        }
    }

    private var pairingOn: Bool { Settings.shared.autoCloseBrackets && AutoEdit.pairs(in: language) }

    /// Typing at every caret: auto-pairing and the Python clause realign
    /// per caret, as with one; an input method's committed text goes in at
    /// the primary (where it composed) and at every other caret.
    func multiInsertText(_ string: Any, replacementRange: NSRange) {
        guard let carets = multiCarets else { return }
        let s = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        if hasMarkedText() {
            commitMarkedText(string, s, replacementRange: replacementRange)
            return
        }
        // A replacement somewhere else (spelling, Services, Writing Tools): the primary only.
        if replacementRange.location != NSNotFound, replacementRange != carets[multiPrimary].range {
            collapseToPrimary()
            insertText(string, replacementRange: replacementRange)
            return
        }
        let ns = self.string as NSString
        var paired: Set<Int> = []
        let edits: [MultiCaret.Edit] = carets.enumerated().map { i, c in
            let r = c.range
            if s.utf16.count == 1, let u = s.utf16.first {
                if language == .python, s == ":", let e = pythonClauseEdit(r) { return relative(e) }
                if pairingOn, let e = AutoEdit.typingEdit(u, in: ns, selection: r, language: language,
                                                         afterIsAutoClosed: autoClosers.contains(NSMaxRange(r))) {
                    if e.replacement.utf16.count == 2 { paired.insert(i) }
                    return relative(e)
                }
            }
            return MultiCaret.Edit(replacing: r, with: s)
        }
        applyMulti(edits, primary: multiPrimary, actionName: String(localized: "Typing")) { sel in
            for i in paired { self.autoClosers.append(sel[i].location) }
            if self.autoClosers.count > 64 { self.autoClosers.removeFirst(self.autoClosers.count - 64) }
        }
    }

    private func relative(_ e: TextEdit) -> MultiCaret.Edit {
        MultiCaret.Edit(range: e.range, replacement: e.replacement,
                        selection: NSRange(location: e.selection.location - e.range.location, length: e.selection.length))
    }

    /// The input method commits (a dead key's é, a Japanese word): NSTextView
    /// puts it in place of the marked text at the primary; then the same
    /// text goes in at every other caret, all in one undo step.
    private func commitMarkedText(_ string: Any, _ s: String, replacementRange: NSRange) {
        guard let um = undoManager else { return }
        let marked = markedRange()
        breakUndoCoalescing()
        um.beginUndoGrouping()
        // The carets as they were before composing (the marked text's own units dropped).
        let before = allCarets
        registerCaretUndo(MultiCaret.shift(before.carets, oldRange: marked, newLength: 0), primary: before.primary, setNow: true)
        multiOwnsSelection = true
        super.insertText(string, replacementRange: replacementRange)
        multiOwnsSelection = false
        let committedEnd = marked.location + (s as NSString).length
        // Carets have followed the commit (textEdited); the primary is the one at its end.
        guard let carets = multiCarets else { um.endUndoGrouping(); return }
        let primary = carets.firstIndex { $0.isEmpty && $0.head == committedEnd } ?? multiPrimary
        let edits = carets.enumerated().map { i, c in
            i == primary ? MultiCaret.Edit(range: NSRange(location: c.head, length: 0), replacement: "", selection: NSRange(location: 0, length: 0))
                : MultiCaret.Edit(replacing: c.range, with: s)
        }
        multiPrimary = primary
        applyMulti(edits, primary: primary, actionName: String(localized: "Typing"))
        um.endUndoGrouping()
        um.setActionName(String(localized: "Typing"))
    }

    /// Paste: one line per caret when the clipboard has as many lines as
    /// there are carets, else the whole text at each.
    func multiPaste(_ s: String) {
        let (carets, primary) = allCarets
        applyMulti(MultiCaret.paste(s, at: carets), primary: primary, actionName: String(localized: "Paste"))
    }

    /// Copy and Cut: every selection, in document order, joined with "\n".
    /// False with no selections at all (the single-caret behaviour runs).
    func multiCopy(cut: Bool) -> Bool {
        let (carets, primary) = allCarets
        let text = MultiCaret.copyText(carets, in: string as NSString)
        guard carets.contains(where: { !$0.isEmpty }) else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        if cut {
            applyMulti(carets.map { MultiCaret.Edit(replacing: $0.range, with: "") }, primary: primary, actionName: String(localized: "Cut"))
        }
        return true
    }

    /// Key commands with several carets. True when handled; anything not
    /// handled here collapses to the primary caret and runs as usual.
    @discardableResult
    func multiCommand(_ selector: Selector) -> Bool {
        guard let carets = multiCarets else { return false }
        let ns = string as NSString
        let p = multiPrimary
        func move(_ m: MultiCaret.Motion, extend: Bool = false) {
            setCarets(MultiCaret.move(carets, m, extend: extend, in: ns, lines: lines, tabWidth: tabWidth), primary: p)
        }
        func delete(_ k: MultiCaret.Deletion) {
            applyMulti(MultiCaret.delete(k, at: carets, in: ns, lines: lines, language: language, pairing: pairingOn), primary: p,
                       actionName: String(localized: "Delete"))
        }
        switch NSStringFromSelector(selector) {
        case "cancelOperation:", "cancel:", "complete:": collapseToPrimary()
        case "insertNewline:", "insertNewlineIgnoringFieldEditor:", "insertLineBreak:":
            guard let lineStartFor else { return false }
            let unit = indentation?().unit
            let edits = carets.map { c -> MultiCaret.Edit in
                relative(AutoEdit.newlineEdit(in: ns, lineStart: lineStartFor(c.range.location), selection: c.range, language: language, unit: unit))
            }
            applyMulti(edits, primary: p, actionName: String(localized: "Typing"))
        case "insertTab:", "insertTabIgnoringFieldEditor:":
            let ind = indentation?() ?? Indentation(usesTabs: true, width: 4)
            let spaces = !ind.usesTabs && (tabInsertsSpaces?() ?? true)
            let edits = carets.map { c -> MultiCaret.Edit in
                guard spaces else { return MultiCaret.Edit(replacing: c.range, with: "\t") }
                let col = MultiCaret.visualColumn(of: c.range.location, in: ns, lines: lines, tabWidth: ind.width)
                return MultiCaret.Edit(replacing: c.range, with: String(repeating: " ", count: ind.width - col % ind.width))
            }
            applyMulti(edits, primary: p, actionName: String(localized: "Typing"))
        case "deleteBackward:", "deleteBackwardByDecomposingPreviousCharacter:": delete(.backward)
        case "deleteForward:": delete(.forward)
        case "deleteWordBackward:": delete(.wordBackward)
        case "deleteWordForward:": delete(.wordForward)
        case "deleteToBeginningOfLine:", "deleteToBeginningOfParagraph:": delete(.toLineStart)
        case "deleteToEndOfLine:", "deleteToEndOfParagraph:": delete(.toLineEnd)
        case "moveLeft:", "moveBackward:": move(.left)
        case "moveRight:", "moveForward:": move(.right)
        case "moveUp:": move(.up)
        case "moveDown:": move(.down)
        case "moveWordLeft:", "moveWordBackward:": move(.wordLeft)
        case "moveWordRight:", "moveWordForward:": move(.wordRight)
        case "moveToBeginningOfLine:", "moveToLeftEndOfLine:", "moveToBeginningOfParagraph:": move(.lineStart)
        case "moveToEndOfLine:", "moveToRightEndOfLine:", "moveToEndOfParagraph:": move(.lineEnd)
        case "moveLeftAndModifySelection:", "moveBackwardAndModifySelection:": move(.left, extend: true)
        case "moveRightAndModifySelection:", "moveForwardAndModifySelection:": move(.right, extend: true)
        case "moveUpAndModifySelection:": move(.up, extend: true)
        case "moveDownAndModifySelection:": move(.down, extend: true)
        case "moveWordLeftAndModifySelection:", "moveWordBackwardAndModifySelection:": move(.wordLeft, extend: true)
        case "moveWordRightAndModifySelection:", "moveWordForwardAndModifySelection:": move(.wordRight, extend: true)
        case "moveToBeginningOfLineAndModifySelection:", "moveToLeftEndOfLineAndModifySelection:",
             "moveParagraphBackwardAndModifySelection:": move(.lineStart, extend: true)
        case "moveToEndOfLineAndModifySelection:", "moveToRightEndOfLineAndModifySelection:",
             "moveParagraphForwardAndModifySelection:": move(.lineEnd, extend: true)
        case "noop:": return true
        default:
            // Page moves, transpose, Shift-Tab and the rest: the primary caret only.
            collapseToPrimary()
            return false
        }
        return true
    }

    // MARK: Mouse

    /// ⌥-drag and ⌘-click. False: not ours (AppKit handles the event).
    func multiMouseDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.clickCount == 1, !flags.contains(.shift), let window else { return false }
        let start = convert(event.locationInWindow, from: nil)
        let column = flags.contains(.option) && !flags.contains(.command)
        guard column || (flags.contains(.command) && !flags.contains(.option)) else { return false }
        window.makeFirstResponder(self)
        let base = allCarets
        let downIndex = characterIndexForInsertion(at: start)
        guard downIndex != NSNotFound else { return false }
        func update(_ point: NSPoint) {
            if column {
                let cols = columnCarets(from: start, to: point)
                guard !cols.isEmpty else { return }
                setCarets(cols, primary: cols.count - 1, reveal: false)
            } else {
                let at = characterIndexForInsertion(at: point)
                var list = base.carets
                if at == downIndex, list.count > 1, let i = list.firstIndex(where: { $0.isEmpty && $0.head == at }) {
                    // ⌘-click on a caret removes it.
                    list.remove(at: i)
                    setCarets(list, primary: i < base.primary ? base.primary - 1 : (i == base.primary ? list.count - 1 : base.primary), reveal: false)
                    return
                }
                list.append(Caret(anchor: downIndex, head: at == NSNotFound ? downIndex : at))
                setCarets(list, primary: list.count - 1, reveal: false)
            }
        }
        update(start)
        // Track until the button comes up (events posted to the queue count too).
        while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            update(convert(e.locationInWindow, from: nil))
            autoscroll(with: e)
            if e.type == .leftMouseUp { break }
        }
        return true
    }

    /// The carets of a column from `a` (where the drag started) to `b`:
    /// one per text row the rectangle crosses, from the x of `a` to the x
    /// of `b` (a caret at the end of a shorter row).
    func columnCarets(from a: NSPoint, to b: NSPoint) -> [Caret] {
        guard let tlm = textLayoutManager else { return [] }
        let origin = textContainerOrigin
        let y0 = min(a.y, b.y) - origin.y, y1 = max(a.y, b.y) - origin.y
        guard let first = tlm.textLayoutFragment(for: CGPoint(x: 0, y: max(0, y0))) else { return [] }
        var rows: [CGFloat] = []
        tlm.enumerateTextLayoutFragments(from: first.rangeInElement.location, options: [.ensuresLayout]) { frag in
            let frame = frag.layoutFragmentFrame
            if frame.minY > y1 { return false }
            for line in frag.textLineFragments {
                let top = frame.minY + line.typographicBounds.minY, bottom = top + line.typographicBounds.height
                if bottom > y0, top <= y1 || rows.isEmpty { rows.append((top + bottom) / 2 + origin.y) }
            }
            return rows.count < caretCap
        }
        var out: [Caret] = []
        for y in rows {
            let s = characterIndexForInsertion(at: NSPoint(x: a.x, y: y))
            let e = characterIndexForInsertion(at: NSPoint(x: b.x, y: y))
            guard s != NSNotFound, e != NSNotFound else { continue }
            out.append(Caret(anchor: s, head: e))
        }
        return out
    }

    // MARK: Drawing

    /// The other carets' selections in the selection colour and their
    /// carets as bars in the caret colour (the primary is NSTextView's).
    /// Only what lies in the viewport.
    func drawMultiCarets(_ carets: [Caret], in rect: NSRect, layoutManager tlm: NSTextLayoutManager) {
        let clip = rect.intersection(bounds)
        guard !clip.isEmpty, let tcm = tlm.textContentManager, let vp = tlm.textViewportLayoutController.viewportRange else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: clip).addClip()
        let others = carets.indices.filter { $0 != multiPrimary }.map { carets[$0] }
        NSColor(hex: palette.selection).setFill()
        forEachSegment(others.filter { !$0.isEmpty }.map(\.range), clip: clip, layoutManager: tlm) { f in f.fill() }
        // Carets: the empty ones (as NSTextView, a selection shows no caret).
        let vpStart = offset(of: vp.location)
        let vpEnd = vpStart + tcm.offset(from: vp.location, to: vp.endLocation)
        let origin = textContainerOrigin
        insertionPointColor.setFill()
        for c in others where c.isEmpty && c.head >= vpStart && c.head <= vpEnd {
            guard let loc = tcm.location(vp.location, offsetBy: c.head - vpStart), let tr = NSTextRange(location: loc, end: loc) else { continue }
            tlm.enumerateTextSegments(in: tr, type: .standard, options: [.rangeNotRequired]) { _, frame, _, _ in
                let f = NSRect(x: frame.minX + origin.x - 0.5, y: frame.minY + origin.y, width: 2, height: max(frame.height, 10))
                if f.intersects(clip) { f.fill() }
                return false
            }
        }
    }
}
