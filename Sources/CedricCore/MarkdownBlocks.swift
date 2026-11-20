import Foundation

/// Format › Markdown's line commands (0.4.0, also the Context Bar's
/// buttons): headings, bulleted and numbered lists, block quotes, fenced
/// code blocks, a table skeleton and image links. Each is a toggle on the
/// selected lines (or the caret's line): it puts the markup on, or takes
/// it off when every line already has it, and returns one `TextEdit` (one
/// undo step) or nil when there is nothing to do. Pure functions of the
/// text and selection; CRLF, LF and CR line endings are all kept as they
/// are, and inserted lines use the text's own ending.
public enum MarkdownBlocks {
    /// More selected lines than this: nothing is done (a beep).
    static let maxLines = 20_000
    /// How far down Code Block looks for the fence it is in (one pass, per use, not per keystroke).
    static let maxScan = 4_000_000

    struct Line {
        /// The line's text, without its line ending.
        var range: NSRange
        var text: String
    }

    /// One change on a line: `remove` UTF-16 units at column `at` replaced by `insert`.
    struct Change {
        var at: Int
        var remove: Int
        var insert: String
    }

    // MARK: Lines

    static func clamped(_ sel: NSRange, in text: NSString) -> NSRange { MarkdownFormat.clamped(sel, in: text) }

    /// The lines the selection touches (a selection that ends at the start
    /// of a line leaves that line out), or nil when there are too many.
    static func lines(_ text: NSString, _ sel: NSRange) -> [Line]? {
        let sel = clamped(sel, in: text)
        var end = NSMaxRange(sel)
        if sel.length > 0, end > sel.location, isLineEnd(text.character(at: end - 1)) {
            end -= 1
            // The \r of a \r\n ending.
            if end > sel.location, text.character(at: end) == 10, text.character(at: end - 1) == 13 { end -= 1 }
        }
        var out: [Line] = []
        var at = sel.location
        while true {
            var start = 0, lineEnd = 0, contentsEnd = 0
            text.getLineStart(&start, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: min(at, text.length), length: 0))
            let r = NSRange(location: start, length: contentsEnd - start)
            out.append(Line(range: r, text: text.substring(with: r)))
            if out.count > maxLines { return nil }
            // The last line (no line ending), or the next line starts past the selection.
            if lineEnd == contentsEnd || lineEnd > end { break }
            at = lineEnd
        }
        return out
    }

    static func isLineEnd(_ c: unichar) -> Bool { c == 10 || c == 13 || c == 0x2028 || c == 0x2029 }

    /// The text's line ending ("\r\n" when its first one is), for inserted lines.
    static func lineEnding(_ text: NSString) -> String {
        let r = text.rangeOfCharacter(from: CharacterSet(charactersIn: "\r\n"))
        guard r.location != NSNotFound else { return "\n" }
        if text.character(at: r.location) == 13 {
            return r.location + 1 < text.length && text.character(at: r.location + 1) == 10 ? "\r\n" : "\r"
        }
        return "\n"
    }

    static func isBlank(_ s: String) -> Bool { s.allSatisfy { $0 == " " || $0 == "\t" } }

    static func utf16(_ s: String) -> Int { s.utf16.count }

    /// Applies one change per line (nil: none) as a single edit. The caret
    /// moves with its text; a selection over several lines becomes the
    /// changed lines.
    static func edit(_ text: NSString, _ lines: [Line], _ changes: [Change?], selection: NSRange) -> TextEdit? {
        guard changes.contains(where: { $0 != nil }), let first = lines.first, let last = lines.last else { return nil }
        let whole = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        var out = ""
        var deltas: [Int] = []
        for (k, line) in lines.enumerated() {
            if k > 0 {
                let gap = NSRange(location: NSMaxRange(lines[k - 1].range), length: line.range.location - NSMaxRange(lines[k - 1].range))
                out += text.substring(with: gap)
            }
            if let c = changes[k] {
                let ns = line.text as NSString
                out += ns.replacingCharacters(in: NSRange(location: c.at, length: c.remove), with: c.insert)
                deltas.append(utf16(c.insert) - c.remove)
            } else {
                out += line.text
                deltas.append(0)
            }
        }
        let sel = clamped(selection, in: text)
        // A selection's start before an inserted marker stays before it.
        func map(_ p: Int, start: Bool = false) -> Int {
            var shift = 0
            for (k, line) in lines.enumerated() {
                let col = p - line.range.location
                if p < line.range.location { break }
                if col <= line.range.length, let c = changes[k] {
                    if col < c.at || (start && col == c.at && c.remove == 0) { return p + shift }
                    if col < c.at + c.remove { return line.range.location + shift + c.at + utf16(c.insert) }
                    return p + shift + deltas[k]
                }
                shift += deltas[k]
            }
            return p + shift
        }
        let newSel: NSRange
        if sel.length > 0, lines.count > 1 {
            newSel = NSRange(location: whole.location, length: utf16(out))
        } else {
            let a = map(sel.location, start: sel.length > 0), b = map(NSMaxRange(sel))
            newSel = NSRange(location: a, length: max(0, b - a))
        }
        return TextEdit(range: whole, replacement: out, selection: newSel)
    }

    /// The lines a toggle looks at: the non-blank ones, or the one line
    /// when that is all there is.
    static func considered(_ lines: [Line]) -> [Int] {
        let k = lines.indices.filter { !isBlank(lines[$0].text) }
        return k.isEmpty && lines.count == 1 ? [0] : k
    }

    // MARK: Headings

    /// An ATX heading's level and the length of its "## " prefix.
    public static func heading(_ s: String) -> (level: Int, prefix: Int)? {
        let u = Array(s.utf16)
        var i = 0
        while i < u.count, i < 3, u[i] == 32 { i += 1 }
        var n = 0
        while i + n < u.count, u[i + n] == 35 { n += 1 } // #
        guard (1...6).contains(n) else { return nil }
        var j = i + n
        guard j == u.count || u[j] == 32 || u[j] == 9 else { return nil }
        while j < u.count, u[j] == 32 || u[j] == 9 { j += 1 }
        return (n, j)
    }

    /// ⌘1–⌘3 (level 1–3), Body (level 0): the selected lines become
    /// headings of `level`; lines that all have it already go back to body
    /// text. Another level is replaced, not stacked.
    public static func heading(_ level: Int, in text: NSString, selection: NSRange) -> TextEdit? {
        guard (0...6).contains(level), let ls = lines(text, selection) else { return nil }
        let idx = considered(ls)
        let allAt = level > 0 && idx.allSatisfy { heading(ls[$0].text)?.level == level }
        let target = allAt ? 0 : level
        var changes = [Change?](repeating: nil, count: ls.count)
        for k in idx {
            let s = ls[k].text
            let old = heading(s)
            let remove = old?.prefix ?? utf16(String(s.prefix { $0 == " " || $0 == "\t" }))
            let insert = target > 0 ? String(repeating: "#", count: target) + " " : ""
            if old?.level == (target > 0 ? target : nil) && remove == utf16(insert) { continue }
            if old == nil && target == 0 { continue }
            changes[k] = Change(at: 0, remove: remove, insert: insert)
        }
        return edit(text, ls, changes, selection: selection)
    }

    // MARK: Lists

    public enum ListKind: Sendable { case bullet, numbered }

    /// Bulleted or numbered list on the selected lines. Lines that are all
    /// such items already stop being a list (marker and checkbox taken off,
    /// the text kept). Otherwise every line becomes an item: plain lines
    /// get a marker after their indent (and block-quote ">"), items of the
    /// other kind change marker and keep their checkbox. A bullet follows
    /// the item just above (or the first bullet selected), else "-";
    /// numbers count on from the item just above at the same indent,
    /// else from 1, per indent level.
    public static func list(_ kind: ListKind, in text: NSString, selection: NSRange) -> TextEdit? {
        guard let ls = lines(text, selection) else { return nil }
        let idx = considered(ls)
        let items = ls.map { MarkdownLists.parse($0.text) }
        func isKind(_ i: MarkdownLists.Item?) -> Bool { i.map { kind == .numbered ? $0.isOrdered : !$0.isOrdered } ?? false }
        var changes = [Change?](repeating: nil, count: ls.count)
        if idx.allSatisfy({ isKind(items[$0]) }) {
            for k in idx {
                guard let it = items[k] else { continue }
                let at = utf16(it.quote + it.indent)
                changes[k] = Change(at: at, remove: utf16(it.prefix) - at, insert: "")
            }
            return edit(text, ls, changes, selection: selection)
        }
        // The item just above the selection (a list being continued).
        var above: MarkdownLists.Item?
        if let first = ls.first, first.range.location > 0 {
            let prev = text.lineRange(for: NSRange(location: first.range.location - 1, length: 0))
            var start = 0, end = 0, contentsEnd = 0
            text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: prev.location, length: 0))
            above = MarkdownLists.parse(text.substring(with: NSRange(location: start, length: contentsEnd - start)))
        }
        let bullet = (kind == .bullet ? [above].compactMap { $0 }.filter { !$0.isOrdered } + idx.compactMap { items[$0] }.filter { !$0.isOrdered } : [])
            .first?.bullet ?? "-"
        let delimiter = ([above].compactMap { $0 } + idx.compactMap { items[$0] }).first { $0.isOrdered }?.delimiter ?? "."
        var counters: [Int: Int] = [:]
        if let a = above, a.isOrdered, let n = a.number { counters[utf16(a.indent)] = n }
        for k in idx {
            let s = ls[k].text
            let it = items[k]
            let (quote, rest) = MarkdownLists.splitQuote(s)
            let indent = it?.indent ?? MarkdownLists.leading(rest)
            let level = utf16(indent)
            counters = counters.filter { $0.key <= level }
            let marker: String
            if kind == .numbered {
                let n = (counters[level] ?? 0) + 1
                counters[level] = n
                marker = "\(n)\(delimiter)"
            } else {
                marker = it.flatMap { $0.isOrdered ? nil : $0.bullet } ?? bullet
            }
            let at = utf16((it?.quote ?? quote) + indent)
            if let it {
                let old = utf16(it.marker + it.gap)
                let new = marker + " "
                if it.marker + it.gap == new { continue }
                changes[k] = Change(at: at, remove: old, insert: new)
            } else {
                changes[k] = Change(at: at, remove: 0, insert: marker + " ")
            }
        }
        return edit(text, ls, changes, selection: selection)
    }

    // MARK: Block quotes

    /// The selected lines go into a block quote ("> "), or come out of
    /// one level of it when every non-blank line is quoted already. Blank
    /// lines between quoted lines get a bare ">" so the quote stays one.
    public static func quote(in text: NSString, selection: NSRange) -> TextEdit? {
        guard let ls = lines(text, selection) else { return nil }
        let idx = considered(ls)
        func quoted(_ s: String) -> (at: Int, len: Int)? {
            let u = Array(s.utf16)
            var i = 0
            while i < u.count, i < 3, u[i] == 32 { i += 1 }
            guard i < u.count, u[i] == 62 else { return nil } // >
            return (i, i + 1 < u.count && u[i + 1] == 32 ? 2 : 1)
        }
        var changes = [Change?](repeating: nil, count: ls.count)
        if idx.allSatisfy({ quoted(ls[$0].text) != nil }) {
            for k in ls.indices {
                guard let q = quoted(ls[k].text) else { continue }
                changes[k] = Change(at: q.at, remove: q.len, insert: "")
            }
        } else {
            let lo = idx.first ?? 0, hi = idx.last ?? 0
            for k in ls.indices where k >= lo && k <= hi {
                let blank = isBlank(ls[k].text)
                changes[k] = Change(at: 0, remove: 0, insert: blank && ls.count > 1 ? ">" : "> ")
            }
        }
        return edit(text, ls, changes, selection: selection)
    }

    // MARK: Code blocks

    /// A fence line's character and length ("```swift": ` and 3).
    static func fence(_ s: String) -> (char: unichar, count: Int)? {
        let u = Array(s.utf16)
        var i = 0
        while i < u.count, i < 3, u[i] == 32 { i += 1 }
        guard i < u.count, u[i] == 96 || u[i] == 126 else { return nil }
        let c = u[i]
        var n = 0
        while i + n < u.count, u[i + n] == c { n += 1 }
        guard n >= 3 else { return nil }
        // A backtick fence's info string has no backticks.
        if c == 96, u[(i + n)...].contains(96) { return nil }
        return (c, n)
    }

    static func closes(_ s: String, _ open: (char: unichar, count: Int)) -> Bool {
        guard let f = fence(s), f.char == open.char, f.count >= open.count else { return false }
        return isBlank(String(s.drop { $0 == " " }.drop { $0 == Character(UnicodeScalar(open.char)!) }))
    }

    /// The line at `location` (its text range) and where the next one starts.
    static func lineAt(_ text: NSString, _ location: Int) -> (range: NSRange, next: Int) {
        var start = 0, end = 0, contentsEnd = 0
        text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: min(location, text.length), length: 0))
        return (NSRange(location: start, length: contentsEnd - start), end)
    }

    /// Fenced code block: the selected lines get "```" lines above and
    /// below (on an empty line, an empty block with the caret inside).
    /// When the selection is a whole fenced block, or lies inside one, its
    /// fence lines go and the code stays.
    public static func codeBlock(in text: NSString, selection: NSRange) -> TextEdit? {
        guard let ls = lines(text, selection), let first = ls.first, let last = ls.last else { return nil }
        // The fence the selection is in (or opens with), scanning from the top.
        var open: (line: NSRange, next: Int, f: (char: unichar, count: Int))?
        // (Past `maxScan` characters down, fences above aren't looked for.)
        var at = first.range.location > maxScan ? first.range.location : 0
        while at < first.range.location {
            let l = lineAt(text, at)
            let s = text.substring(with: l.range)
            if let o = open { if closes(s, o.f) { open = nil } } else if let f = fence(s) { open = (l.range, l.next, f) }
            if l.next <= at { break }
            at = l.next
        }
        if open == nil, ls.count > 1, let f = fence(first.text), closes(last.text, f) {
            let firstNext = lineAt(text, first.range.location).next
            return unwrapFence(text, opener: first.range, openerNext: firstNext, closer: last.range, selection: selection)
        }
        if open == nil, ls.count == 1, let f = fence(first.text) {
            // On an opening fence line: its block.
            open = (first.range, lineAt(text, first.range.location).next, f)
        }
        if let o = open {
            // Its closing line, below the selection (or none: an unclosed block).
            var p = o.next
            var closer: NSRange?
            while p < text.length {
                let l = lineAt(text, p)
                if l.range.location > o.line.location, closes(text.substring(with: l.range), o.f) { closer = l.range; break }
                if l.next <= p { break }
                p = l.next
            }
            return unwrapFence(text, opener: o.line, openerNext: o.next, closer: closer, selection: selection)
        }
        let eol = lineEnding(text)
        let whole = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        let body = text.substring(with: whole)
        let open3 = "```" + eol
        let sel = clamped(selection, in: text)
        let shift = utf16(open3)
        let newSel = sel.length > 0 && ls.count > 1
            ? NSRange(location: whole.location + shift, length: utf16(body))
            : NSRange(location: sel.location + shift, length: sel.length)
        return TextEdit(range: whole, replacement: open3 + body + eol + "```", selection: newSel)
    }

    static func unwrapFence(_ text: NSString, opener: NSRange, openerNext: Int, closer: NSRange?, selection: NSRange) -> TextEdit {
        let sel = clamped(selection, in: text)
        let innerStart = openerNext
        guard let closer else {
            // Unclosed: only the opening line goes.
            let removed = innerStart - opener.location
            let a = max(opener.location, sel.location - removed)
            return TextEdit(range: NSRange(location: opener.location, length: removed), replacement: "",
                            selection: NSRange(location: a, length: max(0, NSMaxRange(sel) - removed - a)))
        }
        let closerNext = lineAt(text, closer.location).next
        var inner = text.substring(with: NSRange(location: innerStart, length: max(0, closer.location - innerStart)))
        let range: NSRange
        if closerNext > NSMaxRange(closer) {
            range = NSRange(location: opener.location, length: closerNext - opener.location)
        } else {
            // The closing fence ends the text: the code's last line ending goes with it.
            range = NSRange(location: opener.location, length: NSMaxRange(closer) - opener.location)
            for end in ["\r\n", "\n", "\r"] where inner.hasSuffix(end) { inner.removeLast(); break }
        }
        let removed = innerStart - opener.location
        let innerLen = utf16(inner)
        func map(_ p: Int) -> Int { min(max(opener.location, p - removed), opener.location + innerLen) }
        let a = map(sel.location), b = map(NSMaxRange(sel))
        return TextEdit(range: range, replacement: inner, selection: NSRange(location: a, length: max(0, b - a)))
    }

    // MARK: Tables

    /// A 3-column table with a header and two empty rows, below the
    /// selection (or in place of an empty caret line), set off by blank
    /// lines; the caret goes in the first header cell.
    public static func insertTable(in text: NSString, selection: NSRange) -> TextEdit? {
        guard let ls = lines(text, selection), let last = ls.last else { return nil }
        let eol = lineEnding(text)
        let row = "|     |     |     |"
        let table = [row, "| --- | --- | --- |", row, row].joined(separator: eol)
        let lineEnd = NSMaxRange(last.range)
        let next = lineAt(text, last.range.location).next
        let nextBlank = next >= text.length || isBlank(text.substring(with: lineAt(text, next).range))
        if ls.count == 1, isBlank(last.text) {
            let prevBlank = last.range.location == 0 || isBlank(text.substring(with: lineAt(text, last.range.location - 1).range))
            let lead = prevBlank ? "" : eol
            let s = lead + table + (nextBlank ? "" : eol)
            return TextEdit(range: last.range, replacement: s, selection: NSRange(location: last.range.location + utf16(lead) + 2, length: 0))
        }
        let s = eol + eol + table + (nextBlank ? "" : eol)
        return TextEdit(range: NSRange(location: lineEnd, length: 0), replacement: s,
                        selection: NSRange(location: lineEnd + 2 * utf16(eol) + 2, length: 0))
    }

    // MARK: Images

    /// The image `![alt](url)` on the selection's line that holds it.
    static func imageSpan(in text: NSString, around sel: NSRange) -> (whole: NSRange, alt: NSRange)? {
        let line = lineAt(text, sel.location).range
        guard NSMaxRange(sel) <= NSMaxRange(line) else { return nil }
        let window = MarkdownFormat.window
        let start = max(line.location, sel.location - window)
        let end = min(NSMaxRange(line), NSMaxRange(sel) + window)
        var i = start
        while i + 1 < end {
            guard text.character(at: i) == 33, text.character(at: i + 1) == 91 else { i += 1; continue } // ![
            var j = i + 2
            while j < end, text.character(at: j) != 93 { j += 1 } // ]
            guard j + 1 < end, text.character(at: j + 1) == 40 else { i = j; continue } // (
            var k = j + 2
            while k < end, text.character(at: k) != 41 { k += 1 } // )
            guard k < end else { return nil }
            let whole = NSRange(location: i, length: k + 1 - i)
            if sel.location >= whole.location, NSMaxRange(sel) <= NSMaxRange(whole) {
                return (whole, NSRange(location: i + 2, length: j - i - 2))
            }
            i = k + 1
        }
        return nil
    }

    /// Image link: the selection becomes `![selection](…)` (the clipboard's
    /// URL, else the caret in the parentheses); a selected URL becomes
    /// `![](url)` with the caret in the brackets; in an image, the image
    /// goes and its alt text stays.
    public static func image(in text: NSString, selection: NSRange, clipboard: String?) -> TextEdit {
        let sel = clamped(selection, in: text)
        if let img = imageSpan(in: text, around: sel) {
            let alt = text.substring(with: img.alt)
            return TextEdit(range: img.whole, replacement: alt, selection: NSRange(location: img.whole.location, length: utf16(alt)))
        }
        let url = clipboard.flatMap { MarkdownFormat.isURL($0) ? $0.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
        let selected = text.substring(with: sel)
        if sel.length > 0, MarkdownFormat.isURL(selected) {
            return TextEdit(range: sel, replacement: "![](\(selected))", selection: NSRange(location: sel.location + 2, length: 0))
        }
        if sel.length > 0 {
            let head = "![\(selected)]("
            if let url {
                let s = head + url + ")"
                return TextEdit(range: sel, replacement: s, selection: NSRange(location: sel.location + utf16(s), length: 0))
            }
            return TextEdit(range: sel, replacement: head + ")", selection: NSRange(location: sel.location + utf16(head), length: 0))
        }
        return TextEdit(range: sel, replacement: "![](\(url ?? ""))", selection: NSRange(location: sel.location + 2, length: 0))
    }
}
