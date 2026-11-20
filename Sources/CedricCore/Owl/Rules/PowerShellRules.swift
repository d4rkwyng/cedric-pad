import Foundation

/// Pack 6: PowerShell. Sources: PSScriptAnalyzer's
/// PossibleIncorrectUsageOfRedirectionOperator and MisleadingBacktick.
/// Patterns match only code (`scanPowerShell`'s strings, comments and
/// here-strings are blanked).
enum PowerShellRules {
    static let redirectID = "rules.ps.redirect-compare"
    static let backtickID = "rules.ps.backtick-space"

    static let powershell = LintRule.languages(["powershell"])

    // MARK: PS1 `>` in an if or while condition

    static let conditionStart = try! NSRegularExpression(pattern: #"(?i)(?<![\w$-])(if|elseif|while)\s*\("#)
    /// `$a > 5`, `$x.Count >= $max`: a value, then > or >=, then a value.
    static let comparison = try! NSRegularExpression(pattern: #"(\$[\w:]+(?:\.\w+|\[[^\]\n]*\])*|\d+(?:\.\d+)?|\))[ \t]*(>=?)[ \t]*(?=[\$\d(]|-\d)"#)

    static let redirectCompare = LintRule(redirectID, applies: powershell) { input in
        let code = input.codeNS, str = input.code
        guard code.range(of: ">").location != NSNotFound else { return nil }
        var edits: [(NSRange, String)] = []
        for m in RulesHintProvider.matches(conditionStart, str) {
            // The condition: up to the matching ), at its own depth only
            // (inside a nested ( ) or $( ) a pipeline may redirect on purpose).
            var i = NSMaxRange(m.range), depth = 0, ranges: [NSRange] = [], segStart = i
            let n = code.length
            var closed = false
            while i < n {
                let c = code.character(at: i)
                if c == 40 || c == 123 || c == 91 {
                    if depth == 0 { ranges.append(NSRange(location: segStart, length: i - segStart)) }
                    depth += 1
                } else if c == 41 || c == 125 || c == 93 {
                    if depth == 0 { ranges.append(NSRange(location: segStart, length: i - segStart)); closed = true; break }
                    depth -= 1
                    if depth == 0 { segStart = i + 1 }
                } else if c == 10, depth == 0, i > 0, code.character(at: i - 1) != 96 {
                    break   // a condition on one line (or continued with a backtick)
                }
                i += 1
            }
            guard closed else { continue }
            for r in ranges where r.length > 0 {
                for c in RulesHintProvider.matches(comparison, str, in: r) {
                    let op = c.range(at: 2)
                    // Not 2>, *>, >> (stream redirections), ->.
                    let before = op.location > 0 ? code.character(at: op.location - 1) : 0
                    if before == 62 || before == 45 || before == 42 { continue }
                    // `2>` / `3>`: a stream redirection (a digit right before >).
                    if before >= 48, before <= 57 { continue }
                    if NSMaxRange(op) < n, code.character(at: NSMaxRange(op)) == 62 { continue }
                    // `$a > $null` throws output away: meant.
                    let tail = code.substring(with: NSRange(location: NSMaxRange(op), length: min(8, n - NSMaxRange(op)))).lowercased()
                    if tail.trimmingCharacters(in: .whitespaces).hasPrefix("$null") { continue }
                    let ge = op.length == 2
                    edits.append((op, ge ? "-ge" : "-gt"))
                }
            }
        }
        guard let first = edits.first, let fix = RulesHintProvider.spanEdit(input.text, edits) else { return nil }
        let ge = first.1 == "-ge"
        return LintFinding(kind: .fix,
                           title: ge ? String(localized: "“>=” in a condition writes a file. Use -ge?") : String(localized: "“>” in a condition writes a file. Use -gt?"),
                           detail: String(localized: "In PowerShell > is redirection: “if ($a > 5)” writes $a to a file named 5 and the test is always false. Comparisons are -gt, -ge, -lt and -le.\(RulesHintProvider.andMore(edits.count))"),
                           range: fix.range, replacement: fix.replacement)
    }

    // MARK: PS4 A backtick followed by a space at the end of a line

    static let backtickSpace = LintRule(backtickID, applies: powershell) { input in
        let code = input.codeNS, s = input.text
        guard code.range(of: "`").location != NSNotFound else { return nil }
        var edits: [(NSRange, String)] = []
        for r in input.lines where r.length > 1 {
            var e = NSMaxRange(r)
            if e > r.location, s.character(at: e - 1) == 13 { e -= 1 }
            var b = e
            while b > r.location, s.character(at: b - 1) == 32 || s.character(at: b - 1) == 9 { b -= 1 }
            guard b < e, b > r.location, code.character(at: b - 1) == 96, s.character(at: b - 1) == 96 else { continue }
            // An escaped backtick (``) is a literal one, not a continuation.
            if b - 2 >= r.location, code.character(at: b - 2) == 96 { continue }
            edits.append((NSRange(location: b, length: e - b), ""))
        }
        guard let first = edits.first, let fix = RulesHintProvider.spanEdit(input.text, edits) else { return nil }
        return LintFinding(kind: .fix, title: String(localized: "A space after the line-end backtick breaks it. Remove?"),
                           detail: String(localized: "The backtick \(input.at(first.0.location)) escapes the space, not the line end, so the command stops there and the next line runs on its own.\(RulesHintProvider.andMore(edits.count))"),
                           range: fix.range, replacement: fix.replacement)
    }
}
