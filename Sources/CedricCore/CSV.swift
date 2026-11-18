import Foundation

/// CSV and TSV for the spreadsheet preview: an RFC 4180 parser (quoted
/// fields with embedded delimiters, doubled quotes and line breaks; CRLF,
/// LF or CR line ends) and a delimiter sniffer. It reads UTF-16 code
/// units, so offsets are the editor's (NSString) offsets. Pure and
/// thread-safe: the app parses on a background queue.
public enum CSV {
    /// The delimiters the sniffer picks from.
    public static let candidates: [UInt16] = [44, 9, 59, 124] // , tab ; |

    public struct Table: Sendable, Equatable {
        /// The records, in file order (the first is the header). Ragged
        /// rows are kept as they are; `columnCount` is the widest.
        public var rows: [[String]] = []
        /// Where each record starts (UTF-16 offset in the parsed text).
        public var rowStarts: [Int] = []
        /// The 0-based line each record starts on.
        public var rowLines: [Int] = []
        public var columnCount = 0
        /// Stopped at `maxRows` (or the text was cut short by the caller).
        public var truncated = false
        public var delimiter: UInt16 = 44

        public init() {}
    }

    /// The delimiter for a file: tab for .tsv and .tab, else whichever of
    /// comma, tab, semicolon and pipe splits the first lines most evenly
    /// (quotes respected), comma when nothing does.
    public static func delimiter(for text: NSString, fileName: String? = nil) -> UInt16 {
        if let ext = fileName.map({ ($0 as NSString).pathExtension.lowercased() }) {
            if ext == "tsv" || ext == "tab" { return 9 }
            if ext == "psv" { return 124 }
        }
        // Counts per line, outside quotes, for the first 20 lines (64 K at most).
        let n = min(text.length, 65_536)
        var counts: [[Int]] = Array(repeating: [], count: candidates.count)
        var line = Array(repeating: 0, count: candidates.count)
        var inQuotes = false
        var lines = 0
        var i = 0
        func endLine() {
            if line.contains(where: { $0 > 0 }) || lines == 0 {
                for k in candidates.indices { counts[k].append(line[k]) }
            }
            line = Array(repeating: 0, count: candidates.count)
            lines += 1
        }
        while i < n && lines < 20 {
            let c = text.character(at: i)
            if c == 34 { inQuotes.toggle() }
            else if !inQuotes && (c == 10 || c == 13) {
                if c == 13, i + 1 < n, text.character(at: i + 1) == 10 { i += 1 }
                endLine()
            } else if !inQuotes, let k = candidates.firstIndex(of: c) { line[k] += 1 }
            i += 1
        }
        if i == n && line.contains(where: { $0 > 0 }) { endLine() }
        var best: (score: Double, delim: UInt16) = (0, 44)
        for (k, d) in candidates.enumerated() {
            let cs = counts[k]
            guard !cs.isEmpty, let first = cs.first, first > 0 else { continue }
            // Lines agreeing with the first line's count, then how many fields.
            let agree = Double(cs.filter { $0 == first }.count) / Double(cs.count)
            let score = agree * 1000 + Double(min(first, 999))
            if score > best.score { best = (score, d) }
        }
        return best.delim
    }

    /// Parses `text` (all of it, or the first `maxRows` records). Blank
    /// lines are skipped.
    public static func parse(_ text: NSString, delimiter: UInt16 = 44, maxRows: Int = .max) -> Table {
        let n = text.length
        var buf = [UInt16](repeating: 0, count: n)
        text.getCharacters(&buf, range: NSRange(location: 0, length: n))
        return parse(buf, delimiter: delimiter, maxRows: maxRows)
    }

    public static func parse(_ u: [UInt16], delimiter d: UInt16 = 44, maxRows: Int = .max) -> Table {
        var t = Table()
        t.delimiter = d
        let n = u.count
        var i = 0
        var line = 0
        var field: [UInt16] = []
        field.reserveCapacity(64)
        var row: [String] = []
        while i < n {
            if t.rows.count >= maxRows { t.truncated = true; break }
            let rowStart = i, rowLine = line
            row.removeAll(keepingCapacity: true)
            // One record.
            while true {
                field.removeAll(keepingCapacity: true)
                if i < n, u[i] == 34 {
                    // Quoted: up to the closing quote; "" is a quote.
                    i += 1
                    while i < n {
                        let c = u[i]
                        if c == 34 {
                            if i + 1 < n, u[i + 1] == 34 { field.append(34); i += 2; continue }
                            i += 1
                            break
                        }
                        if c == 10 || (c == 13 && !(i + 1 < n && u[i + 1] == 10)) { line += 1 }
                        field.append(c)
                        i += 1
                    }
                }
                // Unquoted (or what follows a closing quote, kept as is).
                while i < n {
                    let c = u[i]
                    if c == d || c == 10 || c == 13 { break }
                    field.append(c)
                    i += 1
                }
                row.append(String(decoding: field, as: UTF16.self))
                if i >= n { break }
                let c = u[i]
                i += 1
                if c == d { continue }
                // Line end: CRLF, LF or CR.
                if c == 13, i < n, u[i] == 10 { i += 1 }
                line += 1
                break
            }
            if row.count == 1 && row[0].isEmpty && u[rowStart] != 34 { continue } // blank line
            t.rows.append(row)
            t.rowStarts.append(rowStart)
            t.rowLines.append(rowLine)
            t.columnCount = max(t.columnCount, row.count)
        }
        return t
    }

    /// Where field `column` of the record starting at `rowStart` begins
    /// (inside its quotes for a quoted field), for putting the caret
    /// there. Past the last field: the record's end.
    public static func fieldOffset(in text: NSString, rowStart: Int, column: Int, delimiter d: UInt16) -> Int {
        let n = text.length
        var i = max(0, min(rowStart, n))
        var col = 0
        var inQuotes = false
        var fieldStart = i
        while i < n {
            let c = text.character(at: i)
            if c == 34 && (inQuotes || i == fieldStart) {
                if inQuotes, i + 1 < n, text.character(at: i + 1) == 34 { i += 2; continue }
                inQuotes.toggle()
            } else if !inQuotes {
                if c == 10 || c == 13 { break }
                if c == d {
                    if col == column { break }
                    col += 1
                    fieldStart = i + 1
                }
            }
            i += 1
        }
        guard col == column else { return i }
        if fieldStart < n, text.character(at: fieldStart) == 34 { return fieldStart + 1 }
        return fieldStart
    }

    /// Compares two cells for sorting: as numbers when both are, else
    /// in Finder order (numbers inside text by value, case-insensitive).
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let ta = a.trimmingCharacters(in: .whitespaces), tb = b.trimmingCharacters(in: .whitespaces)
        if let x = Double(ta), let y = Double(tb) { return x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame }
        return ta.localizedStandardCompare(tb)
    }

    /// The data rows' order (indexes into `rows`, header excluded) sorted
    /// by `column`. Stable: equal cells keep file order.
    public static func sortedOrder(_ rows: [[String]], column: Int, ascending: Bool) -> [Int] {
        let idx = Array(rows.indices.dropFirst())
        return idx.sorted { i, j in
            let a = column < rows[i].count ? rows[i][column] : ""
            let b = column < rows[j].count ? rows[j][column] : ""
            // Blank cells last, either way.
            let ba = a.allSatisfy(\.isWhitespace), bb = b.allSatisfy(\.isWhitespace)
            if ba != bb { return bb }
            let r = compare(a, b)
            if r == .orderedSame { return i < j }
            return ascending ? r == .orderedAscending : r == .orderedDescending
        }
    }
}
