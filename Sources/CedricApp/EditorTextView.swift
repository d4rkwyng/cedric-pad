import AppKit
import CedricCore

/// The editing surface: an NSTextView on TextKit 2 (NSTextLayoutManager),
/// which lays out only what is near the viewport, so large files open
/// quickly. Adds the current-line highlight and drawn invisibles; text
/// colours come from `SyntaxColorizer` as text-storage attributes.
final class EditorTextView: NSTextView {
    var palette: EditorPalette = EditorPalettes.light
    var showInvisibles = false { didSet { needsDisplay = true } }
    /// Limits continuous spell checking to comments, strings and prose (Spelling.swift).
    weak var spelling: EditorSpelling?
    /// Misspellings the checker has marked (in scope), for the checks.
    var markedMisspellings: [NSRange] = []
    /// Drawn behind the text (EditingFeatures.swift): other occurrences of
    /// the selection or word, Mark All's marks, and the bracket pair at
    /// the caret. Only ranges in or near the visible text.
    var occurrenceRanges: [NSRange] = []
    var markRanges: [NSRange] = []
    var bracketRanges: [NSRange] = []

    static func make() -> EditorTextView {
        let layoutManager = NSTextLayoutManager()
        let content = ChunkedContentStorage()
        content.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.textContainer = container
        let tv = EditorTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.drawsBackground = true
        return tv
    }

    var contentStorage: ChunkedContentStorage? { textLayoutManager?.textContentManager as? ChunkedContentStorage }

    // MARK: Range conversion

    func textRange(for range: NSRange) -> NSTextRange? {
        guard let tlm = textLayoutManager, let tcm = tlm.textContentManager else { return nil }
        let doc = tcm.documentRange.location
        guard let start = tcm.location(doc, offsetBy: range.location),
              let end = tcm.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    func offset(of location: NSTextLocation) -> Int {
        guard let tcm = textLayoutManager?.textContentManager else { return 0 }
        return tcm.offset(from: tcm.documentRange.location, to: location)
    }

    /// The character range laid out for the viewport (plus what TextKit
    /// laid out around it).
    var viewportCharacterRange: NSRange? {
        guard let tlm = textLayoutManager, let vr = tlm.textViewportLayoutController.viewportRange else { return nil }
        let start = offset(of: vr.location)
        return NSRange(location: start, length: max(0, offset(of: vr.endLocation) - start))
    }

    /// The layout fragment at the top of the visible rect (laid out if
    /// needed), else the viewport's first: TextKit's viewport can lag a
    /// scroll by a layout pass.
    var firstVisibleLocation: NSTextLocation? {
        guard let tlm = textLayoutManager else { return nil }
        let top = CGPoint(x: 0, y: max(0, visibleRect.minY - textContainerOrigin.y))
        if let frag = tlm.textLayoutFragment(for: top) { return frag.rangeInElement.location }
        return tlm.textViewportLayoutController.viewportRange?.location
    }

    /// Characters from the top of the visible rect to its bottom, joined
    /// with TextKit's viewport range.
    var visibleCharacterRange: NSRange? {
        guard let tlm = textLayoutManager else { return nil }
        var result = viewportCharacterRange
        let top = CGPoint(x: 0, y: max(0, visibleRect.minY - textContainerOrigin.y))
        let bottom = CGPoint(x: 0, y: max(0, visibleRect.maxY - textContainerOrigin.y))
        if let a = tlm.textLayoutFragment(for: top), let b = tlm.textLayoutFragment(for: bottom) ?? tlm.textLayoutFragment(for: top) {
            let start = offset(of: a.rangeInElement.location)
            let end = offset(of: b.rangeInElement.endLocation)
            let r = NSRange(location: start, length: max(0, end - start))
            result = result.map { NSUnionRange($0, r) } ?? r
        }
        return result
    }

    // MARK: Auto-indent, bracket and quote pairing (AutoEdit in CedricCore)

    /// The document's language (pairing is for code, not prose).
    var language: Language = .plain
    /// Where the line holding an offset starts (from the line index: O(log n)).
    var lineStartFor: ((Int) -> Int)?

    private var pairing: Bool { Settings.shared.autoCloseBrackets && AutoEdit.pairs(in: language) }

    private func unit(at i: Int) -> unichar? {
        let ns = string as NSString
        return i >= 0 && i < ns.length ? ns.character(at: i) : nil
    }

    /// Return: a newline with the line's indent (one step more after an
    /// opening bracket; between a pair, the closer on its own line).
    override func insertNewline(_ sender: Any?) {
        guard isEditable, !hasMarkedText(), let lineStartFor else { super.insertNewline(sender); return }
        let sel = selectedRange()
        if let e = markdownEdit({ d, _ in MarkdownTable.newline(in: d, selection: sel) }) {
            applyEdit(e, String(localized: "Add Table Row"))
            return
        }
        if let e = markdownEdit({ MarkdownLists.newline(in: $0, selection: sel, language: language,
                                                        tabWidth: $1.width, useTabs: $1.usesTabs) }) {
            applyEdit(e, String(localized: "Typing"))
            return
        }
        let r = AutoEdit.newline(in: string as NSString, lineStart: lineStartFor(sel.location), caret: sel.location,
                                 after: NSMaxRange(sel), language: language, unit: indentation?().unit)
        guard r.text != "\n" || r.caret != 1 else { super.insertNewline(sender); return }
        insertText(r.text, replacementRange: sel)
        setSelectedRange(NSRange(location: sel.location + r.caret, length: 0))
    }

    // MARK: Tab and Shift-Tab (Indentation.swift)

    /// The document's indentation (tabs or spaces, width).
    var indentation: (() -> Indentation)?
    /// Whether Tab types spaces (else a tab character).
    var tabInsertsSpaces: (() -> Bool)?
    /// Indents (true) or outdents (false) the selected lines.
    var onShiftLines: ((Bool) -> Void)?

    /// Tab: with a selection over several lines, indents them; else a tab,
    /// or where spaces were chosen, spaces up to the next tab stop.
    override func insertTab(_ sender: Any?) {
        guard isEditable, !hasMarkedText(), let indentation, let lineStartFor else { super.insertTab(sender); return }
        let sel = selectedRange()
        let ns = string as NSString
        // Markdown: Tab in a table goes to the next cell; in a list item it indents the item.
        if let e = markdownEdit({ d, _ in MarkdownTable.tab(in: d, selection: sel, forward: true) }) {
            applyEdit(e, String(localized: "Format Table"))
            return
        }
        if let e = markdownEdit({ MarkdownLists.shiftItem(in: $0, selection: sel, right: true, useTabs: $1.usesTabs, tabWidth: $1.width) }) {
            applyEdit(e, String(localized: "Indent"))
            return
        }
        if sel.length > 0, ns.rangeOfCharacter(from: .newlines, options: [], range: sel).location != NSNotFound {
            onShiftLines?(true)
            return
        }
        let ind = indentation()
        guard !ind.usesTabs, tabInsertsSpaces?() ?? true else { super.insertTab(sender); return }
        // The caret's column, tabs counted to their stops (a bounded look back).
        let start = lineStartFor(sel.location)
        var col = 0
        var i = max(start, sel.location - 4096)
        while i < sel.location { col = ns.character(at: i) == 9 ? (col / ind.width + 1) * ind.width : col + 1; i += 1 }
        insertText(String(repeating: " ", count: ind.width - col % ind.width), replacementRange: sel)
    }

    /// Shift-Tab: outdents the selected lines (or the caret's line).
    override func insertBacktab(_ sender: Any?) {
        guard isEditable, !hasMarkedText(), let onShiftLines else { super.insertBacktab(sender); return }
        let sel = selectedRange()
        if let e = markdownEdit({ d, _ in MarkdownTable.tab(in: d, selection: sel, forward: false) }) {
            applyEdit(e, String(localized: "Format Table"))
            return
        }
        if let e = markdownEdit({ MarkdownLists.shiftItem(in: $0, selection: sel, right: false, useTabs: $1.usesTabs, tabWidth: $1.width) }) {
            applyEdit(e, String(localized: "Outdent"))
            return
        }
        onShiftLines(false)
    }

    // MARK: Markdown editing (MarkdownLists, MarkdownTable in CedricCore)

    /// Applies an edit as one undo step (the window controller's `apply`).
    var onEdit: ((TextEdit, String) -> Void)?
    /// Whether the line holding an offset is inside a fenced code block.
    var inFence: ((Int) -> Bool)?

    /// `make`'s edit, in a Markdown tab, outside fenced code, with the
    /// selection on one line; nil otherwise (the key does what it did).
    func markdownEdit(_ make: (NSString, Indentation) -> TextEdit?) -> TextEdit? {
        guard language == .markdown, onEdit != nil else { return nil }
        let sel = selectedRange()
        let ns = string as NSString
        if sel.length > 0, ns.rangeOfCharacter(from: .newlines, options: [], range: sel).location != NSNotFound { return nil }
        if language == .markdown, inFence?(sel.location) == true { return nil }
        return make(ns, indentation?() ?? Indentation(usesTabs: false, width: 4))
    }

    func applyEdit(_ e: TextEdit, _ name: String) { onEdit?(e, name) }

    /// Typing an opener or quote pairs it, a closer steps over the one
    /// already there, and with a selection both go around it. Only for
    /// single typed characters (not paste, not input methods).
    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard pairing, isEditable, !hasMarkedText(), replacementRange.location == NSNotFound,
              let s = (string as? String) ?? (string as? NSAttributedString)?.string, s.utf16.count == 1,
              let c = s.utf16.first else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        let sel = selectedRange()
        switch AutoEdit.typing(c, before: unit(at: sel.location - 1), after: unit(at: NSMaxRange(sel)), hasSelection: sel.length > 0,
                               language: language, afterIsAutoClosed: autoClosers.contains(NSMaxRange(sel))) {
        case .skip?:
            autoClosers.removeAll { $0 == sel.location }
            setSelectedRange(NSRange(location: sel.location + 1, length: 0))
        case .pair(let pair)?:
            super.insertText(pair, replacementRange: sel)
            autoClosers.append(sel.location + 1)
            if autoClosers.count > 16 { autoClosers.removeFirst() }
            setSelectedRange(NSRange(location: sel.location + 1, length: 0))
        case .wrap(let open, let close)?:
            let inner = (self.string as NSString).substring(with: sel)
            super.insertText(open + inner + close, replacementRange: sel)
            setSelectedRange(NSRange(location: sel.location + 1, length: sel.length))
        case nil:
            super.insertText(string, replacementRange: replacementRange)
        }
    }

    /// Where closers that pairing typed are (a few, newest last): a quote
    /// steps over only one of these, not a quote that was already there.
    private(set) var autoClosers: [Int] = []

    /// Every character edit (the window controller's storageEdited, undo
    /// included): closers after it shift, ones inside it are gone.
    func textEdited(oldRange: NSRange, newLength: Int) {
        guard !autoClosers.isEmpty else { return }
        let delta = newLength - oldRange.length
        autoClosers = autoClosers.compactMap { k in
            if k >= NSMaxRange(oldRange) { return k + delta }
            return k < oldRange.location ? k : nil
        }
    }

    /// Backspace between a pair ("(|)", "\"|\"") deletes both.
    override func deleteBackward(_ sender: Any?) {
        let sel = selectedRange()
        if pairing, isEditable, !hasMarkedText(), sel.length == 0,
           AutoEdit.deletesPair(before: unit(at: sel.location - 1), after: unit(at: sel.location), language: language) {
            super.insertText("", replacementRange: NSRange(location: sel.location - 1, length: 2))
            return
        }
        super.deleteBackward(sender)
    }

    // MARK: Paste normalisation

    /// Paste and drop: plain text only, with CRLF/CR turned into LF
    /// before it reaches the text (inserted as one undoable typing edit).
    /// (v0 rejected the edit in shouldChangeText and re-inserted it later,
    /// which silently dropped pastes.)
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        // Markdown: image files or a bitmap become image links (the window
        // controller copies them next to the document); a URL pasted over
        // a selection makes a link.
        if language == .markdown, isEditable, let onImages {
            let sel = selectedRange()
            let files = Self.imageFiles(pboard)
            if !files.isEmpty { onImages(files, nil, sel); return true }
            if let s = pboard.string(forType: .string) {
                if inFence?(sel.location) != true, let e = MarkdownPaste.linkPaste(in: string as NSString, selection: sel, pasted: s) {
                    applyEdit(e, String(localized: "Paste"))
                    return true
                }
            } else if let data = pboard.data(forType: .png) ?? pboard.data(forType: .tiff) {
                onImages([], data, sel)
                return true
            }
        }
        guard let s = pboard.string(forType: .string) else { return super.readSelection(from: pboard, type: type) }
        let normalized = TextCodec.normalizeLineEndings(s)
        insertText(normalized, replacementRange: selectedRange())
        return true
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        language == .markdown && onImages != nil ? [.string, .fileURL, .png, .tiff] : [.string]
    }

    /// Markdown: image files (or bitmap data) pasted or dropped, to go in
    /// at the range as image links. Set by the window controller.
    var onImages: ((_ files: [URL], _ bitmap: Data?, _ at: NSRange) -> Void)?

    /// The image files on a pasteboard (existing files with an image extension).
    static func imageFiles(_ pboard: NSPasteboard) -> [URL] {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { MarkdownPaste.isImageFile($0) && FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: Dropping files

    /// Opens files dropped on the text (each in its tab), as Notepad++
    /// does, instead of inserting their paths. Set by the window controller.
    var onDropFiles: (([URL]) -> Void)?

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        var types = super.acceptableDragTypes
        if !types.contains(.fileURL) { types.append(.fileURL) }
        return types
    }

    /// The file URLs a drag carries (none for text, or for a drag that
    /// started in this text view).
    private func droppedFiles(_ info: NSDraggingInfo) -> [URL] {
        guard onDropFiles != nil, (info.draggingSource as? NSView) !== self else { return [] }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { u in var dir: ObjCBool = false; return FileManager.default.fileExists(atPath: u.path, isDirectory: &dir) && !dir.boolValue }
    }

    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        droppedFiles(info).isEmpty ? super.draggingEntered(info) : .copy
    }

    override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        droppedFiles(info).isEmpty ? super.draggingUpdated(info) : .copy
    }

    override func prepareForDragOperation(_ info: NSDraggingInfo) -> Bool {
        droppedFiles(info).isEmpty ? super.prepareForDragOperation(info) : true
    }

    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        let files = droppedFiles(info)
        guard !files.isEmpty, let onDropFiles else { return super.performDragOperation(info) }
        // Markdown: image files go in as image links where they were
        // dropped; other files still open in tabs.
        if language == .markdown, isEditable, let onImages {
            let images = files.filter(MarkdownPaste.isImageFile)
            if !images.isEmpty {
                let others = files.filter { !MarkdownPaste.isImageFile($0) }
                var at = characterIndexForInsertion(at: convert(info.draggingLocation, from: nil))
                if at == NSNotFound || at > (string as NSString).length { at = selectedRange().location }
                DispatchQueue.main.async {
                    onImages(images, nil, NSRange(location: at, length: 0))
                    if !others.isEmpty { onDropFiles(others) }
                }
                return true
            }
        }
        // After the drag session ends (opening a tab inside it upsets AppKit's drag bookkeeping).
        DispatchQueue.main.async { onDropFiles(files) }
        return true
    }

    override func concludeDragOperation(_ info: NSDraggingInfo?) {
        if let info, !droppedFiles(info).isEmpty { return }
        super.concludeDragOperation(info)
    }

    /// ⌘X with nothing selected cuts the whole line (EditingFeatures.swift).
    var onCutLine: (() -> Void)?

    override func cut(_ sender: Any?) {
        if selectedRange().length == 0, let onCutLine { onCutLine(); return }
        super.cut(sender)
    }

    /// Cut stays enabled with an empty selection (it cuts the line).
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(cut(_:)), selectedRange().length == 0, onCutLine != nil {
            return isEditable && (string as NSString).length > 0
        }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: Drawing

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let tlm = textLayoutManager else { return }
        let origin = textContainerOrigin

        // Current line: the paragraph holding the caret (only without a
        // multi-character selection, as in most editors).
        let sel = selectedRange()
        if sel.length == 0, let loc = textRange(for: NSRange(location: sel.location, length: 0))?.location,
           let frag = tlm.textLayoutFragment(for: loc) {
            var f = frag.layoutFragmentFrame
            // On the empty last line TextKit reports the previous paragraph; fine for v0.
            f.origin.x = 0
            f.size.width = bounds.width
            f.origin.y += origin.y
            NSColor(hex: palette.currentLine).setFill()
            f.intersection(rect).fill()
        }

        drawHighlights(in: rect, layoutManager: tlm)
        if showInvisibles { drawInvisibles(in: rect, layoutManager: tlm) }
    }

    /// Marks, occurrences and the matching bracket pair, clipped to the
    /// view (since macOS 14 `rect` can be larger than the bounds).
    private func drawHighlights(in rect: NSRect, layoutManager tlm: NSTextLayoutManager) {
        guard !markRanges.isEmpty || !occurrenceRanges.isEmpty || !bracketRanges.isEmpty else { return }
        let clip = rect.intersection(bounds)
        guard !clip.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: clip).addClip()
        let match = NSColor(hex: palette.findMatch)
        let sel = selectedRange()
        forEachSegment(markRanges, clip: clip, layoutManager: tlm) { f in
            match.setFill()
            NSBezierPath(roundedRect: f, xRadius: 2, yRadius: 2).fill()
        }
        forEachSegment(occurrenceRanges.filter { $0 != sel }, clip: clip, layoutManager: tlm) { f in
            match.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: f, xRadius: 2, yRadius: 2).fill()
        }
        let caret = NSColor(hex: palette.caret)
        forEachSegment(bracketRanges, clip: clip, layoutManager: tlm) { f in
            caret.withAlphaComponent(0.18).setFill()
            NSBezierPath(rect: f).fill()
            caret.withAlphaComponent(0.7).setStroke()
            let p = NSBezierPath(rect: f.insetBy(dx: 0.5, dy: 0.5))
            p.lineWidth = 1
            p.stroke()
        }
    }

    /// Draws the segments of `ranges` that lie in TextKit's viewport (the
    /// laid-out text); anything else is skipped, so a stale or far-away
    /// range never makes TextKit lay out other parts of a big document.
    /// Locations are found from the viewport's start, not the document's.
    private func forEachSegment(_ ranges: [NSRange], clip: NSRect, layoutManager tlm: NSTextLayoutManager, _ draw: (NSRect) -> Void) {
        guard !ranges.isEmpty, let tcm = tlm.textContentManager,
              let vp = tlm.textViewportLayoutController.viewportRange else { return }
        let vpStart = offset(of: vp.location)
        let vpEnd = vpStart + tcm.offset(from: vp.location, to: vp.endLocation)
        let origin = textContainerOrigin
        for r in ranges where r.location >= vpStart && NSMaxRange(r) <= vpEnd {
            guard let start = tcm.location(vp.location, offsetBy: r.location - vpStart),
                  let end = tcm.location(start, offsetBy: r.length),
                  let tr = NSTextRange(location: start, end: end) else { continue }
            tlm.enumerateTextSegments(in: tr, type: .highlight, options: []) { _, frame, _, _ in
                let f = frame.offsetBy(dx: origin.x, dy: origin.y)
                if f.intersects(clip) { draw(f) }
                return true
            }
        }
    }

    private func drawInvisibles(in rect: NSRect, layoutManager tlm: NSTextLayoutManager) {
        guard let start = firstVisibleLocation else { return }
        let font = self.font ?? Settings.shared.font
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(hex: palette.invisibles)]
        let dot = NSAttributedString(string: "·", attributes: attrs)
        let arrow = NSAttributedString(string: "→", attributes: attrs)
        let pilcrow = NSAttributedString(string: "¬", attributes: attrs)
        let origin = textContainerOrigin
        tlm.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { frag in
            let frame = frag.layoutFragmentFrame
            if frame.minY + origin.y > rect.maxY { return false }
            if frame.maxY + origin.y < rect.minY { return true }
            guard let para = frag.textElement as? NSTextParagraph else { return true }
            let units = para.attributedString.string as NSString
            for line in frag.textLineFragments {
                let r = line.characterRange
                let lineOrigin = CGPoint(x: frame.minX + line.typographicBounds.minX + origin.x,
                                         y: frame.minY + line.typographicBounds.minY + origin.y)
                var i = r.location
                while i < r.location + r.length {
                    let c = units.character(at: i)
                    if c == 32 || c == 9 || c == 10 {
                        let p = line.locationForCharacter(at: i)
                        let glyph = c == 32 ? dot : c == 9 ? arrow : pilcrow
                        glyph.draw(at: CGPoint(x: lineOrigin.x + p.x, y: lineOrigin.y))
                    }
                    i += 1
                }
            }
            return true
        }
    }
}

/// Line numbers, drawn beside the scroll view (not as an NSRulerView: a
/// ruler can pull an NSTextView back to TextKit 1). Numbers come from the
/// line index, positions from the visible layout fragments.
final class GutterView: NSView {
    weak var textView: EditorTextView?
    var lineIndex: () -> LineIndex = { LineIndex() }
    var palette: EditorPalette = EditorPalettes.light { didSet { needsDisplay = true } }
    /// Bookmarked lines, drawn as a marker left of the number; a click on
    /// a line number toggles its bookmark.
    var bookmarks: () -> Bookmarks = { Bookmarks() }
    var onClickLine: ((Int) -> Void)?

    override var isFlipped: Bool { true }

    /// The line whose number is drawn at `y` (view coordinates).
    func line(atY y: CGFloat) -> Int? {
        guard let tv = textView, let tlm = tv.textLayoutManager, let scroll = tv.enclosingScrollView else { return nil }
        let point = CGPoint(x: 0, y: y + scroll.contentView.bounds.minY - tv.textContainerOrigin.y)
        guard let frag = tlm.textLayoutFragment(for: point) else { return nil }
        return lineIndex().line(containing: tv.offset(of: frag.rangeInElement.location))
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let line = line(atY: p.y) { onClickLine?(line) } else { super.mouseDown(with: event) }
    }

    /// Wide enough for the largest line number.
    func requiredWidth(lines: Int, font: NSFont) -> CGFloat {
        let digits = max(3, String(lines).count)
        let w = ("8" as NSString).size(withAttributes: [.font: gutterFont(font)]).width
        return ceil(CGFloat(digits) * w + 18)
    }

    private func gutterFont(_ f: NSFont) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: max(8, f.pointSize - 1), weight: .regular)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(hex: palette.gutterBackground).setFill()
        // Since macOS 14 views don't clip to their bounds and dirtyRect
        // can be the whole window: fill only our own part.
        dirtyRect.intersection(bounds).fill()
        guard let tv = textView, let tlm = tv.textLayoutManager, let scroll = tv.enclosingScrollView,
              let start = tv.firstVisibleLocation else { return }
        let index = lineIndex()
        let font = gutterFont(tv.font ?? Settings.shared.font)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(hex: palette.gutterForeground)]
        let currentAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(hex: palette.foreground)]
        let currentLine = index.line(containing: tv.selectedRange().location)
        let scrollY = scroll.contentView.bounds.minY
        let originY = tv.textContainerOrigin.y
        let textFont = tv.font ?? Settings.shared.font
        let marks = bookmarks()
        let markColor = NSColor(hex: palette.caret)
        tlm.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { frag in
            let frame = frag.layoutFragmentFrame
            let y = frame.minY + originY - scrollY
            if y > self.bounds.maxY { return false }
            if y + frame.height < 0 { return true }
            let offset = tv.offset(of: frag.rangeInElement.location)
            let line = index.line(containing: offset)
            // A long line in chunks (large mode) has several fragments:
            // number only the first.
            guard line < index.lineCount, index.starts[line] == offset else { return true }
            let s = NSAttributedString(string: String(line + 1), attributes: line == currentLine ? currentAttrs : attrs)
            let size = s.size()
            // Align with the first line's baseline.
            let baselineY = y + (frag.textLineFragments.first?.typographicBounds.minY ?? 0) + textFont.ascender - font.ascender
            s.draw(at: CGPoint(x: self.bounds.width - size.width - 8, y: baselineY))
            if marks.contains(line) {
                // A bookmark: a rounded tab at the gutter's left edge, as tall as the line.
                let h = max(6, min(frame.height, textFont.boundingRectForFont.height))
                markColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: 2, y: y + 1, width: 5, height: h - 2), xRadius: 2, yRadius: 2).fill()
            }
            return true
        }
        // The last empty line after a trailing newline has no fragment in
        // some TextKit versions; number it from the previous one.
    }
}
