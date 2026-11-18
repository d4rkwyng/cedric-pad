import Foundation

/// Format › Markdown: bold, italic, strikethrough and inline code wrap the
/// selection in their markers, or take them off when it already has them
/// (so ⌘I on `*word*` doesn't stack a second pair); ⌘K makes a link.
/// Pure functions from the text and selection to one `TextEdit`. They
/// look only at the selection and, with none, the caret's line (at most
/// `window` characters either side).
public enum MarkdownFormat {
    public enum Style: String, CaseIterable, Sendable {
        case bold, italic, strikethrough, code

        public var marker: String {
            switch self {
            case .bold: return "**"
            case .italic: return "*"
            case .strikethrough: return "~~"
            case .code: return "`"
            }
        }

        /// The marker characters that count as this style ("_" for
        /// italic and bold too).
        var chars: [unichar] {
            switch self {
            case .bold, .italic: return [42, 95] // * _
            case .strikethrough: return [126] // ~
            case .code: return [96] // `
            }
        }

        /// Whether a run of `n` marker characters carries this style
        /// ("***" is bold and italic).
        func matches(run n: Int) -> Bool {
            switch self {
            case .bold: return n == 2 || n == 3
            case .italic: return n == 1 || n == 3
            case .strikethrough: return n == 2
            case .code: return n == 1
            }
        }
    }

    static let window = 4096

    /// How many `c` are just before (`step` −1) or from (`step` +1) `at`, up to 3.
    static func run(_ text: NSString, at: Int, step: Int, of c: unichar) -> Int {
        var n = 0
        var i = step < 0 ? at - 1 : at
        while n < 4, i >= 0, i < text.length, text.character(at: i) == c { n += 1; i += step }
        return n
    }

    /// Toggles `style` on the selection, or at the caret.
    public static func toggle(_ style: Style, in text: NSString, selection sel: NSRange) -> TextEdit {
        let m = style.marker
        let len = (m as NSString).length
        if sel.length > 0 {
            // Leading and trailing spaces stay outside the markers.
            var a = sel.location, b = NSMaxRange(sel)
            while a < b, isSpace(text.character(at: a)) { a += 1 }
            while b > a, isSpace(text.character(at: b - 1)) { b -= 1 }
            if a == b { a = sel.location; b = NSMaxRange(sel) }
            let core = NSRange(location: a, length: b - a)
            // The selection includes its markers: take them off.
            for c in style.chars {
                let lead = run(text, at: a, step: 1, of: c), trail = run(text, at: b, step: -1, of: c)
                if core.length >= 2 * len + 1, lead == trail, style.matches(run: lead) {
                    let inner = NSRange(location: a + len, length: core.length - 2 * len)
                    return TextEdit(range: core, replacement: text.substring(with: inner), selection: NSRange(location: a, length: inner.length))
                }
            }
            // The markers are just outside it.
            for c in style.chars {
                let before = run(text, at: a, step: -1, of: c), after = run(text, at: b, step: 1, of: c)
                if before == after, style.matches(run: before) {
                    let outer = NSRange(location: a - len, length: core.length + 2 * len)
                    return TextEdit(range: outer, replacement: text.substring(with: core), selection: NSRange(location: a - len, length: core.length))
                }
            }
            return TextEdit(range: core, replacement: m + text.substring(with: core) + m,
                            selection: NSRange(location: a + len, length: core.length))
        }
        let caret = sel.location
        // Between an empty pair: take it away.
        for c in style.chars {
            let before = run(text, at: caret, step: -1, of: c), after = run(text, at: caret, step: 1, of: c)
            if before == after, before >= len, style.matches(run: before) {
                return TextEdit(range: NSRange(location: caret - len, length: 2 * len), replacement: "",
                                selection: NSRange(location: caret - len, length: 0))
            }
        }
        // Inside a span with this style on the caret's line: unwrap it.
        if let (open, close) = span(style, in: text, around: caret) {
            let inner = NSRange(location: open + len, length: close - open - len)
            let newCaret = min(max(caret - len, open), open + inner.length)
            return TextEdit(range: NSRange(location: open, length: close + len - open), replacement: text.substring(with: inner),
                            selection: NSRange(location: newCaret, length: 0))
        }
        return TextEdit(range: sel, replacement: m + m, selection: NSRange(location: caret + len, length: 0))
    }

    static func isSpace(_ c: unichar) -> Bool { c == 32 || c == 9 || c == 10 }

    /// The span of `style` on the caret's line holding the caret: the
    /// opening marker's offset and the closing marker's offset.
    static func span(_ style: Style, in text: NSString, around caret: Int) -> (Int, Int)? {
        let line = text.lineRange(for: NSRange(location: caret, length: 0))
        let start = max(line.location, caret - window)
        let end = min(NSMaxRange(line), caret + window)
        // Not "_": it joins words (snake_case) more often than it italicises.
        for c in style.chars where c != 95 {
            var marks: [Int] = []
            var i = start
            while i < end {
                guard text.character(at: i) == c else { i += 1; continue }
                var n = 0
                while i + n < end, text.character(at: i + n) == c { n += 1 }
                if style.matches(run: n) { marks.append(i) }
                i += n
            }
            var k = 0
            let len = (style.marker as NSString).length
            while k + 1 < marks.count {
                let open = marks[k], close = marks[k + 1]
                // A run of 3 holds italic and bold: pick the part for this style.
                let o = open, cl = close + (run(text, at: close, step: 1, of: c) - len)
                if caret >= o, caret <= cl + len { return (o, cl) }
                k += 2
            }
        }
        return nil
    }

    // MARK: Links

    /// Whether `s` is a link target worth making a link of: one line,
    /// no spaces, with a scheme (http, https, ftp, mailto, file).
    public static func isURL(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.utf16.count < 2048, t.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let u = URL(string: t), let scheme = u.scheme?.lowercased() else { return false }
        switch scheme {
        case "http", "https", "ftp": return u.host != nil
        case "mailto": return t.count > 7
        case "file": return true
        default: return false
        }
    }

    /// ⌘K. With the caret or selection in a link `[text](url)`, the link
    /// goes and its text stays. A selected URL becomes `[](url)` with the
    /// caret in the brackets. Other selected text becomes `[text](url)`:
    /// `url` from the clipboard if it holds one (caret after the link),
    /// else empty with the caret in it. No selection: `[](…)`, caret in
    /// the brackets.
    public static func link(in text: NSString, selection sel: NSRange, clipboard: String?) -> TextEdit {
        if let l = linkSpan(in: text, around: sel) {
            let inner = text.substring(with: l.text)
            return TextEdit(range: l.whole, replacement: inner, selection: NSRange(location: l.whole.location, length: (inner as NSString).length))
        }
        let url = clipboard.flatMap { isURL($0) ? $0.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
        let selected = text.substring(with: sel)
        if sel.length > 0, isURL(selected) {
            return TextEdit(range: sel, replacement: "[](\(selected))", selection: NSRange(location: sel.location + 1, length: 0))
        }
        if sel.length > 0 {
            let head = "[\(selected)]("
            if let url {
                let s = head + url + ")"
                return TextEdit(range: sel, replacement: s, selection: NSRange(location: sel.location + (s as NSString).length, length: 0))
            }
            return TextEdit(range: sel, replacement: head + ")", selection: NSRange(location: sel.location + (head as NSString).length, length: 0))
        }
        return TextEdit(range: sel, replacement: "[](\(url ?? ""))", selection: NSRange(location: sel.location + 1, length: 0))
    }

    /// The inline link `[text](url)` on the selection's line that holds
    /// the selection.
    static func linkSpan(in text: NSString, around sel: NSRange) -> (whole: NSRange, text: NSRange)? {
        let line = text.lineRange(for: NSRange(location: sel.location, length: 0))
        guard NSMaxRange(sel) <= NSMaxRange(line) else { return nil }
        let start = max(line.location, sel.location - window)
        let end = min(NSMaxRange(line), NSMaxRange(sel) + window)
        var i = start
        while i < end {
            guard text.character(at: i) == 91 else { i += 1; continue } // [
            var j = i + 1
            while j < end, text.character(at: j) != 93, text.character(at: j) != 91 { j += 1 } // ]
            guard j + 1 < end, text.character(at: j) == 93, text.character(at: j + 1) == 40 else { i = j; continue } // ](
            var k = j + 2
            while k < end, text.character(at: k) != 41 { k += 1 } // )
            guard k < end else { return nil }
            // ![…](…) is an image, not a link: left alone.
            let whole = NSRange(location: i, length: k + 1 - i)
            if sel.location >= whole.location, NSMaxRange(sel) <= NSMaxRange(whole), !(i > start && text.character(at: i - 1) == 33) {
                return (whole, NSRange(location: i + 1, length: j - i - 1))
            }
            i = k + 1
        }
        return nil
    }
}
