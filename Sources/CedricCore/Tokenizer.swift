import Foundation

/// What a span of source text is, for colouring. Each theme maps every
/// kind to a colour; `.plain` spans are never emitted.
public enum TokenKind: UInt8, CaseIterable, Sendable {
    case plain
    case keyword
    case type
    case string
    case number
    case constant      // true, nil, None, …
    case comment
    case function      // an identifier followed by "("
    case attribute     // @attr, decorators, HTML attribute names
    case variable      // $var, @ivar, YAML anchors
    case preprocessor  // #include, #if, …
    case tag           // HTML/XML tag names, CSS selectors
    case key           // JSON/YAML keys, CSS properties
    case heading       // Markdown headings
    case emphasis      // Markdown *em*
    case strong        // Markdown **strong**
    case link          // Markdown links and URLs
    case code          // Markdown code spans and fences
    case punctuation   // Markdown list markers and quotes, YAML document markers
}

/// One coloured span, in UTF-16 offsets relative to the start of its line.
public struct Token: Equatable, Sendable {
    public var start: Int
    public var length: Int
    public var kind: TokenKind

    public init(_ start: Int, _ length: Int, _ kind: TokenKind) {
        self.start = start
        self.length = length
        self.kind = kind
    }

    public var end: Int { start + length }
}

/// A line-at-a-time tokenizer. A line is handed over without its line
/// terminator. `state` is an opaque value carried from the end of one line
/// to the start of the next (open block comments, multi-line strings,
/// code fences); 0 is "nothing open", the state at the top of a file.
///
/// Tokenizers are pure functions of (line, state), which is what makes the
/// highlighter incremental: an edit invalidates the cached states from the
/// edited line down, and colouring the visible range only needs the state
/// at its first line.
public protocol Tokenizer: Sendable {
    /// False for languages where every line starts in state 0 (JSON, YAML
    /// without block scalars, plain text). The engine then never scans
    /// lines above the visible range to find a state.
    var carriesState: Bool { get }

    func tokenize(_ line: UnsafeBufferPointer<UInt16>, state: inout UInt32, into tokens: inout [Token])

    /// The state at the top of the file (Markdown: "line 0", where a
    /// `---` opens YAML frontmatter). 0 for most languages.
    var initialState: UInt32 { get }
}

extension Tokenizer {
    public var initialState: UInt32 { 0 }
}

// MARK: - Scanning helpers shared by the tokenizers

/// UTF-16 code units for ASCII, so tokenizers can compare without Characters.
enum C {
    static let tab: UInt16 = 9, space: UInt16 = 32, bang: UInt16 = 33, quote: UInt16 = 34, hash: UInt16 = 35
    static let dollar: UInt16 = 36, percent: UInt16 = 37, amp: UInt16 = 38, apos: UInt16 = 39
    static let lparen: UInt16 = 40, rparen: UInt16 = 41, star: UInt16 = 42, plus: UInt16 = 43, comma: UInt16 = 44
    static let minus: UInt16 = 45, dot: UInt16 = 46, slash: UInt16 = 47
    static let zero: UInt16 = 48, nine: UInt16 = 57, colon: UInt16 = 58, semicolon: UInt16 = 59
    static let lt: UInt16 = 60, eq: UInt16 = 61, gt: UInt16 = 62, question: UInt16 = 63, at: UInt16 = 64
    static let A: UInt16 = 65, Z: UInt16 = 90, lbracket: UInt16 = 91, backslash: UInt16 = 92, rbracket: UInt16 = 93
    static let underscore: UInt16 = 95, backtick: UInt16 = 96, a: UInt16 = 97, z: UInt16 = 122
    static let lbrace: UInt16 = 123, pipe: UInt16 = 124, rbrace: UInt16 = 125, tilde: UInt16 = 126

    @inline(__always) static func isDigit(_ c: UInt16) -> Bool { c >= zero && c <= nine }
    @inline(__always) static func isAlpha(_ c: UInt16) -> Bool { (c >= A && c <= Z) || (c >= a && c <= z) }
    @inline(__always) static func isIdentStart(_ c: UInt16) -> Bool { isAlpha(c) || c == underscore || c > 127 }
    @inline(__always) static func isIdent(_ c: UInt16) -> Bool { isIdentStart(c) || isDigit(c) }
    @inline(__always) static func isSpace(_ c: UInt16) -> Bool { c == space || c == tab }
    @inline(__always) static func lower(_ c: UInt16) -> UInt16 { (c >= A && c <= Z) ? c + 32 : c }
}

/// A set of ASCII words, looked up straight from UTF-16 without building a
/// String: words are stored as 64-bit FNV-1a hashes of their code units.
public struct WordSet: Sendable {
    private var hashes: Set<UInt64> = []
    private let caseInsensitive: Bool

    public init(_ words: [String], caseInsensitive: Bool = false) {
        self.caseInsensitive = caseInsensitive
        for w in words {
            let units = Array(w.utf16)
            _ = units.withUnsafeBufferPointer { hashes.insert(Self.hash($0, 0, $0.count, caseInsensitive)) }
        }
    }

    @inline(__always)
    static func hash(_ b: UnsafeBufferPointer<UInt16>, _ start: Int, _ end: Int, _ ci: Bool) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        var i = start
        while i < end {
            h ^= UInt64(ci ? C.lower(b[i]) : b[i])
            h = h &* 0x100000001b3
            i += 1
        }
        return h ^ UInt64(end - start)
    }

    @inline(__always)
    public func contains(_ b: UnsafeBufferPointer<UInt16>, _ start: Int, _ end: Int) -> Bool {
        !hashes.isEmpty && hashes.contains(Self.hash(b, start, end, caseInsensitive))
    }
}

extension UnsafeBufferPointer where Element == UInt16 {
    /// Whether `pattern` occurs at `i`.
    @inline(__always)
    func has(_ pattern: [UInt16], at i: Int, caseInsensitive: Bool = false) -> Bool {
        if pattern.isEmpty || i + pattern.count > count { return false }
        for (k, p) in pattern.enumerated() {
            let c = self[i + k]
            if caseInsensitive ? C.lower(c) != p : c != p { return false }
        }
        return true
    }

    /// The first index at or after `from` where `pattern` occurs, or nil.
    func find(_ pattern: [UInt16], from: Int, caseInsensitive: Bool = false) -> Int? {
        guard !pattern.isEmpty else { return nil }
        var i = from
        let last = count - pattern.count
        while i <= last {
            if has(pattern, at: i, caseInsensitive: caseInsensitive) { return i }
            i += 1
        }
        return nil
    }

    /// The end of a number literal starting at `i` (decimal, hex, binary,
    /// octal, underscores, a fraction, an exponent and a type suffix).
    func scanNumber(from i: Int) -> Int {
        var j = i
        if j + 1 < count, self[j] == C.zero, C.isAlpha(self[j + 1]) { j += 2 } // 0x, 0b, 0o
        while j < count {
            let c = self[j]
            if C.isIdent(c) || (c == C.dot && j + 1 < count && C.isDigit(self[j + 1])) {
                // An exponent sign: 1e-5, 1E+5 (not in hex, where e is a digit).
                if (c == 101 || c == 69), j + 1 < count, self[j + 1] == C.minus || self[j + 1] == C.plus,
                   j + 2 < count, C.isDigit(self[j + 2]), !(j > i + 1 && (self[i + 1] == 120 || self[i + 1] == 88)) {
                    j += 2
                    continue
                }
                j += 1
            } else {
                break
            }
        }
        return j
    }

    func skipSpaces(from i: Int) -> Int {
        var j = i
        while j < count, C.isSpace(self[j]) { j += 1 }
        return j
    }
}

extension Array where Element == Token {
    /// Appends a span, merging it with the previous one when they touch and
    /// share a kind (keeps attribute runs few on long strings and comments).
    @inline(__always)
    mutating func add(_ start: Int, _ end: Int, _ kind: TokenKind) {
        guard end > start, kind != .plain else { return }
        if let lastToken = last, lastToken.kind == kind, lastToken.end == start {
            self[count - 1].length += end - start
        } else {
            append(Token(start, end - start, kind))
        }
    }
}

/// Plain text: no tokens, no state.
public struct PlainTokenizer: Tokenizer {
    public init() {}
    public var carriesState: Bool { false }
    public func tokenize(_ line: UnsafeBufferPointer<UInt16>, state: inout UInt32, into tokens: inout [Token]) {}
}

/// Tokenizes a String line by line, for tests and tools: returns each
/// line's tokens. The app goes through `HighlightEngine` instead.
public func tokenizeLines(_ text: String, with tokenizer: Tokenizer) -> [[Token]] {
    var state = tokenizer.initialState
    var result: [[Token]] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let units = Array(line.utf16)
        var tokens: [Token] = []
        units.withUnsafeBufferPointer { tokenizer.tokenize($0, state: &state, into: &tokens) }
        result.append(tokens)
    }
    return result
}
