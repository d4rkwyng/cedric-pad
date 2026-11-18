import Foundation

/// Markdown (and YAML) list editing: Return continues a list item, Return
/// on an empty item leaves the list, Tab and ⇧Tab indent and outdent the
/// item with its children, ordered lists renumber, and ⌘↩ toggles task
/// checkboxes. Pure functions from the text and the selection to one
/// `TextEdit` (one undo step). Each looks only at the caret's list: at
/// most `maxUp` lines above and `maxDown` below, and no line longer than
/// `maxLine` (a 636 K-character line is never a list item), so a keystroke
/// costs the same in any size of document.
public enum MarkdownLists {
    static let maxLine = 10_000
    static let maxUp = 500
    static let maxDown = 2000

    /// One list item, split so that `line` puts it back together exactly.
    public struct Item: Equatable, Sendable {
        /// Block-quote prefix ("> ", "> > "), as written.
        public var quote: String
        /// Whitespace before the marker.
        public var indent: String
        /// "-", "*", "+", or the number of an ordered item.
        public var bullet: String
        /// "" for a bullet, "." or ")" for an ordered item.
        public var delimiter: String
        /// Whitespace after the marker.
        public var gap: String
        /// "[ ]", "[x]" or "[X]" for a task item.
        public var task: String?
        public var taskGap: String
        public var content: String

        public var isOrdered: Bool { !delimiter.isEmpty }
        public var number: Int? { isOrdered ? Int(bullet) : nil }
        public var marker: String { bullet + delimiter }
        /// Where nested content starts, in columns from the marker: "- " 2,
        /// "1. " 3 (CommonMark: a gap over 4 counts as 1).
        public var contentWidth: Int { marker.utf16.count + (gap.utf16.count > 4 ? 1 : max(1, gap.utf16.count)) }
        /// Everything before the content.
        public var prefix: String { quote + indent + marker + gap + (task ?? "") + taskGap }
        public var line: String { prefix + content }
    }

    // MARK: Parsing

    /// The block-quote prefix of a line ("> ", "  > > ") and the rest.
    public static func splitQuote(_ line: String) -> (quote: String, rest: Substring) {
        var end = line.startIndex
        var i = line.startIndex
        while true {
            var j = i, spaces = 0
            while j < line.endIndex, line[j] == " ", spaces < 3 { j = line.index(after: j); spaces += 1 }
            guard j < line.endIndex, line[j] == ">" else { break }
            j = line.index(after: j)
            if j < line.endIndex, line[j] == " " { j = line.index(after: j) }
            i = j
            end = j
        }
        return (String(line[..<end]), line[end...])
    }

    static func quoteDepth(_ quote: String) -> Int { quote.reduce(0) { $0 + ($1 == ">" ? 1 : 0) } }

    static func isBlank<S: StringProtocol>(_ s: S) -> Bool { s.allSatisfy { $0 == " " || $0 == "\t" } }

    static func leading<S: StringProtocol>(_ s: S) -> String { String(s.prefix { $0 == " " || $0 == "\t" }) }

    /// The width of leading whitespace in columns (a tab to the next stop).
    static func columns<S: StringProtocol>(_ s: S, tabWidth: Int) -> Int {
        var col = 0
        for c in s {
            if c == "\t" { col = (col / tabWidth + 1) * tabWidth } else if c == " " { col += 1 } else { break }
        }
        return col
    }

    /// The list item on `line`, or nil. In YAML only "- " items count and
    /// there are no block quotes or checkboxes. A marker needs a space
    /// after it ("-" alone may be a setext underline); "- - -" and "* * *"
    /// are thematic breaks, not items.
    public static func parse(_ line: String, yaml: Bool = false) -> Item? {
        guard line.utf16.count <= maxLine else { return nil }
        let (quote, rest): (String, Substring) = yaml ? ("", Substring(line)) : splitQuote(line)
        var i = rest.startIndex
        while i < rest.endIndex, rest[i] == " " || rest[i] == "\t" { i = rest.index(after: i) }
        guard i < rest.endIndex else { return nil }
        let indent = String(rest[rest.startIndex..<i])
        let c = rest[i]
        var bullet = "", delimiter = ""
        var j = rest.index(after: i)
        if c == "-" || (!yaml && (c == "*" || c == "+")) {
            bullet = String(c)
        } else if !yaml, c.isASCII, c.isNumber {
            var k = i
            while k < rest.endIndex, rest[k].isASCII, rest[k].isNumber, rest.distance(from: i, to: k) < 9 { k = rest.index(after: k) }
            guard k < rest.endIndex, rest[k] == "." || rest[k] == ")" else { return nil }
            bullet = String(rest[i..<k])
            delimiter = String(rest[k])
            j = rest.index(after: k)
        } else {
            return nil
        }
        var g = j
        while g < rest.endIndex, rest[g] == " " || rest[g] == "\t" { g = rest.index(after: g) }
        guard g > j else { return nil }
        if delimiter.isEmpty {
            let body = rest[i...].filter { $0 != " " && $0 != "\t" }
            if body.count >= 3, body.allSatisfy({ $0 == c }) { return nil }
        }
        let gap = String(rest[j..<g])
        let after = rest[g...]
        var task: String?
        var taskGap = ""
        var content = after
        if !yaml, after.hasPrefix("[ ]") || after.hasPrefix("[x]") || after.hasPrefix("[X]") {
            let t = after.index(after.startIndex, offsetBy: 3)
            var u = t
            while u < after.endIndex, after[u] == " " { u = after.index(after: u) }
            if u > t || t == after.endIndex {
                task = String(after[..<t])
                taskGap = String(after[t..<u])
                content = after[u...]
            }
        }
        return Item(quote: quote, indent: indent, bullet: bullet, delimiter: delimiter, gap: gap,
                    task: task, taskGap: taskGap, content: String(content))
    }

    // MARK: The caret's list

    struct Region {
        /// Whole lines, without the last line's newline.
        var range: NSRange
        var lines: [String]
        /// The caret's line in `lines`.
        var index: Int
    }

    static func lineContent(_ text: NSString, _ r: NSRange) -> NSRange {
        var len = r.length
        if len > 0, text.character(at: r.location + len - 1) == 10 { len -= 1 }
        return NSRange(location: r.location, length: len)
    }

    /// Whether `s` can be part of a list at quote depth `depth`: an item, a
    /// blank line, or an indented line (an item's continuation).
    static func belongs(_ s: String, depth: Int, yaml: Bool) -> Bool {
        guard s.utf16.count <= maxLine else { return false }
        let (q, rest): (String, Substring) = yaml ? ("", Substring(s)) : splitQuote(s)
        guard quoteDepth(q) == depth else { return false }
        if isBlank(rest) || !leading(rest).isEmpty { return true }
        return parse(s, yaml: yaml) != nil
    }

    static func region(in text: NSString, line lineR: NSRange, depth: Int, yaml: Bool = false) -> Region {
        let first = lineContent(text, lineR)
        var lines = [text.substring(with: first)]
        var start = lineR.location
        var up = 0
        while start > 0, up < maxUp {
            let r = text.lineRange(for: NSRange(location: start - 1, length: 0))
            let s = text.substring(with: lineContent(text, r))
            guard belongs(s, depth: depth, yaml: yaml) else { break }
            lines.insert(s, at: 0)
            start = r.location
            up += 1
        }
        var end = NSMaxRange(lineR)
        var lastEnd = NSMaxRange(first)
        var down = 0
        while end < text.length, NSMaxRange(lineR) > first.location + first.length, down < maxDown {
            let r = text.lineRange(for: NSRange(location: end, length: 0))
            let c = lineContent(text, r)
            let s = text.substring(with: c)
            guard belongs(s, depth: depth, yaml: yaml) else { break }
            lines.append(s)
            lastEnd = NSMaxRange(c)
            end = NSMaxRange(r)
            down += 1
        }
        return Region(range: NSRange(location: start, length: lastEnd - start), lines: lines, index: up)
    }

    /// The edit that turns `region` into `lines`, trimmed to what changed,
    /// with the caret at (`caretLine`, `caretColumn`) in `lines`.
    static func finish(_ region: Region, _ lines: [String], caretLine: Int, caretColumn: Int, selectionLength: Int = 0) -> TextEdit {
        var caret = region.range.location
        for k in 0..<caretLine { caret += lines[k].utf16.count + 1 }
        caret += min(caretColumn, lines[caretLine].utf16.count)
        let old = Array(region.lines.joined(separator: "\n").utf16)
        let new = Array(lines.joined(separator: "\n").utf16)
        var p = 0
        while p < old.count, p < new.count, old[p] == new[p] { p += 1 }
        if p > 0, UTF16.isLeadSurrogate(new[p - 1]) { p -= 1 }
        var s = 0
        while s < old.count - p, s < new.count - p, old[old.count - 1 - s] == new[new.count - 1 - s] { s += 1 }
        if s > 0, UTF16.isTrailSurrogate(new[new.count - s]) { s -= 1 }
        let replacement = String(decoding: new[p..<(new.count - s)], as: UTF16.self)
        return TextEdit(range: NSRange(location: region.range.location + p, length: old.count - p - s),
                        replacement: replacement, selection: NSRange(location: caret, length: selectionLength))
    }

    // MARK: Renumbering

    /// Renumbers the ordered lists in `lines` (one list region): each item
    /// one more than the item before it at its level. The first item of a
    /// top-level list keeps its number; a nested list starts at 1. A list
    /// written "1. 1. 1." (the first two the same) stays that way.
    /// `moved`: a line that just changed level; it never makes its list
    /// a "1. 1. 1." one.
    static func renumber(_ lines: inout [String], tabWidth: Int, yaml: Bool = false, moved: Int? = nil) {
        guard !yaml else { return }
        struct Level { var col: Int; var ordered: Bool; var delimiter: String; var first: Int; var last: Int; var count: Int; var lazy: Bool }
        var stack: [Level] = []
        for k in lines.indices {
            let (_, rest) = splitQuote(lines[k])
            if isBlank(rest) { continue }
            guard var item = parse(lines[k]) else {
                let col = columns(rest, tabWidth: tabWidth)
                while let top = stack.last, top.col >= col { stack.removeLast() }
                continue
            }
            let col = columns(item.indent, tabWidth: tabWidth)
            while let top = stack.last, top.col > col { stack.removeLast() }
            let nested = stack.contains { $0.col < col }
            if var top = stack.last, top.col == col, top.ordered == item.isOrdered, top.delimiter == item.delimiter {
                stack.removeLast()
                if let n = item.number {
                    if top.count == 1, n == top.first, k != moved { top.lazy = true }
                    let want = top.lazy ? top.first : top.last + 1
                    if want != n { item.bullet = String(want); lines[k] = item.line }
                    top.last = want
                }
                top.count += 1
                stack.append(top)
            } else {
                if let top = stack.last, top.col == col { stack.removeLast() }
                var n = item.number ?? 0
                if item.isOrdered, nested || k == moved, n != 1 { n = 1; item.bullet = "1"; lines[k] = item.line }
                stack.append(Level(col: col, ordered: item.isOrdered, delimiter: item.delimiter, first: n, last: n, count: 1, lazy: false))
            }
        }
    }

    // MARK: Return

    /// Return in a list item: a new item below with the same indent and
    /// marker (the next number; an unchecked box after a task item), the
    /// text after the caret moving into it. Return on an empty item
    /// outdents it when nested, else ends the list (the marker goes). In a
    /// block quote with no list, the "> " carries on. YAML: "- " items
    /// carry on; "- key: value" continues the mapping under the key.
    /// Nil: not in a list (Return does what it always did).
    public static func newline(in text: NSString, selection sel: NSRange, language: Language,
                               tabWidth: Int = 4, useTabs: Bool = false) -> TextEdit? {
        let yaml = language == .yaml
        guard language == .markdown || yaml, sel.location <= text.length else { return nil }
        let lineR = text.lineRange(for: NSRange(location: sel.location, length: 0))
        let content = lineContent(text, lineR)
        guard NSMaxRange(sel) <= NSMaxRange(content), content.length <= maxLine else { return nil }
        let line = text.substring(with: content)
        let caretCol = sel.location - content.location
        let afterCol = NSMaxRange(sel) - content.location
        let ns = line as NSString
        let tail = ns.substring(from: afterCol)

        guard let item = parse(line, yaml: yaml) else {
            // A block quote without a list: carry the "> " on; an empty one ends the quote.
            guard !yaml else { return nil }
            let (q, rest) = splitQuote(line)
            guard !q.isEmpty, caretCol >= q.utf16.count else { return nil }
            if isBlank(rest), isBlank(tail) {
                return TextEdit(range: content, replacement: "", selection: NSRange(location: content.location, length: 0))
            }
            let insert = "\n" + q
            return TextEdit(range: sel, replacement: insert, selection: NSRange(location: sel.location + (insert as NSString).length, length: 0))
        }
        let markerEnd = (item.quote + item.indent + item.marker + item.gap).utf16.count
        guard caretCol >= markerEnd else { return nil }

        if isBlank(item.content), isBlank(tail) {
            // An empty item: outdent it (nested), else end the list.
            if yaml {
                return TextEdit(range: content, replacement: item.indent, selection: NSRange(location: content.location + item.indent.utf16.count, length: 0))
            }
            if columns(item.indent, tabWidth: tabWidth) > 0,
               let e = shiftItem(in: text, selection: NSRange(location: NSMaxRange(content), length: 0), right: false,
                                 useTabs: useTabs, tabWidth: tabWidth) {
                return e
            }
            return TextEdit(range: content, replacement: item.quote, selection: NSRange(location: content.location + item.quote.utf16.count, length: 0))
        }

        if yaml {
            let head = ns.substring(to: caretCol).trimmingCharacters(in: .whitespaces)
            if head.hasSuffix(":") { return nil } // AutoEdit: one step in
            if item.content.contains(": ") {
                let insert = "\n" + item.indent + String(repeating: " ", count: item.contentWidth)
                return TextEdit(range: sel, replacement: insert, selection: NSRange(location: sel.location + (insert as NSString).length, length: 0))
            }
        }

        let gap = item.gap.contains("\t") ? item.gap : String(repeating: " ", count: max(1, min(4, item.gap.utf16.count)))
        let reg = item.isOrdered ? region(in: text, line: lineR, depth: quoteDepth(item.quote)) : nil
        var bullet = item.bullet
        if let n = item.number {
            let lazy = reg.map { isLazy($0.lines, at: $0.index, tabWidth: tabWidth) } ?? false
            bullet = String(lazy ? n : n + 1)
        }
        let prefix = item.quote + item.indent + bullet + item.delimiter + gap + (item.task != nil ? "[ ] " : "")
        guard let r = reg else {
            let insert = "\n" + prefix
            return TextEdit(range: sel, replacement: insert, selection: NSRange(location: sel.location + (insert as NSString).length, length: 0))
        }
        var lines = r.lines
        lines[r.index] = ns.substring(to: caretCol)
        lines.insert(prefix + tail, at: r.index + 1)
        renumber(&lines, tabWidth: tabWidth)
        // The new line's prefix may have been renumbered: the caret goes after it.
        let newPrefix = parse(lines[r.index + 1]).map { $0.prefix.utf16.count } ?? prefix.utf16.count
        return finish(r, lines, caretLine: r.index + 1, caretColumn: newPrefix)
    }

    /// Whether the ordered item at `k` is in a "1. 1. 1." list: its
    /// sibling just above or below has the same number.
    static func isLazy(_ lines: [String], at k: Int, tabWidth: Int) -> Bool {
        guard let item = parse(lines[k]), let n = item.number else { return false }
        let col = columns(item.indent, tabWidth: tabWidth)
        func sibling(_ step: Int) -> Int? {
            var j = k + step
            while j >= 0, j < lines.count {
                let (_, rest) = splitQuote(lines[j])
                if !isBlank(rest) {
                    let c = columns(rest, tabWidth: tabWidth)
                    if c < col { return nil }
                    if c == col { return parse(lines[j])?.number }
                }
                j += step
            }
            return nil
        }
        return sibling(-1) == n || sibling(1) == n
    }

    // MARK: Tab and Shift-Tab

    /// Tab (right) or ⇧Tab in a list item: the item and its children move
    /// one level in (under the item above it, by that item's content
    /// width: 2 under "- ", 3 under "1. "; a tab where the list is
    /// indented with tabs) or out (to its parent's column), then the list
    /// renumbers. Nil when the caret isn't on a list item, or it can't move
    /// (the first item of a list has nothing to go under; a top-level item
    /// can't go further out).
    public static func shiftItem(in text: NSString, selection sel: NSRange, right: Bool, useTabs: Bool = false, tabWidth: Int = 4) -> TextEdit? {
        guard sel.location <= text.length else { return nil }
        let lineR = text.lineRange(for: NSRange(location: sel.location, length: 0))
        let content = lineContent(text, lineR)
        guard NSMaxRange(sel) <= NSMaxRange(content) else { return nil }
        let line = text.substring(with: content)
        guard let item = parse(line) else { return nil }
        let r = region(in: text, line: lineR, depth: quoteDepth(item.quote))
        var lines = r.lines
        let k = r.index
        let col = columns(item.indent, tabWidth: tabWidth)
        let tabs = useTabs || item.indent.contains("\t")
        // The item's children: the deeper lines below it.
        var last = k
        var j = k + 1
        while j < lines.count {
            let (_, rest) = splitQuote(lines[j])
            if isBlank(rest) { j += 1; continue }
            guard columns(rest, tabWidth: tabWidth) > col else { break }
            last = j
            j += 1
        }
        let target: Int
        if right {
            var sibling: Item?
            var p = k - 1
            while p >= 0 {
                let (_, rest) = splitQuote(lines[p])
                if !isBlank(rest) {
                    let c = columns(rest, tabWidth: tabWidth)
                    if c < col { break }
                    if c == col { sibling = parse(lines[p]); break }
                }
                p -= 1
            }
            guard let sibling else { return nil }
            target = col + (tabs ? tabWidth : sibling.contentWidth)
        } else {
            guard col > 0 else { return nil }
            var parent = 0
            var p = k - 1
            while p >= 0 {
                if let it = parse(lines[p]) {
                    let c = columns(it.indent, tabWidth: tabWidth)
                    if c < col { parent = c; break }
                }
                p -= 1
            }
            target = parent
        }
        let delta = target - col
        for m in k...last {
            let (q, rest) = splitQuote(lines[m])
            if isBlank(rest) { continue }
            let ws = leading(rest)
            let c = columns(ws, tabWidth: tabWidth)
            let n = max(0, c + delta)
            let indent = tabs ? String(repeating: "\t", count: n / tabWidth) + String(repeating: " ", count: n % tabWidth)
                              : String(repeating: " ", count: n)
            lines[m] = q + indent + String(rest.dropFirst(ws.count))
        }
        let oldPrefix = item.prefix.utf16.count
        renumber(&lines, tabWidth: tabWidth, moved: k)
        let newPrefix = parse(lines[k]).map { $0.prefix.utf16.count } ?? oldPrefix
        let caretCol = sel.location - content.location
        let col2 = caretCol >= oldPrefix ? caretCol - oldPrefix + newPrefix : newPrefix
        return finish(r, lines, caretLine: k, caretColumn: col2, selectionLength: caretCol >= oldPrefix ? sel.length : 0)
    }

    // MARK: Checkboxes

    /// ⌘↩: on every line the selection touches, "[ ]" becomes "[x]" and
    /// back; a list item without a box gets "[ ] "; a plain line becomes
    /// "- [ ] line". Blank lines are left alone. Nil when nothing changes.
    public static func toggleTasks(in text: NSString, selection sel: NSRange) -> TextEdit? {
        let block = LineOperations.lineBlock(sel, in: text)
        guard block.length <= 1_000_000 else { return nil }
        let body = text.substring(with: lineContent(text, block))
        var lines = body.components(separatedBy: "\n")
        var changed = false
        var caretShift = 0
        let caretCol = sel.location - block.location
        for k in lines.indices {
            let line = lines[k]
            let (q, rest) = splitQuote(line)
            if isBlank(rest) { continue }
            var at = 0, delta = 0
            if var item = parse(line) {
                if let t = item.task {
                    item.task = t == "[ ]" ? "[x]" : "[ ]"
                } else {
                    at = (item.quote + item.indent + item.marker + item.gap).utf16.count
                    item.task = "[ ]"
                    item.taskGap = " "
                    delta = 4
                }
                lines[k] = item.line
            } else {
                at = (q + leading(rest)).utf16.count
                lines[k] = q + leading(rest) + "- [ ] " + String(rest.dropFirst(leading(rest).count))
                delta = 6
            }
            changed = true
            if k == 0, caretCol >= at { caretShift = delta }
        }
        guard changed else { return nil }
        let r = Region(range: lineContent(text, block), lines: body.components(separatedBy: "\n"), index: 0)
        if sel.length == 0 { return finish(r, lines, caretLine: 0, caretColumn: caretCol + caretShift) }
        var e = finish(r, lines, caretLine: 0, caretColumn: 0)
        let newLength = lines.joined(separator: "\n").utf16.count
        e.selection = NSRange(location: block.location, length: newLength)
        return e
    }

    // MARK: Fences

    /// Whether line `line` is inside a ``` or ~~~ fence (or is one of its
    /// fence lines), counting fences from the top. Looks at no more than
    /// `limit` lines; past that it answers false.
    public static func isInFence(_ text: NSString, index: LineIndex, line: Int, limit: Int = 200_000) -> Bool {
        guard line < index.lineCount, line <= limit else { return false }
        var open: unichar = 0
        var openLength = 0
        for l in 0...line {
            let start = index.starts[l]
            let len = index.lineLength(l)
            var i = start, sp = 0
            while sp < 4, i < start + len, text.character(at: i) == 32 { i += 1; sp += 1 }
            guard sp <= 3, i < start + len else { if l == line { return open != 0 }; continue }
            let c = text.character(at: i)
            guard c == 96 || c == 126 else { if l == line { return open != 0 }; continue }
            var run = 0
            while i + run < start + len, text.character(at: i + run) == c { run += 1 }
            guard run >= 3 else { if l == line { return open != 0 }; continue }
            if open == 0 {
                open = c
                openLength = run
                if l == line { return true }
            } else if c == open, run >= openLength {
                open = 0
                if l == line { return true }
            } else if l == line {
                return true
            }
        }
        return open != 0
    }
}
