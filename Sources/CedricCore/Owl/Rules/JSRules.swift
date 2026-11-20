import Foundation

/// Pack 3: JavaScript and TypeScript. Sources: ESLint's recommended set
/// (no-debugger, use-isnan, valid-typeof). Patterns match only code.
enum JSRules {
    static let debuggerID = "rules.js.debugger"
    static let nanID = "rules.js.nan-compare"
    static let typeofID = "rules.js.typeof-typo"

    static let js = LintRule.languages(["javascript", "typescript"])

    // MARK: JS1 `debugger` left in

    static let debuggerWord = try! NSRegularExpression(pattern: #"\bdebugger\b"#)

    static let debuggerLeftIn = LintRule(debuggerID, applies: js) { input in
        let code = input.codeNS
        guard code.range(of: "debugger").location != NSNotFound else { return nil }
        let n = code.length
        var edits: [(NSRange, String)] = []
        for m in RulesHintProvider.matches(debuggerWord, input.code) {
            var p = m.range.location - 1
            while p >= 0, [32, 9].contains(code.character(at: p)) { p -= 1 }
            // A statement: after the start, a newline, ; { } or ) – not obj.debugger.
            if p >= 0, ![10, 13, 59, 123, 125, 41].contains(code.character(at: p)) { continue }
            var q = NSMaxRange(m.range)
            while q < n, [32, 9].contains(code.character(at: q)) { q += 1 }
            // Followed by ;, a newline, } or the end – not `debugger: 1`.
            guard q >= n || [59, 10, 13, 125].contains(code.character(at: q)) else { continue }
            var end = q < n && code.character(at: q) == 59 ? q + 1 : NSMaxRange(m.range)
            guard let line = RulesHintProvider.lineRange(input.lines, containing: m.range.location) else { continue }
            let before = code.substring(with: NSRange(location: line.location, length: m.range.location - line.location))
            let after = code.substring(with: NSRange(location: end, length: max(0, NSMaxRange(line) - end)))
            if before.trimmingCharacters(in: .whitespaces).isEmpty, after.trimmingCharacters(in: .whitespaces).isEmpty {
                // Alone on its line: the whole line goes, with its newline.
                let lineEnd = NSMaxRange(line) < input.text.length ? NSMaxRange(line) + 1 : NSMaxRange(line)
                let lineStart = lineEnd == NSMaxRange(line) && line.location > 0 ? line.location - 1 : line.location
                edits.append((NSRange(location: lineStart, length: lineEnd - lineStart), ""))
            } else {
                while end < n, code.character(at: end) == 32 { end += 1 }
                edits.append((NSRange(location: m.range.location, length: end - m.range.location), ""))
            }
        }
        guard let fix = RulesHintProvider.spanEdit(input.text, edits) else { return nil }
        return LintFinding(kind: .fix, title: String(localized: "A “debugger” statement is left in. Remove it?"),
                           detail: String(localized: "With the developer tools open, it stops the page or the process right there.\(RulesHintProvider.andMore(edits.count))"),
                           range: fix.range, replacement: fix.replacement)
    }

    // MARK: JS2 Comparing with NaN

    static let nanAfter = try! NSRegularExpression(pattern: #"([!=]==?)[ \t]*(?:Number\.)?NaN\b"#)
    static let nanBefore = try! NSRegularExpression(pattern: #"(?<![\w$.])(?:Number\.)?NaN[ \t]*([!=]==?)"#)
    static let operandBefore = try! NSRegularExpression(pattern: #"([A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*)[ \t]*$"#)
    static let operandAfter = try! NSRegularExpression(pattern: #"^[ \t]*([A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*)"#)

    static let nanCompare = LintRule(nanID, applies: js) { input in
        let code = input.codeNS
        guard code.range(of: "NaN").location != NSNotFound else { return nil }
        var hits: [(NSRange, String?)] = []
        func lineOf(_ k: Int) -> NSRange? { RulesHintProvider.lineRange(input.lines, containing: k) }
        // Characters that may come before `x === NaN` for it to be the whole comparison.
        let openers: Set<unichar> = [40, 44, 59, 123, 38, 124, 63, 58, 61, 10]
        for m in RulesHintProvider.matches(nanAfter, input.code) {
            guard let line = lineOf(m.range.location) else { continue }
            let negate = code.substring(with: m.range(at: 1)).hasPrefix("!")
            let head = NSRange(location: line.location, length: m.range.location - line.location)
            var fix: (NSRange, String)?
            if let o = operandBefore.firstMatch(in: input.code, range: head) {
                var p = o.range(at: 1).location - 1
                while p >= line.location, [32, 9].contains(code.character(at: p)) { p -= 1 }
                let ok = p < line.location || openers.contains(code.character(at: p))
                    || code.substring(with: NSRange(location: line.location, length: p - line.location + 1)).hasSuffix(" return")
                    || code.substring(with: NSRange(location: line.location, length: p - line.location + 1)).trimmingCharacters(in: .whitespaces) == "return"
                if ok {
                    let operand = code.substring(with: o.range(at: 1))
                    fix = (NSRange(location: o.range(at: 1).location, length: NSMaxRange(m.range) - o.range(at: 1).location),
                           (negate ? "!" : "") + "Number.isNaN(\(operand))")
                }
            }
            hits.append(fix.map { ($0.0, $0.1) } ?? (m.range, nil))
        }
        for m in RulesHintProvider.matches(nanBefore, input.code) {
            if hits.contains(where: { NSIntersectionRange($0.0, m.range).length > 0 }) { continue }
            guard let line = lineOf(m.range.location) else { continue }
            let negate = code.substring(with: m.range(at: 1)).hasPrefix("!")
            let tail = NSRange(location: NSMaxRange(m.range), length: NSMaxRange(line) - NSMaxRange(m.range))
            var fix: (NSRange, String)?
            if let o = operandAfter.firstMatch(in: input.code, options: .anchored, range: tail) {
                var q = NSMaxRange(o.range(at: 1))
                while q < NSMaxRange(line), [32, 9].contains(code.character(at: q)) { q += 1 }
                if q >= NSMaxRange(line) || [41, 59, 38, 124, 44, 63, 58, 125].contains(code.character(at: q)) {
                    fix = (NSRange(location: m.range.location, length: NSMaxRange(o.range(at: 1)) - m.range.location),
                           (negate ? "!" : "") + "Number.isNaN(\(code.substring(with: o.range(at: 1))))")
                }
            }
            hits.append(fix.map { ($0.0, $0.1) } ?? (m.range, nil))
        }
        guard !hits.isEmpty else { return nil }
        hits.sort { $0.0.location < $1.0.location }
        let fixable = hits.allSatisfy { $0.1 != nil }
        let fix = fixable ? RulesHintProvider.spanEdit(input.text, hits.map { ($0.0, $0.1!) }) : nil
        return LintFinding(kind: fixable ? .fix : .warning, title: String(localized: "Nothing equals NaN, not even NaN. Use Number.isNaN?"),
                           detail: String(localized: "“x === NaN” is always false (and “!==” always true). Number.isNaN(x) is the check that works.\(RulesHintProvider.andMore(hits.count))"),
                           range: fix?.range ?? hits[0].0, replacement: fix?.replacement)
    }

    // MARK: JS3 typeof compared with a misspelt type

    static let typeNames = ["undefined", "object", "boolean", "number", "string", "function", "symbol", "bigint"]
    static let typeofThenString = try! NSRegularExpression(pattern: #"\btypeof\b[^=!;\n&|?]*?[!=]==?[ \t]*(["'])"#)
    static let stringThenTypeof = try! NSRegularExpression(pattern: #"(["'])[ \t]*[!=]==?[ \t]*typeof\b"#)

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var prev = row[0]
            row[0] = i
            for j in 1...max(b.count, 1) where !b.isEmpty {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return row[b.count]
    }

    static let typeofTypo = LintRule(typeofID, applies: js) { input in
        let code = input.codeNS
        guard code.range(of: "typeof").location != NSNotFound, let mask = input.mask else { return nil }
        var hits: [(NSRange, String?, String)] = []
        var seen: Set<NSRange> = []
        // The nearest type name per value: a file repeats the same typo,
        // and eight edit distances per hit are the cost (debug builds most).
        var nearest: [String: String?] = [:]
        func check(stringAt k: Int) {
            guard let sp = mask.string(startingAt: k), sp.range.length >= 2 else { return }
            let inner = NSRange(location: sp.range.location + 1, length: sp.range.length - 2)
            let value = input.text.substring(with: inner)
            guard !typeNames.contains(value), !seen.contains(inner) else { return }
            let fix: String?
            if let known = nearest[value] { fix = known } else {
                let near = typeNames.map { ($0, distance(value.lowercased(), $0)) }.min { $0.1 < $1.1 }
                fix = near.flatMap { $0.1 <= 2 ? $0.0 : nil }
                nearest[value] = .some(fix)
            }
            seen.insert(inner)
            hits.append((inner, fix, value))
        }
        for m in RulesHintProvider.matches(typeofThenString, input.code) { check(stringAt: m.range(at: 1).location) }
        for m in RulesHintProvider.matches(stringThenTypeof, input.code) {
            // The string ends at the quote matched; find where it starts.
            guard let sp = mask.span(at: m.range(at: 1).location), sp.kind == .string else { continue }
            check(stringAt: sp.range.location)
        }
        guard !hits.isEmpty else { return nil }
        hits.sort { $0.0.location < $1.0.location }
        let fixable = hits.allSatisfy { $0.1 != nil }
        let fix = fixable ? RulesHintProvider.spanEdit(input.text, hits.map { ($0.0, $0.1!) }) : nil
        let first = hits[0]
        return LintFinding(kind: fixable ? .fix : .warning,
                           title: first.1.map { String(localized: "typeof gives no “\(String(first.2.prefix(16)))”. Mean “\($0)”?") }
                               ?? String(localized: "typeof never gives “\(String(first.2.prefix(20)))”."),
                           detail: String(localized: "typeof only ever returns undefined, object, boolean, number, string, function, symbol or bigint, so “===” with anything else is always false (and “!==” always true).\(RulesHintProvider.andMore(hits.count))"),
                           range: fix?.range ?? first.0, replacement: fix?.replacement)
    }
}
