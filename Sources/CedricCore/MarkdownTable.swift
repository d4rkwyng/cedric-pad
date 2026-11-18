import Foundation

/// Markdown (GFM) tables: Tab and ⇧Tab move between cells, Return at the
/// end of a row adds a row, and every one of them (and Format › Markdown ›
/// Format Table) lines the whole table's pipes up. Column widths are in
/// display columns (East Asian wide characters and emoji count 2), so
/// CJK tables line up in a monospaced font. A table is the run of lines
/// with a `|` around the caret whose second line is the delimiter row
/// (`| --- | :-: |`); at most `maxLines` lines, else it's left alone. The
/// caller skips fenced code.
public enum MarkdownTable {
    static let maxLines = 2000
    static let maxLine = 10_000

    public enum Alignment: Sendable { case none, left, center, right }

    // MARK: Display width

    /// Columns `s` takes in a monospaced font: 2 for East Asian wide and
    /// fullwidth characters and emoji, 0 for combining marks and format
    /// characters, 1 for the rest.
    public static func displayWidth(_ s: String) -> Int {
        var w = 0
        for ch in s {
            let scalars = ch.unicodeScalars
            guard let first = scalars.first else { continue }
            if scalars.contains(where: { $0.value == 0xFE0F }) || first.properties.isEmojiPresentation || isWide(first.value) {
                w += 2
                continue
            }
            switch first.properties.generalCategory {
            case .nonspacingMark, .enclosingMark, .format, .control: continue
            default: w += 1
            }
        }
        return w
    }

    /// East Asian Width W or F (Unicode 15, the ranges that matter).
    static func isWide(_ v: UInt32) -> Bool {
        switch v {
        case 0x1100...0x115F, 0x231A...0x231B, 0x2329...0x232A, 0x23E9...0x23EC, 0x23F0, 0x23F3, 0x25FD...0x25FE,
             0x2614...0x2615, 0x2648...0x2653, 0x267F, 0x2693, 0x26A1, 0x26AA...0x26AB, 0x26BD...0x26BE, 0x26C4...0x26C5,
             0x26CE, 0x26D4, 0x26EA, 0x26F2...0x26F3, 0x26F5, 0x26FA, 0x26FD, 0x2705, 0x270A...0x270B, 0x2728, 0x274C,
             0x274E, 0x2753...0x2755, 0x2757, 0x2795...0x2797, 0x27B0, 0x27BF, 0x2B1B...0x2B1C, 0x2B50, 0x2B55,
             0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF, 0xA960...0xA97F,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x16FE0...0x18CFF, 0x1B000...0x1B2FF, 0x1F004, 0x1F0CF, 0x1F18E, 0x1F191...0x1F19A, 0x1F200...0x1F251,
             0x1F300...0x1F64F, 0x1F680...0x1F6FF, 0x1F7E0...0x1F7EB, 0x1F90C...0x1F9FF, 0x1FA70...0x1FAFF,
             0x20000...0x2FFFD, 0x30000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    // MARK: Rows

    /// The UTF-16 offsets of the `|`s that separate cells: not escaped
    /// (`\|`) and not inside a code span.
    static func pipes(_ line: String) -> [Int] {
        var out: [Int] = []
        var code = 0
        var escaped = false
        var i = 0
        let u = Array(line.utf16)
        while i < u.count {
            let c = u[i]
            if escaped { escaped = false; i += 1; continue }
            if c == 92 { escaped = true; i += 1; continue }
            if c == 96 {
                var n = 0
                while i + n < u.count, u[i + n] == 96 { n += 1 }
                if code == 0 { code = n } else if code == n { code = 0 }
                i += n
                continue
            }
            if c == 124, code == 0 { out.append(i) }
            i += 1
        }
        return out
    }

    static func isRow(_ line: String) -> Bool {
        guard line.utf16.count <= maxLine else { return false }
        let t = line.drop { $0 == " " || $0 == "\t" }
        if t.hasPrefix(">") { return false }
        return !pipes(line).isEmpty
    }

    static func startsWithPipe(_ line: String) -> Bool { line.drop { $0 == " " || $0 == "\t" }.hasPrefix("|") }

    /// A row's cells, trimmed (the outer pipes don't make empty cells).
    /// Also where each cell's text starts, as a UTF-16 offset in `line`.
    static func cells(_ line: String) -> [(text: String, start: Int)] {
        let u = Array(line.utf16)
        var bounds = pipes(line)
        var from = 0
        if startsWithPipe(line), let first = bounds.first { from = first + 1; bounds.removeFirst() }
        var ends = bounds
        // A trailing pipe closes the last cell; without one the line end does.
        let trailing = u[(bounds.last.map { $0 + 1 } ?? from)...].allSatisfy { $0 == 32 || $0 == 9 }
        if !(trailing && !bounds.isEmpty) { ends.append(u.count) }
        var out: [(String, Int)] = []
        var s = from
        for e in ends {
            var a = s, b = e
            while a < b, u[a] == 32 || u[a] == 9 { a += 1 }
            while b > a, u[b - 1] == 32 || u[b - 1] == 9 { b -= 1 }
            out.append((String(decoding: u[a..<b], as: UTF16.self), a))
            s = e + 1
        }
        return out
    }

    static func alignment(_ cell: String) -> Alignment? {
        let t = cell.trimmingCharacters(in: .whitespaces)
        guard t.count >= 1 else { return nil }
        let left = t.hasPrefix(":"), right = t.hasSuffix(":") && t.count > 1
        let dashes = t.dropFirst(left ? 1 : 0).dropLast(right ? 1 : 0)
        guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
        return left && right ? .center : left ? .left : right ? .right : Alignment.none
    }

    static func isDelimiter(_ line: String) -> Bool {
        guard isRow(line) else { return false }
        let c = cells(line)
        return !c.isEmpty && c.allSatisfy { alignment($0.text) != nil }
    }

    // MARK: Layout

    /// The table's lines lined up: "| a   | b |" with one space of
    /// padding, the delimiter row's dashes as wide as each column (at
    /// least 3) and its colons kept. Also each formatted row's cells'
    /// text starts (UTF-16 offsets). `lines[1]` is the delimiter row.
    static func layout(_ lines: [String]) -> (lines: [String], starts: [[Int]], columns: Int) {
        let indent = String(lines[0].prefix { $0 == " " || $0 == "\t" })
        var rows = lines.map { cells($0).map(\.text) }
        let columns = rows.map(\.count).max() ?? 1
        for k in rows.indices { while rows[k].count < columns { rows[k].append("") } }
        let aligns = rows[1].map { alignment($0) ?? Alignment.none }
        var widths = [Int](repeating: 3, count: columns)
        for (k, row) in rows.enumerated() where k != 1 {
            for (c, cell) in row.enumerated() { widths[c] = max(widths[c], displayWidth(cell)) }
        }
        var out: [String] = []
        var starts: [[Int]] = []
        for (k, row) in rows.enumerated() {
            var line = indent + "|"
            var rowStarts: [Int] = []
            for c in 0..<columns {
                let w = widths[c]
                let a = c < aligns.count ? aligns[c] : Alignment.none
                let cell: String
                if k == 1 {
                    switch a {
                    case .none: cell = String(repeating: "-", count: w)
                    case .left: cell = ":" + String(repeating: "-", count: w - 1)
                    case .right: cell = String(repeating: "-", count: w - 1) + ":"
                    case .center: cell = ":" + String(repeating: "-", count: w - 2) + ":"
                    }
                    rowStarts.append(line.utf16.count + 1)
                    line += " " + cell + " |"
                    continue
                }
                let text = row[c]
                let pad = max(0, w - displayWidth(text))
                let (l, r): (Int, Int)
                switch a {
                case .right: (l, r) = (pad, 0)
                case .center: (l, r) = (pad / 2, pad - pad / 2)
                default: (l, r) = (0, pad)
                }
                rowStarts.append(line.utf16.count + 1 + l)
                line += " " + String(repeating: " ", count: l) + text + String(repeating: " ", count: r) + " |"
            }
            out.append(line)
            starts.append(rowStarts)
        }
        return (out, starts, columns)
    }

    // MARK: The caret's table

    struct Found {
        var region: MarkdownLists.Region
        /// The caret's cell (clamped to the table's columns later) and
        /// how far into its text the caret is.
        var cell: Int
        var offset: Int
        var atRowEnd: Bool
    }

    /// The table around the caret, with or without its delimiter row yet.
    static func find(in text: NSString, selection sel: NSRange) -> Found? {
        guard MarkdownLists.valid(sel, in: text) else { return nil }
        let lineR = text.lineRange(for: NSRange(location: sel.location, length: 0))
        let content = MarkdownLists.lineContent(text, lineR)
        guard NSMaxRange(sel) <= NSMaxRange(content) else { return nil }
        let line = text.substring(with: content)
        guard isRow(line) else { return nil }
        var lines = [line]
        var start = content.location
        var up = 0
        while start > 0, lines.count < maxLines {
            let r = text.lineRange(for: NSRange(location: start - 1, length: 0))
            let s = text.substring(with: MarkdownLists.lineContent(text, r))
            guard isRow(s) else { break }
            lines.insert(s, at: 0)
            start = r.location
            up += 1
        }
        var end = NSMaxRange(lineR)
        var lastEnd = NSMaxRange(content)
        while end < text.length, NSMaxRange(lineR) > NSMaxRange(content), lines.count < maxLines {
            let r = text.lineRange(for: NSRange(location: end, length: 0))
            let c = MarkdownLists.lineContent(text, r)
            let s = text.substring(with: c)
            guard isRow(s) else { break }
            lines.append(s)
            lastEnd = NSMaxRange(c)
            end = NSMaxRange(r)
        }
        guard lines.count < maxLines else { return nil }
        let caretCol = sel.location - content.location
        let cs = cells(line)
        // The cell is the number of pipes before the caret (after a
        // trailing pipe: past the last cell).
        let cell = max(0, pipes(line).filter { $0 < caretCol }.count - (startsWithPipe(line) ? 1 : 0))
        let offset = cell < cs.count ? max(0, min(caretCol - cs[cell].start, cs[cell].text.utf16.count)) : 0
        let rest = (line as NSString).substring(from: caretCol)
        return Found(region: MarkdownLists.Region(range: NSRange(location: start, length: lastEnd - start), lines: lines, index: up),
                     cell: cell, offset: offset, atRowEnd: rest.allSatisfy { $0 == " " || $0 == "\t" })
    }

    static func isTable(_ lines: [String]) -> Bool { lines.count >= 2 && isDelimiter(lines[1]) && !isDelimiter(lines[0]) }

    /// Format › Markdown › Format Table: lines the table up; the caret
    /// stays in its cell.
    public static func format(in text: NSString, selection sel: NSRange) -> TextEdit? {
        guard let f = find(in: text, selection: sel), isTable(f.region.lines) else { return nil }
        let l = layout(f.region.lines)
        let row = f.region.index
        let cell = min(f.cell, l.columns - 1)
        let at = row == 1 ? l.starts[row][cell] : l.starts[row][cell] + min(f.offset, cells(l.lines[row])[cell].text.utf16.count)
        return MarkdownLists.finish(f.region, l.lines, caretLine: row, caretColumn: at)
    }

    /// Tab (forward) or ⇧Tab in a table: lines it up and selects the
    /// next (previous) cell's text, skipping the delimiter row. Tab past
    /// the last cell adds a row. On a lone `| a | b |` header line, Tab
    /// first adds the delimiter row. Nil when the caret isn't in a table.
    public static func tab(in text: NSString, selection sel: NSRange, forward: Bool) -> TextEdit? {
        guard let f = find(in: text, selection: sel) else { return nil }
        var lines = f.region.lines
        var row = f.region.index
        if !isTable(lines) {
            // A header typed on its own: build the delimiter row under it.
            guard forward, lines.count == 1, startsWithPipe(lines[0]), !isDelimiter(lines[0]) else { return nil }
            let n = max(1, cells(lines[0]).count)
            lines.append("|" + String(repeating: " --- |", count: n))
        }
        var lay = layout(lines)
        var cell = min(f.cell, lay.columns)
        if forward {
            cell += 1
            if row == 1 { row = 2; cell = 0 }
            if cell >= lay.columns { row += 1; cell = 0 }
            if row == 1 { row = 2 }
            if row >= lines.count {
                lines.append("|" + String(repeating: "  |", count: lay.columns))
                lay = layout(lines)
                row = lines.count - 1
            }
        } else {
            cell = min(cell, lay.columns) - 1
            if row == 1 { row = 0; cell = lay.columns - 1 }
            if cell < 0 {
                if row == 0 { cell = 0 } else { row -= 1; cell = lay.columns - 1 }
            }
            if row == 1 { row = 0 }
        }
        let start = lay.starts[row][cell]
        let length = cells(lay.lines[row])[cell].text.utf16.count
        return MarkdownLists.finish(f.region, lay.lines, caretLine: row, caretColumn: start, selectionLength: length)
    }

    /// Return in a table row (not before its first character): lines the
    /// table up and goes to the same cell in the row below, adding a row
    /// when this is the last one. Return in an empty last row ends the
    /// table (the row goes). Nil elsewhere, and on the delimiter row.
    public static func newline(in text: NSString, selection sel: NSRange) -> TextEdit? {
        guard sel.length == 0, let f = find(in: text, selection: sel), isTable(f.region.lines) else { return nil }
        let lineStart = text.lineRange(for: NSRange(location: sel.location, length: 0)).location
        var lines = f.region.lines
        let row = f.region.index
        let line = lines[row]
        let lead = line.utf16.prefix { $0 == 32 || $0 == 9 }.count
        guard row != 1, sel.location - lineStart > lead else { return nil }
        if row >= 2, row == lines.count - 1, cells(line).allSatisfy({ $0.text.isEmpty }) {
            lines.removeLast()
            let l = layout(lines)
            return MarkdownLists.finish(f.region, l.lines + [""], caretLine: row, caretColumn: 0)
        }
        var next = row == 0 ? 2 : row + 1
        if next >= lines.count {
            lines.append("|" + String(repeating: "  |", count: layout(lines).columns))
            next = lines.count - 1
        }
        let l = layout(lines)
        // After the row's last pipe: the new row's first cell.
        let cell = f.cell >= l.columns ? 0 : f.cell
        return MarkdownLists.finish(f.region, l.lines, caretLine: next, caretColumn: l.starts[next][cell])
    }
}
