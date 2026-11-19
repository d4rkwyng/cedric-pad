import Foundation

/// Pack 2: Python. Sources: Ruff (W605, B006, E711, F632) and Python
/// 3.12's SyntaxWarning for invalid escapes. Patterns match only code (the
/// bracket lexer's strings and comments are blanked first).
enum PythonRules {
    static let escapeID = "rules.py.invalid-escape"
    static let mutableDefaultID = "rules.py.mutable-default"
    static let noneCompareID = "rules.py.none-compare"
    static let isLiteralID = "rules.py.is-literal"
    static let printID = "rules.py.print-statement"

    static let python = LintRule.languages(["python"])

    // MARK: PY1 Invalid escapes

    /// After a backslash, in a str: valid escapes. Bytes don't have N, u, U.
    static let validEscapes = Set("\n\\'\"abfnrtv01234567xNuU".unicodeScalars.map(\.value))
    static let validBytesEscapes = Set("\n\\'\"abfnrtv01234567x".unicodeScalars.map(\.value))

    static let invalidEscape = LintRule(escapeID, applies: python) { input in
        guard input.string.contains("\\"), let mask = input.mask else { return nil }
        let s = input.text
        var edits: [(NSRange, String)] = []
        var strings = 0, example = ""
        for sp in mask.spans where sp.kind == .string && !sp.prefix.contains("r") {
            let r = sp.range
            guard r.length >= 2 else { continue }
            let q = s.character(at: r.location)
            guard q == 34 || q == 39, s.character(at: NSMaxRange(r) - 1) == q else { continue }
            // Triple-quoted strings (docstrings) are left alone.
            if r.length >= 6, s.character(at: r.location + 1) == q, s.character(at: r.location + 2) == q { continue }
            let bytes = sp.prefix.contains("b")
            var bad: [Int] = [], good = 0
            var k = r.location + 1
            let end = NSMaxRange(r) - 1
            while k < end {
                if s.character(at: k) == 92 {
                    let next = k + 1 < end ? s.character(at: k + 1) : 0
                    if next == 13 || (bytes ? validBytesEscapes : validEscapes).contains(UInt32(next)) { good += 1 } else { bad.append(k) }
                    k += 2
                    continue
                }
                k += 1
            }
            guard !bad.isEmpty else { continue }
            strings += 1
            if example.isEmpty { example = s.substring(with: NSRange(location: bad[0], length: min(2, end - bad[0]))) }
            if good == 0, !sp.prefix.contains("u") {
                // Nothing but invalid escapes: a raw string means the same.
                edits.append((NSRange(location: r.location - sp.prefix.utf16.count, length: 0), "r"))
            } else {
                for b in bad { edits.append((NSRange(location: b, length: 0), "\\")) }
            }
        }
        guard let fix = RulesHintProvider.spanEdit(s, edits) else { return nil }
        return LintFinding(kind: .fix, title: String(localized: "“\(example)” isn’t a string escape. Make it a raw string?"),
                           detail: String(localized: "Python 3.12 warns about it and a later version will refuse it. A raw string (r\"…\") keeps the backslash for a regular expression; where a string also has real escapes like \\n, the backslash is doubled instead.\(strings > 1 ? String(localized: " \(strings) strings.") : "")"),
                           range: fix.range, replacement: fix.replacement)
    }

    // MARK: PY2 Mutable default arguments

    static let defStart = try! NSRegularExpression(pattern: #"\bdef[ \t]+\w+[ \t]*\("#)
    static let mutableCall = try! NSRegularExpression(pattern: #"\G(list|dict|set|bytearray|defaultdict|OrderedDict|deque|collections\.\w+)[ \t]*\("#)

    // Not in a .pyi stub: its defaults never run.
    static let mutableDefault = LintRule(mutableDefaultID, applies: { l, name in l == "python" && RulesHintProvider.ext(name) != "pyi" }) { input in
        let code = input.codeNS
        guard code.range(of: "def").location != NSNotFound else { return nil }
        let n = code.length
        var hits: [NSRange] = []
        for m in RulesHintProvider.matches(defStart, input.code) {
            var i = NSMaxRange(m.range), depth = 1
            while i < n, depth > 0 {
                let c = code.character(at: i)
                if c == 40 || c == 91 || c == 123 { depth += 1 } else if c == 41 || c == 93 || c == 125 { depth -= 1 }
                // `=` of a default at the parameters' level (not ==, <=, >=, !=).
                else if c == 61, depth == 1, i + 1 < n, code.character(at: i + 1) != 61, ![60, 62, 33, 61].contains(code.character(at: i - 1)) {
                    var j = i + 1
                    while j < n, code.character(at: j) == 32 || code.character(at: j) == 9 { j += 1 }
                    guard j < n else { break }
                    let v = code.character(at: j)
                    if v == 91 || v == 123 {
                        hits.append(NSRange(location: j, length: 1))
                    } else if mutableCall.firstMatch(in: input.code, range: NSRange(location: j, length: n - j)) != nil {
                        hits.append(NSRange(location: j, length: 1))
                    }
                }
                i += 1
            }
        }
        guard let first = hits.first else { return nil }
        // The whole default value, for Show Me.
        var e = first.location + 1, depth = 0
        let open = code.character(at: first.location)
        if open == 91 || open == 123 { depth = 1 } else {
            while e < n, code.character(at: e) != 40 { e += 1 }
            e += 1; depth = 1
        }
        while e < n, depth > 0 {
            let c = code.character(at: e)
            if c == 40 || c == 91 || c == 123 { depth += 1 } else if c == 41 || c == 93 || c == 125 { depth -= 1 }
            e += 1
        }
        return LintFinding(kind: .warning, title: String(localized: "A list or dict as a default is shared by every call."),
                           detail: String(localized: "Python makes the default once, when the function is defined: whatever one call adds to it, the next call sees. Use None as the default and make a new one inside: “if x is None: x = []”.\(RulesHintProvider.andMore(hits.count))"),
                           range: NSRange(location: first.location, length: e - first.location))
    }

    // MARK: PY3 `== None`

    static let noneComparison = try! NSRegularExpression(pattern: #"(?<![=!<>])([!=]=)[ \t]*None\b|\bNone[ \t]*([!=]=)(?!=)"#)

    /// Inside a call's or a subscript's brackets on the line: `filter(x == None)`
    /// (SQLAlchemy) and `df[df.a == None]` (pandas) mean it elementwise.
    static func insideCallOrSubscript(_ code: NSString, line: NSRange, at offset: Int) -> Bool {
        var depth = 0
        var k = offset - 1
        while k >= line.location {
            let c = code.character(at: k)
            if c == 41 || c == 93 || c == 125 { depth += 1 } else if c == 40 || c == 91 || c == 123 {
                if depth == 0 {
                    if c == 123 { return true }
                    var p = k - 1
                    while p >= line.location, code.character(at: p) == 32 { p -= 1 }
                    guard p >= line.location, let u = UnicodeScalar(code.character(at: p)) else { return false }
                    if CharacterSet.alphanumerics.contains(u) || u == "_" || u == ")" || u == "]" {
                        // `if (`, `and (`, `not (`: grouping, not a call.
                        var w = p
                        while w >= line.location, let v = UnicodeScalar(code.character(at: w)), CharacterSet.alphanumerics.contains(v) || v == "_" { w -= 1 }
                        let word = code.substring(with: NSRange(location: w + 1, length: p - w))
                        return !["if", "elif", "while", "and", "or", "not", "return", "assert", "in", "is"].contains(word)
                    }
                    return false
                }
                depth -= 1
            }
            k -= 1
        }
        // A continuation line of a call opened on an earlier line.
        var prev = line.location - 1, d = 0
        while prev >= 0, line.location - prev < 400 {
            let c = code.character(at: prev)
            if c == 41 || c == 93 { d += 1 } else if c == 40 || c == 91 { if d == 0 { return true }; d -= 1 }
            prev -= 1
        }
        return false
    }

    static let noneCompare = LintRule(noneCompareID, applies: python) { input in
        let code = input.codeNS
        guard code.range(of: "None").location != NSNotFound else { return nil }
        var edits: [(NSRange, String)] = []
        for m in RulesHintProvider.matches(noneComparison, input.code) {
            let op = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
            guard let line = RulesHintProvider.lineRange(input.lines, containing: op.location),
                  !insideCallOrSubscript(code, line: line, at: m.range.location) else { continue }
            edits.append((op, code.substring(with: op) == "==" ? "is" : "is not"))
        }
        guard let fix = RulesHintProvider.spanEdit(input.text, edits) else { return nil }
        return LintFinding(kind: .fix, title: String(localized: "Compare with None using “is”. Fix it?"),
                           detail: String(localized: "“== None” calls the object’s own __eq__, which can say anything; “is None” always checks for None.\(RulesHintProvider.andMore(edits.count))"),
                           range: fix.range, replacement: fix.replacement)
    }

    // MARK: PY4 `is` with a literal

    static let isBeforeLiteral = try! NSRegularExpression(pattern: #"\bis([ \t]+not)?[ \t]+(?=[-+]?\d|[rRbBuUfF]{0,2}["'])"#)
    static let isAfterLiteral = try! NSRegularExpression(pattern: #"(["']|\b\d+(\.\d+)?)[ \t]+(is([ \t]+not)?)\b"#)

    static let isLiteral = LintRule(isLiteralID, applies: python) { input in
        let code = input.codeNS
        guard code.range(of: "is").location != NSNotFound else { return nil }
        var edits: [(NSRange, String)] = []
        for m in RulesHintProvider.matches(isBeforeLiteral, input.code) {
            let neg = m.range(at: 1).location != NSNotFound
            let end = neg ? NSMaxRange(m.range(at: 1)) : m.range.location + 2
            edits.append((NSRange(location: m.range.location, length: end - m.range.location), neg ? "!=" : "=="))
        }
        for m in RulesHintProvider.matches(isAfterLiteral, input.code) {
            // A number on the left must be a whole literal, not the end of a name (`x2 is y`).
            let lit = m.range(at: 1)
            if code.character(at: lit.location) != 34, code.character(at: lit.location) != 39, lit.location > 0,
               let u = UnicodeScalar(code.character(at: lit.location - 1)), CharacterSet.letters.contains(u) || u == "_" || u == "." { continue }
            let op = m.range(at: 3)
            if edits.contains(where: { NSIntersectionRange($0.0, op).length > 0 }) { continue }
            edits.append((op, m.range(at: 4).location != NSNotFound ? "!=" : "=="))
        }
        guard let fix = RulesHintProvider.spanEdit(input.text, edits) else { return nil }
        return LintFinding(kind: .fix, title: String(localized: "“is” with a literal compares identity. Use “==”?"),
                           detail: String(localized: "“x is \"a\"” or “x is 0” checks whether they are the same object, which depends on Python’s caching; Python warns about it. “==” compares the values.\(RulesHintProvider.andMore(edits.count))"),
                           range: fix.range, replacement: fix.replacement)
    }

    // MARK: PY5 Python 2 print

    static let printStatement2 = try! NSRegularExpression(pattern: #"(?m)^([ \t]*)print[ \t]+(?=["'\w]|>>)(?!(in|is|and|or|if|else|for|not)\b)"#)

    static let printStatement = LintRule(printID, applies: python) { input in
        let code = input.codeNS
        guard code.range(of: "print").location != NSNotFound else { return nil }
        var hits: [(NSRange, String?)] = []
        for m in RulesHintProvider.matches(printStatement2, input.code) {
            guard let line = RulesHintProvider.lineRange(input.lines, containing: m.range.location) else { continue }
            // Not a continuation line inside brackets opened earlier.
            if openBracketsBefore(code, line.location) { continue }
            let argStart = NSMaxRange(m.range)
            var argEnd = NSMaxRange(line)
            while argEnd > argStart, [32, 9, 13].contains(code.character(at: argEnd - 1)) { argEnd -= 1 }
            let start = NSMaxRange(m.range(at: 1))
            let whole = NSRange(location: start, length: argEnd - start)
            let codeArgs = code.substring(with: NSRange(location: argStart, length: argEnd - argStart))
            var args = input.text.substring(with: NSRange(location: argStart, length: argEnd - argStart))
            var balance = 0
            for u in codeArgs.unicodeScalars { if "([{".unicodeScalars.contains(u) { balance += 1 } else if ")]}".unicodeScalars.contains(u) { balance -= 1 } }
            guard balance == 0, !codeArgs.hasSuffix("\\"), !codeArgs.contains(";") else { hits.append((whole, nil)); continue }
            var tail = ""
            if codeArgs.hasPrefix(">>") {
                // print >>f, x  →  print(x, file=f)
                guard let comma = codeArgs.firstIndex(of: ",") else { hits.append((whole, nil)); continue }
                let cut = codeArgs.utf16.distance(from: codeArgs.utf16.startIndex, to: comma.samePosition(in: codeArgs.utf16)!)
                let ns = args as NSString
                tail = ", file=" + ns.substring(with: NSRange(location: 2, length: cut - 2)).trimmingCharacters(in: .whitespaces)
                args = ns.substring(from: cut + 1)
            }
            args = args.trimmingCharacters(in: .whitespaces)
            // A trailing comma: no newline after it.
            if args.hasSuffix(",") { args.removeLast(); tail += ", end=\" \"" }
            hits.append((whole, "print(" + args + tail + ")"))
        }
        guard let first = hits.first else { return nil }
        let fixable = hits.allSatisfy { $0.1 != nil }
        let fix = fixable ? RulesHintProvider.spanEdit(input.text, hits.map { ($0.0, $0.1!) }) : nil
        return LintFinding(kind: fixable ? .fix : .warning, title: String(localized: "Python 2 print. Make it print(…)?"),
                           detail: String(localized: "In Python 3, print is a function: “print \"hi\"” is a syntax error and the script won’t start.\(RulesHintProvider.andMore(hits.count))"),
                           range: fix?.range ?? first.0, replacement: fix?.replacement)
    }

    /// Sentences where the mask says code: a window that starts (and
    /// maybe ends) inside a docstring longer than itself. Python 3 code has
    /// no backticks and no line ending in “word.”.
    static let prose = try! NSRegularExpression(pattern: #"`|[a-z]{2}\.[ \t]*$"#, options: [.anchorsMatchLines])

    /// Whether a bracket opened before `offset` (in the last few lines) is still open.
    static func openBracketsBefore(_ code: NSString, _ offset: Int) -> Bool {
        var d = 0, k = offset - 1
        while k >= 0, offset - k < 2000 {
            let c = code.character(at: k)
            if c == 41 || c == 93 || c == 125 { d += 1 } else if c == 40 || c == 91 || c == 123 { if d == 0 { return true }; d -= 1 }
            k -= 1
        }
        return false
    }
}

extension LintInput {
    /// Prose outside the masked strings and comments of a Python window.
    var proseInCode: Bool {
        shared("python.prose") {
            !whole && context.textStart > 0 && PythonRules.prose.firstMatch(in: code, range: NSRange(location: 0, length: codeNS.length)) != nil
        }
    }
}
