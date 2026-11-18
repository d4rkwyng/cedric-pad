import Foundation

/// Typing helpers: auto-indent on Return, bracket and quote pairing (with
/// skip-over and paired delete) and the bracket matching the caret. Each
/// looks only at the caret's neighbourhood (bounded scans), so a keystroke
/// costs the same on a 636 K-character line.
public enum AutoEdit {
    /// Brackets and quotes pair in code, not in prose (plain text, Markdown).
    public static func pairs(in language: Language) -> Bool { language != .plain && language != .markdown && language != .diff }

    static let openers: [unichar: unichar] = [40: 41, 91: 93, 123: 125] // ( [ {
    static let closers: Set<unichar> = [41, 93, 125]
    static let space: Set<unichar> = [32, 9]

    /// The quotes that pair: no ' where it never starts a string (Swift
    /// and JSON), so an apostrophe in a comment or string stays one.
    static func quotes(in language: Language) -> Set<unichar> {
        switch language {
        case .javascript, .typescript, .shell: return [34, 39, 96] // " ' `
        case .swift, .json: return [34]
        default: return [34, 39]
        }
    }

    /// One indent step: a tab if the line is indented with tabs, else the
    /// document's own step (`preferred`, from its indentation setting),
    /// else spaces (2 for YAML and Ruby, 4 otherwise).
    public static func indentUnit(lineIndent: String, language: Language, preferred: String? = nil) -> String {
        if lineIndent.contains("\t") { return "\t" }
        if let preferred { return preferred }
        return language == .yaml || language == .ruby ? "  " : "    "
    }

    /// Return at `caret` (the selection `caret..<after` is replaced): a
    /// newline plus the line's indent, one step more after an opening
    /// bracket (or a ":" in Python and YAML). Between a bracket pair the
    /// closer goes on its own line. Returns the text and where the caret
    /// goes, as an offset into that text.
    public static func newline(in text: NSString, lineStart: Int, caret: Int, after: Int, language: Language,
                               unit preferred: String? = nil) -> (text: String, caret: Int) {
        // The line's indent (bounded: a 636 K line of spaces isn't an indent).
        var e = lineStart
        while e < caret, e - lineStart < 256, space.contains(text.character(at: e)) { e += 1 }
        let indent = text.substring(with: NSRange(location: lineStart, length: e - lineStart))
        // The last non-blank character before the caret.
        var p = caret - 1
        while p >= lineStart, caret - p < 256, space.contains(text.character(at: p)) { p -= 1 }
        let last: unichar? = p >= lineStart && p >= e ? text.character(at: p) : nil
        let next: unichar? = after < text.length ? text.character(at: after) : nil
        var opens = false
        if let last, language != .plain, language != .markdown {
            opens = openers[last] != nil || (last == 58 && (language == .python || language == .yaml)) // ":"
        }
        guard opens, let last else { return ("\n" + indent, 1 + (indent as NSString).length) }
        let unit = indentUnit(lineIndent: indent, language: language, preferred: preferred)
        let inner = "\n" + indent + unit
        if let close = openers[last], next == close {
            return (inner + "\n" + indent, (inner as NSString).length)
        }
        return (inner, (inner as NSString).length)
    }

    /// What typing one character does instead of a plain insert.
    public enum Typing: Equatable, Sendable {
        /// Insert `open` + `close`, caret between.
        case pair(String)
        /// Step over the next character (the closer that's already there).
        case skip
        /// Put `open` and `close` around the selection, which stays selected.
        case wrap(String, String)
    }

    /// `c` typed with `before`/`after` the characters around the caret (or
    /// around the selection); nil: a plain insert. `afterIsAutoClosed`:
    /// the quote after the caret was put there by pairing (a quote steps
    /// over only that one, not a quote that opens the next string).
    public static func typing(_ c: unichar, before: unichar?, after: unichar?, hasSelection: Bool, language: Language,
                              afterIsAutoClosed: Bool = true) -> Typing? {
        guard pairs(in: language) else { return nil }
        let qs = quotes(in: language)
        let isQuote = qs.contains(c)
        let close: unichar? = openers[c] ?? (isQuote ? c : nil)
        if hasSelection {
            guard let close else { return nil }
            return .wrap(String(utf16CodeUnits: [c], count: 1), String(utf16CodeUnits: [close], count: 1))
        }
        if closers.contains(c) || isQuote && afterIsAutoClosed, after == c { return .skip }
        guard let close else { return nil }
        // Only before a space, a closer, punctuation or the line end: typing
        // "(" in front of a word shouldn't add a ")".
        if let after, !(space.contains(after) || after == 10 || closers.contains(after) || [44, 59, 58].contains(after)) {
            return nil
        }
        if isQuote, let before {
            // An apostrophe in a word (don't), or closing a string.
            if Occurrences.isWordUnit(before) || before == c || qs.contains(before) { return nil }
        }
        return .pair(String(utf16CodeUnits: [c, close], count: 2))
    }

    /// Backspace between a just-paired opener and its closer deletes both.
    public static func deletesPair(before: unichar?, after: unichar?, language: Language) -> Bool {
        guard pairs(in: language), let before, let after else { return false }
        if let close = openers[before] { return close == after }
        return quotes(in: language).contains(before) && before == after
    }

    /// The bracket next to `caret` (just before it, else just after) and
    /// its partner, scanning at most `limit` characters; nil if neither
    /// side is a bracket or the partner is too far.
    public static func matchingBracket(in text: NSString, caret: Int, limit: Int = 20_000) -> (NSRange, NSRange)? {
        let n = text.length
        var at = -1
        if caret > 0, caret - 1 < n, isBracket(text.character(at: caret - 1)) { at = caret - 1 } else if caret < n, isBracket(text.character(at: caret)) { at = caret }
        guard at >= 0 else { return nil }
        let c = text.character(at: at)
        let pairsList: [(unichar, unichar)] = [(40, 41), (91, 93), (123, 125)]
        guard let pair = pairsList.first(where: { $0.0 == c || $0.1 == c }) else { return nil }
        let forward = c == pair.0
        var depth = 0
        var i = at
        var steps = 0
        while steps <= limit {
            let ch = text.character(at: i)
            if ch == pair.0 { depth += forward ? 1 : -1 } else if ch == pair.1 { depth += forward ? -1 : 1 }
            if depth == 0 { return (NSRange(location: at, length: 1), NSRange(location: i, length: 1)) }
            i += forward ? 1 : -1
            steps += 1
            if i < 0 || i >= n { return nil }
        }
        return nil
    }

    static func isBracket(_ c: unichar) -> Bool { openers[c] != nil || closers.contains(c) }
}
