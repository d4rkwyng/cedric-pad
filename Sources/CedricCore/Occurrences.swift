import Foundation

/// Highlight-all and Mark All: what to look for (the selection, or the
/// word under the caret) and where it occurs. The editor only ever asks
/// for the occurrences inside a bounded range (the visible text), so the
/// cost per keystroke or scroll doesn't grow with the document.
public enum Occurrences {
    /// What to highlight: a literal, case-sensitive string, matched as a
    /// whole word or anywhere.
    public struct Needle: Equatable, Sendable {
        public var text: String
        public var wholeWord: Bool
        public init(_ text: String, wholeWord: Bool) {
            self.text = text
            self.wholeWord = wholeWord
        }
    }

    /// The longest selection that is highlighted elsewhere (a longer one
    /// is rarely repeated and costs more to look for).
    public static let maxNeedleLength = 200
    /// At most this many UTF-16 units are searched per call.
    public static let maxScanLength = 200_000

    /// Letters, digits and "_" (and both halves of a surrogate pair, so a
    /// non-BMP letter doesn't split a word).
    public static func isWordUnit(_ c: unichar) -> Bool {
        if c < 128 {
            return (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
        }
        if UTF16.isLeadSurrogate(c) || UTF16.isTrailSurrogate(c) { return true }
        guard let s = Unicode.Scalar(c) else { return false }
        return CharacterSet.alphanumerics.contains(s)
    }

    /// The word touching `offset` (the caret may sit just after it), at
    /// most `maxLength` units long, or nil.
    public static func word(at offset: Int, in text: NSString, maxLength: Int = 128) -> NSRange? {
        let n = text.length
        guard n > 0, offset >= 0, offset <= n else { return nil }
        let atWord = offset < n && isWordUnit(text.character(at: offset))
        let beforeWord = offset > 0 && isWordUnit(text.character(at: offset - 1))
        guard atWord || beforeWord else { return nil }
        var s = offset, e = offset
        while s > 0, offset - s <= maxLength, isWordUnit(text.character(at: s - 1)) { s -= 1 }
        while e < n, e - offset <= maxLength, isWordUnit(text.character(at: e)) { e += 1 }
        guard e - s <= maxLength else { return nil }
        return NSRange(location: s, length: e - s)
    }

    /// The needle for this selection: the selected text (one line, not
    /// just whitespace, up to `maxNeedleLength`), or with an empty
    /// selection the word under the caret (two units or more), whole word.
    public static func needle(selection: NSRange, in text: NSString) -> Needle? {
        if selection.length == 0 {
            guard let w = word(at: selection.location, in: text), w.length >= 2 else { return nil }
            return Needle(text.substring(with: w), wholeWord: true)
        }
        guard selection.length <= maxNeedleLength, NSMaxRange(selection) <= text.length else { return nil }
        let s = text.substring(with: selection)
        guard !s.contains("\n"), !s.allSatisfy({ $0 == " " || $0 == "\t" }) else { return nil }
        // A selected whole word matches whole words only (a double-click on
        // "id" shouldn't light up every "width").
        let whole = s.utf16.allSatisfy(isWordUnit)
            && (selection.location == 0 || !isWordUnit(text.character(at: selection.location - 1)))
            && (NSMaxRange(selection) == text.length || !isWordUnit(text.character(at: NSMaxRange(selection))))
        return Needle(s, wholeWord: whole)
    }

    /// Occurrences of `needle` within `range` (clamped to the text and to
    /// `maxScanLength`), at most `limit` of them.
    public static func find(_ needle: Needle, in text: NSString, range: NSRange, limit: Int = 2_000) -> [NSRange] {
        let n = text.length
        let start = max(0, min(range.location, n))
        let end = min(n, NSMaxRange(range), start + maxScanLength)
        return scan(needle, in: text, from: start, to: end, limit: limit)
    }

    /// How many times `needle` occurs in the whole text (Mark All's count),
    /// stopping at `limit`.
    public static func count(_ needle: Needle, in text: NSString, limit: Int = 100_000) -> Int {
        scan(needle, in: text, from: 0, to: text.length, limit: limit).count
    }

    private static func scan(_ needle: Needle, in text: NSString, from start: Int, to end: Int, limit: Int) -> [NSRange] {
        let len = (needle.text as NSString).length
        guard len > 0, end - start >= len else { return [] }
        var out: [NSRange] = []
        var pos = start
        while pos < end, out.count < limit {
            let r = text.range(of: needle.text, options: [.literal], range: NSRange(location: pos, length: end - pos))
            if r.location == NSNotFound { break }
            if !needle.wholeWord || isWholeWord(r, in: text) { out.append(r) }
            pos = r.location + max(1, needle.wholeWord ? 1 : r.length)
        }
        return out
    }

    static func isWholeWord(_ r: NSRange, in text: NSString) -> Bool {
        (r.location == 0 || !isWordUnit(text.character(at: r.location - 1)))
            && (NSMaxRange(r) >= text.length || !isWordUnit(text.character(at: NSMaxRange(r))))
    }
}
