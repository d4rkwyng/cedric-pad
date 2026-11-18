import Foundation

/// Builds the `OwlContext` a provider sees: the visible lines plus about 40
/// lines either side, whole lines only, capped at 8 KB (8,192 UTF-16 code
/// units). A document that fits in the cap is sent whole.
///
/// Coordinates: in an `OwlContext` built here, `visibleRange`, `selection`
/// and every `OwlHint.range` a provider returns are UTF-16 offsets into
/// `context.text`, not into the document. `context.textStart` (= `offset`)
/// is where that text starts in the document. The coordinator converts a
/// hint's range to `range.location + textStart`, drops the hint if that
/// range is out of bounds or the document's edit generation moved, and
/// Apply also checks the text there is still what the provider saw. The
/// rules provider follows the same convention: its ranges are relative to
/// `context.text` too (they equal document ranges only when textStart = 0).
public struct OwlContextWindow: Sendable {
    public static let byteCap = 8192
    public static let marginLines = 40

    public let context: OwlContext
    /// Where `context.text` starts in the document (= `context.textStart`).
    public let offset: Int
    /// The whole document is in `context.text`.
    public let isWholeDocument: Bool

    public init(text full: NSString, visible: NSRange, selection: NSRange?, fileName: String?, language: String,
                documentID: UUID, editGeneration: Int, cap: Int = OwlContextWindow.byteCap, margin: Int = OwlContextWindow.marginLines) {
        let length = full.length
        var range: NSRange
        if length <= cap {
            range = NSRange(location: 0, length: length)
        } else {
            let vis = NSIntersectionRange(visible, NSRange(location: 0, length: length))
            var start = full.lineRange(for: NSRange(location: vis.location, length: 0)).location
            var end = NSMaxRange(full.lineRange(for: NSRange(location: max(vis.location, NSMaxRange(vis) - (vis.length > 0 ? 1 : 0)), length: 0)))
            for _ in 0..<margin {
                if start > 0 { start = full.lineRange(for: NSRange(location: start - 1, length: 0)).location }
                if end < length { end = NSMaxRange(full.lineRange(for: NSRange(location: end, length: 0))) }
            }
            // Over the cap: drop margin lines from the larger side.
            while end - start > cap {
                let top = vis.location - start, bottom = end - NSMaxRange(vis)
                if top <= 0 && bottom <= 0 { end = start + cap; break }
                if top >= bottom {
                    start = min(NSMaxRange(full.lineRange(for: NSRange(location: start, length: 0))), vis.location)
                } else {
                    end = max(full.lineRange(for: NSRange(location: end - 1, length: 0)).location, NSMaxRange(vis))
                }
            }
            range = NSRange(location: start, length: end - start)
        }
        // Never split a surrogate pair at the cap.
        if NSMaxRange(range) < length, range.length > 0,
           CFStringIsSurrogateHighCharacter(full.character(at: NSMaxRange(range) - 1)) {
            range.length -= 1
        }
        func local(_ r: NSRange) -> NSRange {
            let s = min(max(r.location - range.location, 0), range.length)
            let e = min(max(NSMaxRange(r) - range.location, 0), range.length)
            return NSRange(location: s, length: e - s)
        }
        offset = range.location
        isWholeDocument = range.location == 0 && range.length == length
        context = OwlContext(fileName: fileName, language: language, text: full.substring(with: range), textStart: range.location,
                             visibleRange: local(visible), selection: selection.map(local),
                             documentID: documentID, editGeneration: editGeneration, isWholeDocument: isWholeDocument)
    }
}

/// What the app knows about a document beyond its text, for the rules that
/// need it (reload, unsaved for hours, CRLF).
public struct OwlDocumentFacts: Sendable, Equatable {
    public var isWholeDocument: Bool
    public var changedOnDisk: Bool
    /// When the document last went from saved to unsaved (nil: saved).
    public var unsavedSince: Date?
    public var lineEnding: LineEnding
    /// The file had more than one kind of line ending when it was read.
    public var mixedLineEndings: Bool
    /// The language was picked from the menu: the owl doesn't second-guess it.
    public var languageIsManual: Bool
    /// The time rules that depend on it (certificate expiry) use; nil: now.
    public var now: Date?

    public init(isWholeDocument: Bool = true, changedOnDisk: Bool = false, unsavedSince: Date? = nil, lineEnding: LineEnding = .lf,
                mixedLineEndings: Bool = false, languageIsManual: Bool = false, now: Date? = nil) {
        self.now = now
        self.isWholeDocument = isWholeDocument
        self.changedOnDisk = changedOnDisk
        self.unsavedSince = unsavedSince
        self.lineEnding = lineEnding
        self.mixedLineEndings = mixedLineEndings
        self.languageIsManual = languageIsManual
    }
}

/// A provider that also wants the document facts. The coordinator calls
/// this instead of `hints(for:)` when a provider adopts it.
public protocol OwlFactsAwareProvider: OwlHintProvider {
    func hints(for context: OwlContext, facts: OwlDocumentFacts) async -> [OwlHint]
}

/// Turns a replacement of `range` in `old` into the smallest equivalent
/// edit (common prefix and suffix dropped), so applying a hint moves as
/// little text, and as little of the selection, as possible.
public enum OwlEdit {
    public static func minimal(in old: NSString, range: NSRange, replacement: String) -> (range: NSRange, replacement: String) {
        let a = old.substring(with: range) as NSString
        let b = replacement as NSString
        var p = 0
        let maxP = min(a.length, b.length)
        while p < maxP, a.character(at: p) == b.character(at: p) { p += 1 }
        var s = 0
        while s < maxP - p, a.character(at: a.length - 1 - s) == b.character(at: b.length - 1 - s) { s += 1 }
        // Keep surrogate pairs whole.
        if p > 0, CFStringIsSurrogateHighCharacter(a.character(at: p - 1)) { p -= 1 }
        if s > 0, CFStringIsSurrogateLowCharacter(a.character(at: a.length - s)) { s -= 1 }
        let r = NSRange(location: range.location + p, length: a.length - p - s)
        return (r, b.substring(with: NSRange(location: p, length: b.length - p - s)))
    }
}
