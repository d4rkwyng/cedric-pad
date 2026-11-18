import Foundation

/// Windows batch files (.bat, .cmd): `REM` and `::` comments, `:labels`,
/// `%var%`, `%1`, `%~dp0`, `%%i` and `!var!` variables, `"strings"`, the
/// commands and keywords (`echo`, `set`, `if`, `goto`, `call`, `for`,
/// `equ`, `errorlevel`, …, without case) and the `@` that silences a line.
/// Every line stands alone: no state.
public struct BatchTokenizer: Tokenizer {
    public init() {}
    public var carriesState: Bool { false }

    static let keywords = WordSet(["if", "else", "goto", "call", "exit", "for", "in", "do", "set", "setlocal", "endlocal",
        "echo", "not", "exist", "defined", "errorlevel", "equ", "neq", "lss", "leq", "gtr", "geq", "shift", "pause",
        "start", "cd", "chdir", "pushd", "popd", "title", "cls", "choice", "enabledelayedexpansion",
        "disabledelayedexpansion", "enableextensions", "disableextensions", "copy", "xcopy", "robocopy", "move", "del",
        "erase", "mkdir", "md", "rmdir", "rd", "ren", "rename", "type", "find", "findstr", "timeout", "cmd", "color",
        "ver", "path", "prompt", "assoc", "ftype", "where", "dir", "attrib", "break", "verify", "vol", "on", "off",
        "nul", "con", "aux", "prn"], caseInsensitive: true)
    private static let rem = Array("rem".utf16)

    public func tokenize(_ b: UnsafeBufferPointer<UInt16>, state: inout UInt32, into t: inout [Token]) {
        let n = b.count
        var i = b.skipSpaces(from: 0)
        guard i < n else { return }
        // `::` comments, `:label`.
        if b[i] == C.colon {
            if i + 1 < n, b[i + 1] == C.colon { t.add(i, n, .comment); return }
            var j = i + 1
            while j < n, !C.isSpace(b[j]) { j += 1 }
            t.add(i, j, .tag)
            return
        }
        if b[i] == C.at { t.add(i, i + 1, .punctuation); i += 1 }
        // REM (also `@rem`), followed by a space or the line end.
        if b.has(Self.rem, at: i, caseInsensitive: true), i + 3 == n || C.isSpace(b[i + 3]) || b[i + 3] == C.dot {
            t.add(i, n, .comment)
            return
        }
        while i < n {
            let c = b[i]
            if c == C.percent || c == C.bang, let end = Self.variableEnd(b, at: i) {
                t.add(i, end, .variable)
                i = end
                continue
            }
            if c == C.quote {
                // A string runs to the closing quote; variables inside are still coloured.
                var j = i + 1
                var run = i
                while j < n, b[j] != C.quote {
                    if b[j] == C.percent || b[j] == C.bang, let end = Self.variableEnd(b, at: j) {
                        t.add(run, j, .string)
                        t.add(j, end, .variable)
                        j = end
                        run = end
                        continue
                    }
                    j += 1
                }
                j = min(n, j + 1)
                t.add(run, j, .string)
                i = j
                continue
            }
            // `& rem …` after a command.
            if c == C.amp {
                let k = b.skipSpaces(from: i + 1)
                if b.has(Self.rem, at: k, caseInsensitive: true), k + 3 == n || C.isSpace(b[k + 3]) { t.add(k, n, .comment); return }
            }
            if C.isDigit(c), i == 0 || !C.isIdent(b[i - 1]) {
                var j = i
                while j < n, C.isDigit(b[j]) { j += 1 }
                if j == n || !C.isIdent(b[j]) { t.add(i, j, .number) }
                i = j
                continue
            }
            if C.isIdentStart(c) {
                var j = i
                while j < n, C.isIdent(b[j]) { j += 1 }
                // A word, not part of a path or a switch (/b, C:\dir, file.txt).
                let alone = (i == 0 || !(b[i - 1] == C.slash || b[i - 1] == C.backslash || b[i - 1] == C.dot || b[i - 1] == C.minus || b[i - 1] == C.colon))
                    && (j == n || !(b[j] == C.backslash || b[j] == C.dot || b[j] == C.colon))
                if alone, Self.keywords.contains(b, i, j) { t.add(i, j, .keyword) }
                i = j
                continue
            }
            if c == C.slash, i + 1 < n, C.isAlpha(b[i + 1]), i == 0 || C.isSpace(b[i - 1]) {
                // A switch: /b, /i, /f.
                var j = i + 1
                while j < n, C.isIdent(b[j]) { j += 1 }
                t.add(i, j, .attribute)
                i = j
                continue
            }
            i += 1
        }
    }

    /// The end of `%name%`, `%1`, `%*`, `%~dp0`, `%%i` or `!name!` at `i`, or nil.
    static func variableEnd(_ b: UnsafeBufferPointer<UInt16>, at i: Int) -> Int? {
        let n = b.count
        guard i + 1 < n else { return nil }
        let c = b[i]
        if c == C.percent {
            let d = b[i + 1]
            if d == C.percent { return i + 2 < n && C.isAlpha(b[i + 2]) ? i + 3 : nil } // %%i
            if C.isDigit(d) || d == C.star { return i + 2 }                               // %1, %*
            if d == C.tilde {                                                             // %~dp0, %~nx1
                var j = i + 2
                while j < n, C.isAlpha(b[j]) { j += 1 }
                return j < n && (C.isDigit(b[j]) || b[j] == C.star) ? j + 1 : nil
            }
        }
        // %name% / !name!: a name without spaces at the ends, closed on the line.
        var j = i + 1
        while j < n, b[j] != c {
            if b[j] == C.quote { return nil }
            j += 1
        }
        guard j < n, j > i + 1, !C.isSpace(b[i + 1]) else { return nil }
        return j + 1
    }
}

/// Windows registry exports (.reg): the `Windows Registry Editor Version
/// 5.00` / `REGEDIT4` header, `;` comments, `[HKEY_…\Key]` sections (and
/// `[-HKEY…]` deletions), `"name"=` and `@=` value names, `"string"`
/// values, `dword:` / `qword:` / `hex(…):` types with their digits, and
/// the hex-byte lines a long value continues on.
public struct RegistryTokenizer: Tokenizer {
    public init() {}
    public var carriesState: Bool { false }
    private static let header1 = Array("Windows Registry Editor".utf16), header2 = Array("REGEDIT".utf16)

    public func tokenize(_ b: UnsafeBufferPointer<UInt16>, state: inout UInt32, into t: inout [Token]) {
        let n = b.count
        let i = b.skipSpaces(from: 0)
        guard i < n else { return }
        let c = b[i]
        if c == C.semicolon { t.add(i, n, .comment); return }
        if b.has(Self.header1, at: i) || b.has(Self.header2, at: i) { t.add(i, n, .keyword); return }
        if c == C.lbracket {
            var j = n
            while j > i, b[j - 1] != C.rbracket { j -= 1 }
            t.add(i, j > i ? j : n, .tag)
            return
        }
        if c == C.quote || c == C.at {
            // The value name.
            var j = i + 1
            if c == C.quote {
                while j < n, b[j] != C.quote { j += b[j] == C.backslash ? 2 : 1 }
                j = min(n, j + 1)
            }
            t.add(i, j, .key)
            guard j < n, b[j] == C.eq else { return }
            value(b, from: j + 1, into: &t)
            return
        }
        // A continuation line of hex bytes: `  00,01,ff,\`.
        if C.isDigit(c) || (C.lower(c) >= C.a && C.lower(c) <= 102) {
            var j = i
            while j < n, Self.isHexListChar(b[j]) { j += 1 }
            if j == n || b[j] == C.backslash { t.add(i, n, .number) }
        }
    }

    private func value(_ b: UnsafeBufferPointer<UInt16>, from start: Int, into t: inout [Token]) {
        let n = b.count
        let i = b.skipSpaces(from: start)
        guard i < n else { return }
        if b[i] == C.quote {
            var j = i + 1
            while j < n, b[j] != C.quote { j += b[j] == C.backslash ? 2 : 1 }
            t.add(i, min(n, j + 1), .string)
            return
        }
        if b[i] == C.minus { t.add(i, i + 1, .keyword); return } // "name"=- deletes the value
        // dword:0000002a, qword:…, hex:…, hex(2):…
        var j = i
        while j < n, b[j] != C.colon { j += 1 }
        guard j < n else { return }
        t.add(i, j + 1, .type)
        t.add(j + 1, n, .number)
    }

    @inline(__always) static func isHexListChar(_ c: UInt16) -> Bool {
        C.isDigit(c) || (C.lower(c) >= C.a && C.lower(c) <= 102) || c == C.comma || C.isSpace(c)
    }
}
