import AppKit
import CedricCore

/// An `NSTextContentStorage` that, when `chunkLimit` is set, hands TextKit
/// paragraphs longer than the limit as several consecutive text elements
/// ("chunks") instead of one.
///
/// Why: TextKit 2 lays out a paragraph as a whole. A 636,000-character line
/// (Derek's add-on import string) is one paragraph, so every keystroke and
/// every scroll re-typesets all of it: ~100 ms per keystroke here, with or
/// without wrapping. Cut into chunks, TextKit only lays out the chunks near
/// the viewport and re-lays out only the chunk being edited.
///
/// The cost: a chunk boundary is a forced line break on screen (a wrapped
/// row ends early there, or, without wrapping, the line continues on the
/// next row). The text itself is untouched: no characters are inserted,
/// copy, save and find see the one long line. Chunks start at fixed
/// offsets from the paragraph start, nudged so they never split a
/// composed character sequence (surrogate pairs, combining marks).
final class ChunkedContentStorage: NSTextContentStorage {
    /// Paragraphs longer than this are split; nil: TextKit's own paragraphs.
    var chunkLimit: Int? {
        didSet { if chunkLimit != oldValue { cache.removeAll() } }
    }

    /// Chunk elements by start offset, reused until the next edit so
    /// TextKit keeps their layout. Dropped at or after an edit.
    private var cache: [Int: (range: NSRange, element: NSTextParagraph)] = [:]

    /// The line (paragraph) holding an offset, newline included. Set by the
    /// editor to its line index (O(log n)); NSString.paragraphRange scans
    /// the whole 636 K line on every call.
    var lineRange: ((Int) -> NSRange?)?

    override func processEditing(for textStorage: NSTextStorage, edited editMask: NSTextStorageEditActions,
                                 range newCharRange: NSRange, changeInLength delta: Int, invalidatedRange invalidatedCharRange: NSRange) {
        if chunkLimit != nil, !cache.isEmpty {
            // Chunks start at fixed steps from their line's start, so the
            // chunks ending before the edit keep their text and bounds;
            // the rest are rebuilt on demand.
            let at = invalidatedCharRange.location
            cache = cache.filter { NSMaxRange($0.value.range) < at }
        }
        super.processEditing(for: textStorage, edited: editMask, range: newCharRange,
                             changeInLength: delta, invalidatedRange: invalidatedCharRange)
    }

    /// The chunk holding `offset` (offset == length: the last chunk).
    func chunkRange(at offset: Int, in text: NSString, limit: Int) -> NSRange {
        let probe = min(offset, max(0, text.length - 1))
        let para = lineRange?(probe).flatMap { NSLocationInRange(probe, $0) ? $0 : nil } ?? text.paragraphRange(for: NSRange(location: probe, length: 0))
        return LargeDocument.chunk(containing: probe, line: para, in: text, limit: limit)
    }

    private func element(for r: NSRange, in storage: NSTextStorage) -> NSTextParagraph? {
        if let c = cache[r.location], c.range == r { return c.element }
        let doc = documentRange.location
        guard let s = location(doc, offsetBy: r.location), let e = location(s, offsetBy: r.length) else { return nil }
        let p = ChunkParagraph(attributedString: storage.attributedSubstring(from: r))
        p.elementRange = NSTextRange(location: s, end: e)
        // The content range is the chunk without its trailing newline, if any.
        let hasNewline = r.length > 0 && (storage.string as NSString).character(at: NSMaxRange(r) - 1) == 10
        if hasNewline, let ce = location(s, offsetBy: r.length - 1) {
            p.content = NSTextRange(location: s, end: ce)
            p.separator = NSTextRange(location: ce, end: e)
        } else {
            p.content = p.elementRange
            p.separator = NSTextRange(location: e)
        }
        p.textContentManager = self
        cache[r.location] = (r, p)
        return p
    }

    override func enumerateTextElements(from textLocation: NSTextLocation?, options: NSTextContentManager.EnumerationOptions = [],
                                        using block: (NSTextElement) -> Bool) -> NSTextLocation? {
        guard let limit = chunkLimit, let storage = textStorage, storage.length > 0 else {
            return super.enumerateTextElements(from: textLocation, options: options, using: block)
        }
        let text = storage.string as NSString
        let len = text.length
        let reverse = options.contains(.reverse)
        var offset = textLocation.map { self.offset(from: documentRange.location, to: $0) } ?? (reverse ? len : 0)
        if reverse {
            // From a location, backwards: the element ending at or containing it.
            var at = offset - 1
            while at >= 0 {
                let r = chunkRange(at: at, in: text, limit: limit)
                guard let p = element(for: r, in: storage) else { return nil }
                if !block(p) { return p.elementRange?.location }
                at = r.location - 1
            }
            return documentRange.location
        }
        offset = max(0, min(offset, len))
        var at = offset == len ? max(0, len - 1) : offset
        while at < len {
            let r = chunkRange(at: at, in: text, limit: limit)
            guard let p = element(for: r, in: storage) else { return nil }
            if !block(p) { return p.elementRange?.endLocation }
            at = NSMaxRange(r)
        }
        return documentRange.endLocation
    }
}

/// A chunk: TextKit reads the content and separator ranges of a paragraph
/// it lays out, which NSTextContentStorage only fills in for paragraphs it
/// made itself.
final class ChunkParagraph: NSTextParagraph {
    var content: NSTextRange?
    var separator: NSTextRange?
    override var paragraphContentRange: NSTextRange? { content }
    override var paragraphSeparatorRange: NSTextRange? { separator }
}

