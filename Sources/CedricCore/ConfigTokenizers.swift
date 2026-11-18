import Foundation

/// Unified diffs and patches: file headers (`diff`, `---`, `+++`), hunk
/// headers (`@@ … @@`), added and removed lines, and git's metadata lines.
/// Every line is classified by its first characters alone: no state.
public struct DiffTokenizer: Tokenizer {
    public init() {}
    public var carriesState: Bool { false }
    private static let meta = ["diff ", "index ", "new file", "deleted file", "similarity", "rename ", "old mode", "new mode",
                               "Binary files", "Only in ", "\\ No newline"].map { Array($0.utf16) }
    private static let minus3 = Array("--- ".utf16), plus3 = Array("+++ ".utf16), at2 = Array("@@".utf16)

    public func tokenize(_ b: UnsafeBufferPointer<UInt16>, state: inout UInt32, into t: inout [Token]) {
        let n = b.count
        guard n > 0 else { return }
        if b.has(Self.minus3, at: 0) || b.has(Self.plus3, at: 0) || (n == 3 && (b.has(Array("---".utf16), at: 0) || b.has(Array("+++".utf16), at: 0))) {
            t.add(0, n, .heading)
        } else if b.has(Self.at2, at: 0) {
            // "@@ -1,4 +1,5 @@ func context": the range in one colour, the context plain.
            var end = n
            if let close = b.find(Self.at2, from: 2) { end = close + 2 }
            t.add(0, end, .type)
        } else if b[0] == C.plus {
            t.add(0, n, .function)
        } else if b[0] == C.minus {
            t.add(0, n, .keyword)
        } else if Self.meta.contains(where: { b.has($0, at: 0) }) {
            t.add(0, n, .comment)
        }
    }
}

/// INI, TOML, .env, .properties and git-config style files: comments (`#`,
/// `;`), `[section]` / `[[table]]` headers, `key = value` / `key: value` /
/// `KEY=value` (with `export`), and in values strings, numbers and
/// true/false. TOML's multi-line strings aren't tracked (each line is
/// coloured on its own).
public struct INITokenizer: Tokenizer {
    public init() {}
    public var carriesState: Bool { false }
    private static let constants = WordSet(["true", "false", "yes", "no", "on", "off", "null", "none", "inf", "nan"], caseInsensitive: true)
    private static let export = Array("export".utf16)

    public func tokenize(_ b: UnsafeBufferPointer<UInt16>, state: inout UInt32, into t: inout [Token]) {
        let n = b.count
        var i = b.skipSpaces(from: 0)
        guard i < n else { return }
        let c = b[i]
        if c == C.hash || c == C.semicolon { t.add(i, n, .comment); return }
        if c == C.lbracket {
            var j = i
            while j < n, b[j] != C.hash, b[j] != C.semicolon || j == i { j += 1 }
            var end = j
            while end > i, C.isSpace(b[end - 1]) { end -= 1 }
            t.add(i, end, .tag)
            if j < n { t.add(j, n, .comment) }
            return
        }
        // `export KEY=value` (.env, shell-style).
        if b.has(Self.export, at: i), i + 6 < n, C.isSpace(b[i + 6]) {
            t.add(i, i + 6, .keyword)
            i = b.skipSpaces(from: i + 6)
        }
        // The key: up to "=" or ":" (quoted TOML keys allowed).
        var j = i
        while j < n, b[j] != C.eq, b[j] != C.colon {
            if b[j] == C.quote || b[j] == C.apos {
                let q = b[j]; j += 1
                while j < n, b[j] != q { j += 1 }
            }
            j += 1
        }
        guard j < n else { return } // no separator: a bare line (INI flags), left plain
        var keyEnd = j
        while keyEnd > i, C.isSpace(b[keyEnd - 1]) { keyEnd -= 1 }
        t.add(i, keyEnd, .key)
        value(b, from: j + 1, into: &t)
    }

    private func value(_ b: UnsafeBufferPointer<UInt16>, from start: Int, into t: inout [Token]) {
        let n = b.count
        var i = start
        while i < n {
            let c = b[i]
            if c == C.quote || c == C.apos {
                var j = i + 1
                while j < n, b[j] != c { j += (c == C.quote && b[j] == C.backslash) ? 2 : 1 }
                j = min(n, j + 1)
                t.add(i, j, .string)
                i = j
            } else if c == C.hash, i == start || C.isSpace(b[i - 1]) {
                t.add(i, n, .comment)
                return
            } else if c == C.dollar, i + 1 < n, b[i + 1] == C.lbrace || C.isIdentStart(b[i + 1]) {
                var j = i + 1
                if b[j] == C.lbrace { while j < n, b[j] != C.rbrace { j += 1 }; j = min(n, j + 1) } else { while j < n, C.isIdent(b[j]) { j += 1 } }
                t.add(i, j, .variable)
                i = j
            } else if C.isDigit(c) || ((c == C.minus || c == C.plus) && i + 1 < n && C.isDigit(b[i + 1])) {
                let wordStart = i == start || !C.isIdent(b[i - 1])
                let end = b.scanNumber(from: C.isDigit(c) ? i : i + 1)
                if wordStart { t.add(i, end, .number) }
                i = max(end, i + 1)
            } else if C.isAlpha(c) {
                var j = i
                while j < n, C.isIdent(b[j]) { j += 1 }
                if Self.constants.contains(b, i, j), i == start || !C.isIdent(b[i - 1]) {
                    // Only a whole value word ("true", not "trueish").
                    t.add(i, j, .constant)
                }
                i = j
            } else {
                i += 1
            }
        }
    }
}
