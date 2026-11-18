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

    // MARK: Paste normalisation

    /// Paste and drop: plain text only, with CRLF/CR turned into LF
    /// before it reaches the text (inserted as one undoable typing edit).
    /// (v0 rejected the edit in shouldChangeText and re-inserted it later,
    /// which silently dropped pastes.)
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let s = pboard.string(forType: .string) else { return super.readSelection(from: pboard, type: type) }
        let normalized = TextCodec.normalizeLineEndings(s)
        insertText(normalized, replacementRange: selectedRange())
        return true
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

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

    private func forEachSegment(_ ranges: [NSRange], clip: NSRect, layoutManager tlm: NSTextLayoutManager, _ draw: (NSRect) -> Void) {
        let origin = textContainerOrigin
        for r in ranges {
            guard let tr = textRange(for: r) else { continue }
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

    override var isFlipped: Bool { true }

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
            return true
        }
        // The last empty line after a trailing newline has no fragment in
        // some TextKit versions; number it from the previous one.
    }
}
