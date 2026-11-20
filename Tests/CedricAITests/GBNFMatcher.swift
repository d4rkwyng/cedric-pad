import Foundation

/// A small GBNF interpreter for tests: parses the subset Owlink's grammars
/// use (literals, character classes with ranges and negation, rule
/// references, groups, alternation, `?`, `*`, `+`, `{m,n}`) and says
/// whether a whole string matches the root rule. Not llama.cpp's parser,
/// but the same language: it catches a rule that accepts what it
/// shouldn't (a quoted integer, a misspelt key) or rejects a valid call.
struct GBNFMatcher {
    indirect enum Node {
        case literal([Unicode.Scalar])
        case charClass(negated: Bool, ranges: [ClosedRange<UInt32>])
        case ref(String)
        case seq([Node])
        case alt([Node])
        case repeated(Node, min: Int, max: Int?)
    }

    enum ParseError: Error { case bad(String) }

    private(set) var rules: [String: Node] = [:]

    init(_ grammar: String) throws {
        for raw in grammar.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let r = line.range(of: "::=") else { throw ParseError.bad("no ::= in \(line)") }
            let name = line[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            var p = Parser(Array(line[r.upperBound...].unicodeScalars))
            let node = try p.alt()
            p.skip()
            guard p.i == p.s.count else { throw ParseError.bad("trailing text in rule \(name)") }
            guard rules[name] == nil else { throw ParseError.bad("rule \(name) defined twice") }
            rules[name] = node
        }
        // Every reference resolves.
        func check(_ n: Node) throws {
            switch n {
            case .ref(let r): if rules[r] == nil { throw ParseError.bad("undefined rule \(r)") }
            case .seq(let a), .alt(let a): try a.forEach(check)
            case .repeated(let x, _, _): try check(x)
            default: break
            }
        }
        try rules.values.forEach(check)
    }

    func matches(_ text: String, root: String = "root") -> Bool {
        let s = Array(text.unicodeScalars)
        return ends(.ref(root), s, 0).contains(s.count)
    }

    private func ends(_ n: Node, _ s: [Unicode.Scalar], _ i: Int) -> Set<Int> {
        switch n {
        case .literal(let l):
            guard i + l.count <= s.count, Array(s[i..<(i + l.count)]) == l else { return [] }
            return [i + l.count]
        case .charClass(let neg, let ranges):
            guard i < s.count else { return [] }
            let inside = ranges.contains { $0.contains(s[i].value) }
            return inside != neg ? [i + 1] : []
        case .ref(let r):
            return ends(rules[r]!, s, i)
        case .seq(let items):
            var at: Set<Int> = [i]
            for item in items {
                var next: Set<Int> = []
                for p in at { next.formUnion(ends(item, s, p)) }
                at = next
                if at.isEmpty { break }
            }
            return at
        case .alt(let options):
            var out: Set<Int> = []
            for o in options { out.formUnion(ends(o, s, i)) }
            return out
        case .repeated(let x, let lo, let hi):
            var out: Set<Int> = lo == 0 ? [i] : []
            var seen: Set<Int> = [i]
            var frontier: Set<Int> = [i]
            var count = 0
            while !frontier.isEmpty, hi.map({ count < $0 }) ?? true {
                var next: Set<Int> = []
                // Each repetition must consume something, so this ends.
                for p in frontier { next.formUnion(ends(x, s, p).filter { $0 > p }) }
                count += 1
                if count >= lo {
                    // Reached earlier with ≥ lo repetitions: nothing new from there.
                    next.subtract(seen)
                    seen.formUnion(next)
                    out.formUnion(next)
                }
                frontier = next
            }
            return out
        }
    }

    private struct Parser {
        let s: [Unicode.Scalar]
        var i = 0
        init(_ s: [Unicode.Scalar]) { self.s = s }

        mutating func skip() { while i < s.count, s[i] == " " || s[i] == "\t" { i += 1 } }

        mutating func alt() throws -> Node {
            var options = [try seq()]
            skip()
            while i < s.count, s[i] == "|" { i += 1; options.append(try seq()); skip() }
            return options.count == 1 ? options[0] : .alt(options)
        }

        mutating func seq() throws -> Node {
            var items: [Node] = []
            while true {
                skip()
                guard i < s.count, s[i] != "|", s[i] != ")" else { break }
                items.append(try postfix(try atom()))
            }
            return items.count == 1 ? items[0] : .seq(items)
        }

        mutating func postfix(_ a: Node) throws -> Node {
            guard i < s.count else { return a }
            switch s[i] {
            case "?": i += 1; return .repeated(a, min: 0, max: 1)
            case "*": i += 1; return .repeated(a, min: 0, max: nil)
            case "+": i += 1; return .repeated(a, min: 1, max: nil)
            case "{":
                i += 1
                let lo = number()
                var hi: Int? = lo
                if i < s.count, s[i] == "," { i += 1; hi = i < s.count && s[i] == "}" ? nil : number() }
                guard i < s.count, s[i] == "}" else { throw ParseError.bad("bad {m,n}") }
                i += 1
                return .repeated(a, min: lo, max: hi)
            default: return a
            }
        }

        mutating func number() -> Int {
            var n = 0
            while i < s.count, let d = Int(String(s[i])) { n = n * 10 + d; i += 1 }
            return n
        }

        mutating func escaped() throws -> Unicode.Scalar {
            guard i < s.count else { throw ParseError.bad("dangling escape") }
            let e = s[i]; i += 1
            switch e {
            case "n": return "\n"
            case "t": return "\t"
            case "r": return "\r"
            case "x":
                guard i + 2 <= s.count, let v = UInt32(String(String.UnicodeScalarView(s[i..<(i + 2)])), radix: 16) else { throw ParseError.bad("bad \\x") }
                i += 2
                return Unicode.Scalar(v)!
            default: return e
            }
        }

        mutating func atom() throws -> Node {
            let c = s[i]
            if c == "\"" {
                i += 1
                var lit: [Unicode.Scalar] = []
                while true {
                    guard i < s.count else { throw ParseError.bad("unterminated literal") }
                    let d = s[i]; i += 1
                    if d == "\"" { break }
                    lit.append(d == "\\" ? try escaped() : d)
                }
                return .literal(lit)
            }
            if c == "[" {
                i += 1
                var neg = false
                if i < s.count, s[i] == "^" { neg = true; i += 1 }
                var ranges: [ClosedRange<UInt32>] = []
                while true {
                    guard i < s.count else { throw ParseError.bad("unterminated class") }
                    if s[i] == "]" { i += 1; break }
                    var a = s[i]; i += 1
                    if a == "\\" { a = try escaped() }
                    var b = a
                    if i + 1 < s.count, s[i] == "-", s[i + 1] != "]" {
                        i += 1
                        b = s[i]; i += 1
                        if b == "\\" { b = try escaped() }
                    }
                    ranges.append(a.value...b.value)
                }
                return .charClass(negated: neg, ranges: ranges)
            }
            if c == "(" {
                i += 1
                let inner = try alt()
                skip()
                guard i < s.count, s[i] == ")" else { throw ParseError.bad("unclosed (") }
                i += 1
                return inner
            }
            var name = ""
            while i < s.count, s[i].properties.isAlphabetic || ("0"..."9").contains(s[i]) || s[i] == "-" || s[i] == "_" {
                name.unicodeScalars.append(s[i]); i += 1
            }
            guard !name.isEmpty else { throw ParseError.bad("unexpected \(c)") }
            return .ref(name)
        }
    }
}
