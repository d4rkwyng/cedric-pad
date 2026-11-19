import Foundation

/// Pack 5–6: data files. CSV and TSV (RFC 4180, on the same parser as the
/// table preview, `CSV.swift`), and SQL (SQLFluff's CV05; UPDATE/DELETE
/// without WHERE is our own), matched only in code (`CodeMask.scanSQL`).
enum DataRules {
    static let csvQuoteID = "rules.csv.unclosed-quote"
    static let csvRaggedID = "rules.csv.ragged-rows"
    static let sqlNullID = "rules.sql.null-compare"
    static let sqlNoWhereID = "rules.sql.no-where"

    static let sql = LintRule.languages(["sql"])

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

    // MARK: SQ1 `= NULL`

    static let nullCompare = try! NSRegularExpression(pattern: #"(!=|<>|(?<![<>!:=])=)[ \t]*(NULL)\b"#, options: .caseInsensitive)
    static let sqlKeyword = try! NSRegularExpression(pattern: #"\b(WHERE|ON|HAVING|WHEN|AND|OR|IF|WHILE|NOT(?![ \t]+NULL\b)|SET|DECLARE|SELECT|VALUES|DEFAULT|UPDATE|CREATE|ALTER|PROCEDURE|PROC|FUNCTION|RETURNS|BEGIN|THEN|ELSE|CASE|BY|LIMIT|PRAGMA|EXEC|EXECUTE|CALL|AS)\b"#, options: .caseInsensitive)
    /// After these, `x = NULL` is a comparison (always unknown, never true).
    static let conditionKeywords: Set<String> = ["WHERE", "ON", "HAVING", "WHEN", "AND", "OR", "IF", "WHILE", "NOT"]

    static let nullComparison = LintRule(sqlNullID, applies: sql) { input in
        let code = input.codeNS
        guard code.range(of: "null", options: .caseInsensitive).location != NSNotFound else { return nil }
        // SET ANSI_NULLS OFF: SQL Server then does compare with = NULL.
        if code.range(of: "ANSI_NULLS OFF", options: .caseInsensitive).location != NSNotFound { return nil }
        var edits: [(NSRange, String)] = []
        for m in RulesHintProvider.matches(nullCompare, input.code) {
            // The keyword this comparison belongs to: the last one before it
            // in the same statement (SET a = NULL assigns; WHERE a = NULL compares).
            var from = m.range.location
            let stop = max(0, m.range.location - 600)
            while from > stop, code.character(at: from - 1) != 59 { from -= 1 }
            let head = NSRange(location: from, length: m.range.location - from)
            guard let kw = sqlKeyword.matches(in: input.code, range: head).last else { continue }
            guard conditionKeywords.contains(code.substring(with: kw.range).uppercased()) else { continue }
            let op = code.substring(with: m.range(at: 1))
            let null = code.substring(with: m.range(at: 2))
            let lower = null == "null"
            let rep = op == "=" ? (lower ? "is null" : "IS NULL") : (lower ? "is not null" : "IS NOT NULL")
            edits.append((m.range, rep))
        }
        guard let first = edits.first, let fix = RulesHintProvider.spanEdit(input.text, edits) else { return nil }
        let isNot = first.1.uppercased().contains("NOT")
        return LintFinding(kind: .fix,
                           title: isNot ? String(localized: "“<> NULL” is never true. Use IS NOT NULL?") : String(localized: "“= NULL” is never true. Use IS NULL?"),
                           detail: String(localized: "Comparing with NULL gives NULL (unknown), so the row is never matched, with = and with <> alike. IS NULL and IS NOT NULL are the tests that work.\(RulesHintProvider.andMore(edits.count))"),
                           range: fix.range, replacement: fix.replacement)
    }

    // MARK: SQ2 UPDATE / DELETE without WHERE

    static let firstWords = try! NSRegularExpression(pattern: #"^\s*(\w+)(?:\s+(\w+))?"#)
    static let wordWhere = try! NSRegularExpression(pattern: #"\b(WHERE|JOIN|LIMIT|TOP)\b|\bCURRENT\s+OF\b"#, options: .caseInsensitive)
    static let goLine = try! NSRegularExpression(pattern: #"(?im)^[ \t]*GO[ \t]*$"#)

    static let noWhere = LintRule(sqlNoWhereID, applies: sql) { input in
        let code = input.codeNS, str = input.code
        guard code.range(of: "update", options: .caseInsensitive).location != NSNotFound
                || code.range(of: "delete", options: .caseInsensitive).location != NSNotFound else { return nil }
        // Statements: split at ; and at GO lines; each ends there (or at the end of the whole file).
        var ends: [Int] = []
        var k = 0
        while true {
            let r = code.range(of: ";", options: [], range: NSRange(location: k, length: code.length - k))
            if r.location == NSNotFound { break }
            ends.append(r.location)
            k = r.location + 1
        }
        for m in RulesHintProvider.matches(goLine, str) { ends.append(m.range.location) }
        ends.sort()
        var hits: [(NSRange, String)] = []
        var start = 0
        let partialStart = !input.whole && input.context.textStart > 0
        for (i, end) in (ends + (input.whole ? [code.length] : [])).enumerated() {
            defer { start = end + 1 }
            guard end > start, !(i == 0 && partialStart) else { continue }
            let seg = NSRange(location: start, length: end - start)
            guard let w = firstWords.firstMatch(in: str, options: .anchored, range: seg) else { continue }
            let verb = code.substring(with: w.range(at: 1)).uppercased()
            guard verb == "DELETE" || verb == "UPDATE" else { continue }
            let second = w.range(at: 2).location == NSNotFound ? "" : code.substring(with: w.range(at: 2)).uppercased()
            if verb == "UPDATE", second == "STATISTICS" || second.isEmpty { continue }
            if wordWhere.firstMatch(in: str, range: seg) != nil { continue }
            let line = RulesHintProvider.lineRange(input.lines, containing: w.range(at: 1).location) ?? w.range(at: 1)
            let from = w.range(at: 1).location
            hits.append((NSRange(location: from, length: NSMaxRange(line) - from), verb))
        }
        guard let first = hits.first else { return nil }
        return LintFinding(kind: .warning,
                           title: first.1 == "DELETE" ? String(localized: "DELETE with no WHERE: it removes every row.")
                               : String(localized: "UPDATE with no WHERE: it changes every row."),
                           detail: String(localized: "The statement \(input.at(first.0.location)) has no WHERE clause, so it applies to the whole table. If that’s meant, fine; if not, add the WHERE before running it.\(RulesHintProvider.andMore(hits.count))"),
                           range: first.0)
    }
}
