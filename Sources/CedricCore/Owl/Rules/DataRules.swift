import Foundation

/// Pack 5–6: data files. CSV and TSV (RFC 4180, on the same parser as the
/// table preview, `CSV.swift`).
enum DataRules {
    static let csvQuoteID = "rules.csv.unclosed-quote"
    static let csvRaggedID = "rules.csv.ragged-rows"

    static let csv = LintRule.languages(["csv"])

    /// The parsed table, once per query.
    static func table(_ input: LintInput) -> CSV.Table {
        input.shared("csv.table") { CSV.parse(input.text, dialect: CSV.dialect(for: input.text, fileName: input.fileName)) }
    }

    // MARK: CSV1 A quote that never closes

    static let unclosedQuote = LintRule(csvQuoteID, wholeDocument: true, applies: csv) { input in
        guard input.text.range(of: "\"").location != NSNotFound else { return nil }
        let t = table(input)
        guard let line = t.unclosedQuoteLine, line < input.lines.count else { return nil }
        let r = input.lines[line]
        return LintFinding(kind: .warning, title: String(localized: "A quote on line \(line + 1) never closes."),
                           detail: String(localized: "A field that starts with a quote runs to the next quote, so the rest of the file reads as one field in Excel, Numbers and most CSV readers. Close it, or double a quote inside a field (\"\")."),
                           range: r)
    }

    // MARK: CSV2 Rows with the wrong number of fields

    static let raggedRows = LintRule(csvRaggedID, applies: csv) { input in
        // A window of a longer file may start inside a quoted field: only
        // when it has no quotes at all (then a row is a line).
        let s = input.text
        guard input.whole || s.range(of: "\"").location == NSNotFound else { return nil }
        var t = table(input)
        if !input.whole {
            // The window's first and last lines may be cut short.
            if !t.rows.isEmpty { t.rows.removeFirst(); t.rowStarts.removeFirst(); t.rowLines.removeFirst() }
            if !s.hasSuffix("\n"), !t.rows.isEmpty { t.rows.removeLast(); t.rowStarts.removeLast(); t.rowLines.removeLast() }
        }
        guard t.unclosedQuoteLine == nil else { return nil }
        // Comment lines (`# …`) aren't records.
        let rows = t.rows.indices.filter { i in
            !(t.rows[i].first.map { $0.hasPrefix("#") } ?? false) && !(t.rows[i].count == 1 && t.rows[i][0].isEmpty)
        }
        guard rows.count >= 3 else { return nil }
        var counts: [Int: Int] = [:]
        for i in rows { counts[t.rows[i].count, default: 0] += 1 }
        guard let (mode, modeRows) = counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key < $1.key) }),
              mode >= 2, modeRows >= 3 else { return nil }
        // The majority's count (a header that differs is itself flagged).
        let expected = mode
        let bad = rows.filter { t.rows[$0].count != expected }
        // Mostly ragged: a different format (or not a table), not a mistake.
        guard !bad.isEmpty, bad.count * 5 <= rows.count else { return nil }
        let first = bad[0]
        let line = t.rowLines[first]
        guard line < input.lines.count else { return nil }
        let got = t.rows[first].count
        let more = bad.count > 1 ? String(localized: " \(bad.count) rows are like this.") : ""
        return LintFinding(kind: .warning,
                           title: input.whole ? String(localized: "Row on line \(line + 1) has \(got) fields, not \(expected).")
                               : String(localized: "A row here has \(got) fields, not \(expected)."),
                           detail: String(localized: "The other rows have \(expected) fields: many readers stop at this row or shift its values into other columns. A missing or extra separator, or a value with a separator in it that needs quotes?\(more)"),
                           range: input.lines[line])
    }
}
