import Foundation

/// Explains a regular expression offline, token by token: a structured
/// breakdown (one row per piece, nested under its group) in plain English.
/// Deterministic and pure; what it doesn't know is said, not guessed.
/// Handles the common syntax of JavaScript, Python, PCRE, ICU (Swift's
/// NSRegularExpression) and POSIX ERE: anchors, classes, sets, groups
/// (capturing, named, non-capturing, lookaround), alternation,
/// quantifiers (greedy, lazy, possessive), back-references, escapes,
/// Unicode properties and inline flags. A JS literal `/…/gi` explains its
/// flags too. Nested quantifiers such as `(a+)+` get a warning: they can
/// take exponential time on a near match.
public enum RegexExplain {
    public struct Part: Sendable, Equatable {
        public var token: String
        public var meaning: String
        public var depth: Int
    }

    public struct Explanation: Sendable, Equatable {
        public var parts: [Part]
        public var warnings: [String]
        /// The pattern as explained (without a literal's slashes and flags).
        public var pattern: String

        /// The breakdown as indented text (for the popover and Copy).
        public var text: String {
            var lines = parts.map { String(repeating: "  ", count: $0.depth) + $0.token + "  " + $0.meaning }
            if !warnings.isEmpty { lines.append(""); lines += warnings.map { "⚠︎ " + $0 } }
            return lines.joined(separator: "\n")
        }
    }

    /// Whether a selection plausibly is a regex (worth offering): a JS
    /// literal, or text with regex syntax that parses.
    public static func looksLikeRegex(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2, t.count <= 2000, !t.contains("\n") else { return false }
        if t.hasPrefix("/"), literal(t) != nil { return true }
        let meta = ["\\d", "\\w", "\\s", "\\b", "[", "(", "+", "*", "?", "^", "$", "{", "|", "\\."]
        guard meta.filter({ t.contains($0) }).count >= 2 else { return false }
        return (try? NSRegularExpression(pattern: t)) != nil
    }

    /// `/pattern/flags` → (pattern, flags).
    static func literal(_ t: String) -> (String, String)? {
        guard t.hasPrefix("/"), let end = t.lastIndex(of: "/"), end > t.startIndex else { return nil }
        let flags = String(t[t.index(after: end)...])
        guard flags.allSatisfy({ "dgimsuyv".contains($0) }) else { return nil }
        return (String(t[t.index(after: t.startIndex)..<end]), flags)
    }

    public static func explain(_ input: String) -> Explanation {
        var source = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var flags = ""
        if let (p, f) = literal(source) { source = p; flags = f }
        var p = Parser(Array(source))
        p.run()
        var parts = p.parts
        if !flags.isEmpty {
            let names: [Character: String] = ["g": "g: every match, not just the first", "i": "i: ignore case", "m": "m: ^ and $ match at each line",
                                              "s": "s: . matches newlines too", "u": "u: Unicode mode", "y": "y: sticky (match at lastIndex only)",
                                              "d": "d: report match indices", "v": "v: Unicode sets mode"]
            parts.append(Part(token: "/" + flags, meaning: String(localized: "flags: ") + flags.compactMap { names[$0] }.joined(separator: "; "), depth: 0))
        }
        return Explanation(parts: parts, warnings: p.warnings, pattern: source)
    }

    struct Parser {
        let c: [Character]
        var i = 0
        var parts: [Part] = []
        var warnings: [String] = []
        var depth = 0
        var groupCount = 0
        /// Per open group: whether something inside it is quantified (for (a+)+).
        var quantifiedInside: [Bool] = []

        init(_ c: [Character]) { self.c = c }

        func peek(_ k: Int = 0) -> Character? { i + k < c.count ? c[i + k] : nil }

        mutating func add(_ token: String, _ meaning: String) { parts.append(Part(token: token, meaning: meaning, depth: depth)) }

        mutating func run() {
            while i < c.count {
                let ch = c[i]
                switch ch {
                case "(": openGroup()
                case ")":
                    i += 1
                    depth = max(0, depth - 1)
                    let inner = quantifiedInside.popLast() ?? false
                    add(")", String(localized: "end of group"))
                    if quantifier(afterGroupWithQuantifiedInside: inner) {} else if inner, !quantifiedInside.isEmpty { quantifiedInside[quantifiedInside.count - 1] = true }
                case "|":
                    i += 1
                    add("|", String(localized: "or"))
                case "[": set()
                case "\\": escape()
                case "^": i += 1; add("^", String(localized: "start of the line (or of the text)"))
                case "$": i += 1; add("$", String(localized: "end of the line (or of the text)"))
                case ".": i += 1; add(".", String(localized: "any character (except a newline)")); _ = quantifier()
                case "*", "+", "?":
                    i += 1
                    add(String(ch), String(localized: "a quantifier with nothing to repeat (an error in most engines)"))
                default:
                    // A run of literal characters (each may take a quantifier).
                    var run = ""
                    while i < c.count, !"()|[\\^$.*+?{".contains(c[i]) || (c[i] == "{" && !isQuantifierBrace()) {
                        // A quantifier applies to the last character only: stop before it.
                        if i + 1 < c.count, "*+?".contains(c[i + 1]) || (c[i + 1] == "{" && isQuantifierBrace(at: i + 1)) {
                            if run.isEmpty { run.append(c[i]); i += 1 }
                            break
                        }
                        run.append(c[i]); i += 1
                    }
                    if run.isEmpty { run.append(c[i]); i += 1 }
                    add(run, run.count == 1 ? String(localized: "the character “\(run)”") : String(localized: "the text “\(run)”"))
                    _ = quantifier()
                }
            }
            if depth > 0 { warnings.append(String(localized: "A group is never closed: this pattern doesn’t compile.")) }
        }

        func isQuantifierBrace(at k: Int? = nil) -> Bool {
            var j = (k ?? i) + 1
            var digits = 0
            while j < c.count, c[j].isNumber { j += 1; digits += 1 }
            guard digits > 0, j < c.count else { return false }
            if c[j] == "}" { return true }
            guard c[j] == "," else { return false }
            j += 1
            while j < c.count, c[j].isNumber { j += 1 }
            return j < c.count && c[j] == "}"
        }

        /// A quantifier after the last part, explained on its own row.
        @discardableResult
        mutating func quantifier(afterGroupWithQuantifiedInside inner: Bool = false) -> Bool {
            guard let q = peek() else { return false }
            var token = "", meaning = ""
            var repeats = false
            switch q {
            case "*": token = "*"; meaning = String(localized: "zero or more times"); repeats = true; i += 1
            case "+": token = "+"; meaning = String(localized: "one or more times"); repeats = true; i += 1
            case "?": token = "?"; meaning = String(localized: "optional (zero or one time)"); i += 1
            case "{" where isQuantifierBrace():
                var j = i + 1, a = "", b: String? = nil
                while c[j].isNumber { a.append(c[j]); j += 1 }
                if c[j] == "," { b = ""; j += 1; while c[j].isNumber { b!.append(c[j]); j += 1 } }
                token = String(c[i...j])
                i = j + 1
                if let b {
                    meaning = b.isEmpty ? String(localized: "\(a) or more times") : String(localized: "\(a) to \(b) times")
                    repeats = b.isEmpty || (Int(b) ?? 0) > 1
                } else {
                    meaning = String(localized: "exactly \(a) times")
                    repeats = (Int(a) ?? 0) > 1
                }
            default: return false
            }
            if peek() == "?" { token += "?"; meaning += String(localized: ", as few as possible (lazy)"); i += 1 } else if peek() == "+" {
                token += "+"; meaning += String(localized: ", without backtracking (possessive)"); i += 1
            }
            parts.append(Part(token: token, meaning: meaning, depth: depth + 1))
            if repeats, inner {
                warnings.append(String(localized: "A repeated group with a repeat inside it (like (a+)+) can take exponential time on text that almost matches."))
            }
            if repeats, !quantifiedInside.isEmpty { quantifiedInside[quantifiedInside.count - 1] = true }
            return true
        }

        mutating func openGroup() {
            i += 1
            var token = "(", meaning = ""
            if peek() == "?" {
                let rest = String(c[i..<min(c.count, i + 4)])
                if rest.hasPrefix("?:") { token = "(?:"; meaning = String(localized: "a group (not captured)"); i += 2 }
                else if rest.hasPrefix("?=") { token = "(?="; meaning = String(localized: "followed by (lookahead, not part of the match)"); i += 2 }
                else if rest.hasPrefix("?!") { token = "(?!"; meaning = String(localized: "not followed by (negative lookahead)"); i += 2 }
                else if rest.hasPrefix("?<=") { token = "(?<="; meaning = String(localized: "preceded by (lookbehind)"); i += 3 }
                else if rest.hasPrefix("?<!") { token = "(?<!"; meaning = String(localized: "not preceded by (negative lookbehind)"); i += 3 }
                else if rest.hasPrefix("?>") { token = "(?>"; meaning = String(localized: "an atomic group (no backtracking into it)"); i += 2 }
                else if rest.hasPrefix("?<") || rest.hasPrefix("?P<") || rest.hasPrefix("?'") {
                    let start = i
                    while i < c.count, c[i] != ">", c[i] != "'" || i == start + 1 { i += 1 }
                    let name = String(c[(start + (rest.hasPrefix("?P<") ? 3 : 2))..<min(i, c.count)])
                    i += 1
                    groupCount += 1
                    token = String(c[(start - 1)..<min(i, c.count)])
                    meaning = String(localized: "group \(groupCount), named “\(name)” (captured)")
                } else {
                    // Inline flags: (?i) or (?i:…).
                    let start = i
                    i += 1
                    while i < c.count, c[i].isLetter || c[i] == "-" { i += 1 }
                    let flags = String(c[(start + 1)..<i])
                    if peek() == ")" {
                        i += 1
                        add("(?" + flags + ")", flagMeaning(flags))
                        return
                    }
                    if peek() == ":" { i += 1 }
                    token = "(?" + flags + ":"
                    meaning = String(localized: "a group with ") + flagMeaning(flags)
                }
            } else {
                groupCount += 1
                meaning = String(localized: "group \(groupCount) (captured)")
            }
            add(token, meaning)
            depth += 1
            quantifiedInside.append(false)
        }

        func flagMeaning(_ f: String) -> String {
            let names: [Character: String] = ["i": String(localized: "ignore case"), "m": String(localized: "^ and $ at each line"),
                                              "s": String(localized: ". matches newlines"), "x": String(localized: "spaces and # comments ignored"),
                                              "u": String(localized: "Unicode")]
            let on = f.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
            let off = f.contains("-") ? String(f.split(separator: "-", maxSplits: 1).last ?? "") : ""
            var out = on.compactMap { names[$0] }
            out += off.compactMap { names[$0].map { String(localized: "not ") + $0 } }
            return out.isEmpty ? String(localized: "flags \(f)") : String(localized: "flags: ") + out.joined(separator: ", ")
        }

        static let classNames: [Character: String] = [
            "d": "a digit (0–9)", "D": "anything but a digit", "w": "a word character (letter, digit or _)",
            "W": "anything but a word character", "s": "white space (space, tab, newline…)", "S": "anything but white space",
            "b": "a word boundary", "B": "not a word boundary", "A": "start of the text", "z": "end of the text",
            "Z": "end of the text (before a final newline)", "G": "where the last match ended", "n": "a newline", "t": "a tab",
            "r": "a carriage return", "f": "a form feed", "v": "a vertical tab", "0": "the NUL character", "h": "horizontal white space",
            "R": "any line break", "K": "drop what matched so far from the match",
        ]

        mutating func escape() {
            guard let e = peek(1) else { i += 1; add("\\", String(localized: "a trailing backslash (an error)")); return }
            i += 2
            switch e {
            case "p", "P":
                var name = ""
                if peek() == "{" { i += 1; while i < c.count, c[i] != "}" { name.append(c[i]); i += 1 }; i += 1 } else if let x = peek() { name = String(x); i += 1 }
                add("\\\(e){\(name)}", e == "p" ? String(localized: "a character with the Unicode property \(name)") : String(localized: "a character without the Unicode property \(name)"))
            case "x":
                var hex = ""
                if peek() == "{" { i += 1; while i < c.count, c[i] != "}" { hex.append(c[i]); i += 1 }; i += 1 } else { while hex.count < 2, let h = peek(), h.isHexDigit { hex.append(h); i += 1 } }
                add("\\x" + hex, String(localized: "the character U+\(hex.uppercased())"))
            case "u":
                var hex = ""
                if peek() == "{" { i += 1; while i < c.count, c[i] != "}" { hex.append(c[i]); i += 1 }; i += 1 } else { while hex.count < 4, let h = peek(), h.isHexDigit { hex.append(h); i += 1 } }
                add("\\u" + hex, String(localized: "the character U+\(hex.uppercased())"))
            case "k":
                var name = ""
                if let o = peek(), "<{'".contains(o) { i += 1; while i < c.count, !">}'".contains(c[i]) { name.append(c[i]); i += 1 }; i += 1 }
                add("\\k<\(name)>", String(localized: "the same text group “\(name)” matched"))
            case "1"..."9":
                var n = String(e)
                while let d = peek(), d.isNumber { n.append(d); i += 1 }
                add("\\" + n, String(localized: "the same text group \(n) matched"))
            default:
                if let name = Self.classNames[e] {
                    add("\\" + String(e), String(localized: String.LocalizationValue(name)))
                } else if e.isLetter {
                    add("\\" + String(e), String(localized: "“\\\(String(e))” (unknown here; engines differ)"))
                } else {
                    add("\\" + String(e), String(localized: "the character “\(String(e))”"))
                }
            }
            _ = quantifier()
        }

        mutating func set() {
            let start = i
            i += 1
            var negated = false
            if peek() == "^" { negated = true; i += 1 }
            var items: [String] = []
            var first = true
            while i < c.count, c[i] != "]" || first {
                first = false
                if c[i] == "\\", i + 1 < c.count {
                    let e = c[i + 1]
                    items.append(Self.classNames[e].map { String(localized: String.LocalizationValue($0)) } ?? "“\(e)”")
                    i += 2
                } else if c[i] == "[", peek(1) == ":" {
                    // POSIX [:alpha:]
                    var name = ""
                    i += 2
                    while i < c.count, c[i] != ":" { name.append(c[i]); i += 1 }
                    i += 2
                    items.append("[:\(name):]")
                } else if i + 2 < c.count, c[i + 1] == "-", c[i + 2] != "]" {
                    items.append("“\(c[i])” to “\(c[i + 2])”")
                    i += 3
                } else {
                    items.append("“\(c[i])”")
                    i += 1
                }
            }
            let closed = i < c.count
            i = min(i + 1, c.count)
            let token = String(c[start..<min(i, c.count)])
            let list = items.joined(separator: ", ")
            if !closed { warnings.append(String(localized: "A [ set is never closed: this pattern doesn’t compile.")) }
            add(token, negated ? String(localized: "one character that is not: \(list)") : String(localized: "one character of: \(list)"))
            _ = quantifier()
        }
    }
}
