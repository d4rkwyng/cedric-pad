import Foundation

/// A string literal rule: opening and closing delimiters, whether it may
/// span lines, and whether backslash escapes apply.
public struct StringRule: Sendable {
    public var open: [UInt16]
    public var close: [UInt16]
    public var multiline: Bool
    public var escapes: Bool

    public init(_ open: String, _ close: String? = nil, multiline: Bool = false, escapes: Bool = true) {
        self.open = Array(open.utf16)
        self.close = Array((close ?? open).utf16)
        self.multiline = multiline
        self.escapes = escapes
    }
}

/// What distinguishes one C-family-ish language from another, for the
/// shared `CodeTokenizer`. Swift, Python, JavaScript/TypeScript, C, Ruby
/// and shell scripts are all described with one of these.
public struct CodeSpec: Sendable {
    public var lineComments: [[UInt16]] = []
    /// `#` starts a comment only at the start of a word (shell: `a#b` is a word).
    public var lineCommentNeedsWordBoundary = false
    public var blockComment: (open: [UInt16], close: [UInt16])?
    public var nestedBlockComments = false
    /// Longest openers first: `"""` before `"`.
    public var strings: [StringRule] = []
    public var keywords = WordSet([])
    public var types = WordSet([])
    public var constants = WordSet([])
    /// Identifiers starting with an uppercase letter are types (Swift, TS).
    public var capitalizedAreTypes = false
    /// `@name` is an attribute (Swift attributes, Python decorators).
    public var atAttributes = false
    /// `@name` / `@@name` is a variable (Ruby instance variables).
    public var atVariables = false
    /// `$name`, `${…}`, `$1` are variables (shell).
    public var dollarVariables = false
    /// `#word` at the start of a line is a preprocessor directive (C).
    public var preprocessor = false
    /// `:name` is a constant (Ruby symbols).
    public var colonSymbols = false
    /// `$` may appear inside identifiers (JavaScript).
    public var dollarInIdentifiers = false
    /// `?` and `!` may end an identifier (Ruby).
    public var predicateSuffix = false
    /// `#if` / `#available` style keywords (Swift `#selector`).
    public var hashKeywords = false

    public init() {}
}

/// A configurable tokenizer for languages made of comments, strings,
/// numbers, keywords and identifiers. State: 0 = normal;
/// `1 | depth << 8` = inside a block comment; `2 | rule << 8` = inside a
/// multi-line string opened by `strings[rule]`.
public struct CodeTokenizer: Tokenizer {
    public let spec: CodeSpec
    public init(_ spec: CodeSpec) { self.spec = spec }

    public var carriesState: Bool {
        spec.blockComment != nil || spec.strings.contains { $0.multiline }
    }

    public func tokenize(_ b: UnsafeBufferPointer<UInt16>, state: inout UInt32, into t: inout [Token]) {
        let n = b.count
        var i = 0

        // Continue whatever the previous line left open.
        if state & 0xff == 1, let bc = spec.blockComment {
            var depth = Int(state >> 8)
            let end = scanBlockComment(b, from: 0, close: bc.close, open: bc.open, depth: &depth)
            t.add(0, end, .comment)
            i = end
            state = depth > 0 ? 1 | UInt32(depth) << 8 : 0
            if depth > 0 { return }
        } else if state & 0xff == 2 {
            let rule = spec.strings[Int(state >> 8)]
            let (end, closed) = scanString(b, from: 0, rule: rule)
            t.add(0, end, .string)
            i = end
            if !closed { return }
            state = 0
        }

        let lineStartContent = b.skipSpaces(from: 0)
        while i < n {
            let c = b[i]
            if C.isSpace(c) { i += 1; continue }

            // Preprocessor: the directive word (and for #include its argument).
            if spec.preprocessor, c == C.hash, i == lineStartContent {
                var j = b.skipSpaces(from: i + 1)
                while j < n, C.isIdent(b[j]) { j += 1 }
                t.add(i, j, .preprocessor)
                i = j
                continue
            }

            // Line comments.
            var isLineComment = false
            for lc in spec.lineComments where b.has(lc, at: i) {
                if spec.lineCommentNeedsWordBoundary, i > 0, !C.isSpace(b[i - 1]) { continue }
                isLineComment = true
                break
            }
            if isLineComment { t.add(i, n, .comment); return }

            // Block comments.
            if let bc = spec.blockComment, b.has(bc.open, at: i) {
                var depth = 1
                let end = scanBlockComment(b, from: i + bc.open.count, close: bc.close, open: bc.open, depth: &depth)
                t.add(i, end, .comment)
                i = end
                if depth > 0 { state = 1 | UInt32(depth) << 8; return }
                continue
            }

            // Strings.
            var matchedString = false
            for (k, rule) in spec.strings.enumerated() where b.has(rule.open, at: i) {
                let (end, closed) = scanString(b, from: i + rule.open.count, rule: rule)
                t.add(i, end, .string)
                i = end
                if !closed {
                    if rule.multiline { state = 2 | UInt32(k) << 8 }
                    return
                }
                matchedString = true
                break
            }
            if matchedString { continue }

            if C.isDigit(c) || (c == C.dot && i + 1 < n && C.isDigit(b[i + 1]) && (i == 0 || !C.isIdent(b[i - 1]))) {
                let end = b.scanNumber(from: i)
                t.add(i, end, .number)
                i = end
                continue
            }

            if c == C.at, spec.atAttributes || spec.atVariables, i + 1 < n {
                var j = i + 1
                if spec.atVariables, j < n, b[j] == C.at { j += 1 }
                if j < n, C.isIdentStart(b[j]) {
                    while j < n, C.isIdent(b[j]) || b[j] == C.dot && spec.atAttributes { j += 1 }
                    t.add(i, j, spec.atAttributes ? .attribute : .variable)
                    i = j
                    continue
                }
            }

            if c == C.dollar, spec.dollarVariables, i + 1 < n {
                var j = i + 1
                if b[j] == C.lbrace {
                    while j < n, b[j] != C.rbrace { j += 1 }
                    j = min(n, j + 1)
                } else if C.isIdentStart(b[j]) {
                    while j < n, C.isIdent(b[j]) { j += 1 }
                } else {
                    j += 1 // $1, $?, $@, $#
                }
                t.add(i, j, .variable)
                i = j
                continue
            }

            if c == C.hash, spec.hashKeywords, i + 1 < n, C.isIdentStart(b[i + 1]) {
                var j = i + 1
                while j < n, C.isIdent(b[j]) { j += 1 }
                t.add(i, j, .keyword)
                i = j
                continue
            }

            if c == C.colon, spec.colonSymbols, i + 1 < n, C.isIdentStart(b[i + 1]),
               i == 0 || (b[i - 1] != C.colon && !C.isIdent(b[i - 1])) {
                var j = i + 1
                while j < n, C.isIdent(b[j]) { j += 1 }
                t.add(i, j, .constant)
                i = j
                continue
            }

            if C.isIdentStart(c) || (spec.dollarInIdentifiers && c == C.dollar) {
                var j = i + 1
                while j < n, C.isIdent(b[j]) || (spec.dollarInIdentifiers && b[j] == C.dollar) { j += 1 }
                if spec.predicateSuffix, j < n, b[j] == C.question || b[j] == C.bang,
                   !(j + 1 < n && b[j + 1] == C.eq) { j += 1 }
                // A keyword after "." is a member (foo.default), not a keyword.
                let afterDot = i > 0 && b[i - 1] == C.dot
                if !afterDot, spec.keywords.contains(b, i, j) {
                    t.add(i, j, .keyword)
                } else if spec.constants.contains(b, i, j) {
                    t.add(i, j, .constant)
                } else if spec.types.contains(b, i, j) || (spec.capitalizedAreTypes && c >= C.A && c <= C.Z) {
                    t.add(i, j, .type)
                } else if j < n, b[j] == C.lparen {
                    t.add(i, j, .function)
                }
                i = j
                continue
            }
            i += 1
        }
    }

    /// Scans to the end of a block comment; `depth` is how many are open
    /// on entry and on exit (0 = closed).
    private func scanBlockComment(_ b: UnsafeBufferPointer<UInt16>, from: Int, close: [UInt16], open: [UInt16],
                                  depth: inout Int) -> Int {
        var i = from
        while i < b.count {
            if b.has(close, at: i) {
                depth -= 1
                i += close.count
                if depth == 0 { return i }
            } else if spec.nestedBlockComments, b.has(open, at: i) {
                depth += 1
                i += open.count
            } else {
                i += 1
            }
        }
        return b.count
    }

    /// Scans to the end of a string body; returns the end and whether the
    /// closing delimiter was found on this line.
    private func scanString(_ b: UnsafeBufferPointer<UInt16>, from: Int, rule: StringRule) -> (Int, Bool) {
        var i = from
        while i < b.count {
            if rule.escapes, b[i] == C.backslash { i += 2; continue }
            if b.has(rule.close, at: i) { return (i + rule.close.count, true) }
            i += 1
        }
        return (b.count, false)
    }
}
