import Foundation

/// PowerShell (.ps1, .psm1, .psd1): `#` and `<# … #>` comments (with the
/// comment-based help keywords `.SYNOPSIS`, `.PARAMETER` … picked out),
/// `'…'` literal and `"…"` expandable strings (`$var`, `${var}`,
/// `$env:PATH` and `$( … )` subexpressions coloured inside, nested to any
/// depth on one line), here-strings `@' … '@` / `@" … "@`, variables,
/// Verb-Noun cmdlets (approved verbs), `-Parameter`s, `-eq` / `-like` …
/// operators, keywords, `[type]` literals, `[Attribute(…)]`s and numbers
/// with `KB` / `MB` … suffixes. Keywords and operators are matched without
/// case, as PowerShell does.
///
/// State: 0 normal; 1 inside `<# … #>`; 2 inside a `'…'` string that runs
/// over the line end; 3 the same for `"…"`; 4 inside `@' … '@`; 5 inside
/// `@" … "@`. A `$( … )` subexpression left open at a line end inside a
/// string isn't carried: the next line continues the string.
public struct PowerShellTokenizer: Tokenizer {
    public init() {}
    public var carriesState: Bool { true }

    static let keywords = WordSet(["begin", "break", "catch", "class", "clean", "continue", "data", "define", "do",
        "dynamicparam", "else", "elseif", "end", "enum", "exit", "filter", "finally", "for", "foreach", "from",
        "function", "hidden", "if", "in", "inlinescript", "parallel", "param", "process", "return", "sequence",
        "static", "switch", "throw", "trap", "try", "until", "using", "var", "while", "workflow", "configuration"],
        caseInsensitive: true)

    /// `-eq`, `-like`, … (with the `c` / `i` case variants of the comparisons).
    static let operators: WordSet = {
        let compare = ["eq", "ne", "gt", "ge", "lt", "le", "like", "notlike", "match", "notmatch", "contains",
                       "notcontains", "in", "notin", "replace", "split"]
        var words = compare + compare.map { "c" + $0 } + compare.map { "i" + $0 }
        words += ["is", "isnot", "as", "and", "or", "xor", "not", "band", "bor", "bxor", "bnot", "shl", "shr", "f", "join"]
        return WordSet(words, caseInsensitive: true)
    }()

    /// `Get-Verb`'s approved verbs, plus the core cmdlets whose verbs aren't (ForEach-Object, Sort-Object, Tee-Object).
    static let verbs = WordSet(["Add", "Approve", "Assert", "Backup", "Block", "Build", "Checkpoint", "Clear", "Close",
        "Compare", "Complete", "Compress", "Confirm", "Connect", "Convert", "ConvertFrom", "ConvertTo", "Copy", "Debug",
        "Deny", "Deploy", "Disable", "Disconnect", "Dismount", "Edit", "Enable", "Enter", "Exit", "Expand", "Export",
        "Find", "Format", "Get", "Grant", "Group", "Hide", "Import", "Initialize", "Install", "Invoke", "Join", "Limit",
        "Lock", "Measure", "Merge", "Mount", "Move", "New", "Open", "Optimize", "Out", "Ping", "Pop", "Protect",
        "Publish", "Push", "Read", "Receive", "Redo", "Register", "Remove", "Rename", "Repair", "Request", "Reset",
        "Resize", "Resolve", "Restart", "Restore", "Resume", "Revoke", "Save", "Search", "Select", "Send", "Set",
        "Show", "Skip", "Split", "Start", "Step", "Stop", "Submit", "Suspend", "Switch", "Sync", "Test", "Trace",
        "Unblock", "Undo", "Uninstall", "Unlock", "Unprotect", "Unpublish", "Unregister", "Update", "Use", "Wait",
        "Watch", "Where", "Write", "ForEach", "Sort", "Tee"], caseInsensitive: true)

    static let constants = WordSet(["true", "false", "null"], caseInsensitive: true)

    /// Comment-based help keywords: `.SYNOPSIS` at the start of a comment line.
    static let helpKeywords = WordSet(["SYNOPSIS", "DESCRIPTION", "PARAMETER", "EXAMPLE", "INPUTS", "OUTPUTS", "NOTES",
        "LINK", "COMPONENT", "ROLE", "FUNCTIONALITY", "FORWARDHELPTARGETNAME", "FORWARDHELPCATEGORY",
        "REMOTEHELPRUNSPACE", "EXTERNALHELP"], caseInsensitive: true)

    static let backtick: UInt16 = 96, caret: UInt16 = 94
    /// PowerShell takes the typographic quotes as quotes too.
    @inline(__always) static func isDQ(_ c: UInt16) -> Bool { c == C.quote || c == 0x201C || c == 0x201D || c == 0x201E }
    @inline(__always) static func isSQ(_ c: UInt16) -> Bool { c == C.apos || c == 0x2018 || c == 0x2019 || c == 0x201A || c == 0x201B }

    public func tokenize(_ b: UnsafeBufferPointer<UInt16>, state: inout UInt32, into t: inout [Token]) {
        let n = b.count
        var i = 0
        switch state {
        case 1:
            let (end, closed) = blockComment(b, from: 0, commentStart: 0, keywordFrom: 0, into: &t)
            if !closed { return }
            state = 0
            i = end
        case 2:
            let (end, closed) = literal(b, from: 0, start: 0, into: &t)
            if !closed { return }
            state = 0
            i = end
        case 3:
            let (end, closed) = expandable(b, from: 0, start: 0, quoteEnds: true, into: &t)
            if !closed { return }
            state = 0
            i = end
        case 4, 5:
            // The closing '@ / "@ must start the line.
            if n >= 2, b[1] == C.at, state == 4 ? Self.isSQ(b[0]) : Self.isDQ(b[0]) {
                t.add(0, 2, .string)
                state = 0
                i = 2
            } else {
                if state == 4 { t.add(0, n, .string) } else { _ = expandable(b, from: 0, start: 0, quoteEnds: false, into: &t) }
                return
            }
        default:
            state = 0
        }
        _ = code(b, from: i, nested: false, state: &state, into: &t)
    }

    // MARK: Code

    /// Tokenizes code from `start`. `nested`: inside a string's `$( … )`,
    /// stop after the `)` that closes it (returns its end and true); a
    /// construct left open at the line end then changes no state.
    private func code(_ b: UnsafeBufferPointer<UInt16>, from start: Int, nested: Bool, state: inout UInt32,
                      into t: inout [Token]) -> (Int, Bool) {
        let n = b.count
        var i = start
        var depth = 0
        // The previous significant word was `function` / `filter` / `class` …: the next word is its name.
        var nameNext = false
        while i < n {
            let c = b[i]
            if C.isSpace(c) { i += 1; continue }
            let prev: UInt16? = i > 0 ? b[i - 1] : nil

            // Comments: `<#` anywhere, `#` at the start of a token.
            if c == C.lt, i + 1 < n, b[i + 1] == C.hash {
                let (end, closed) = blockComment(b, from: i + 2, commentStart: i, keywordFrom: i + 2, into: &t)
                if !closed { if !nested { state = 1 }; return (n, false) }
                i = end
                continue
            }
            if c == C.hash, prev.map({ C.isSpace($0) || Self.tokenBreak($0) }) ?? true {
                lineComment(b, from: i, into: &t)
                return (n, false)
            }

            // Here-strings: @' or @" with nothing after it on the line.
            if c == C.at, i + 1 < n, Self.isSQ(b[i + 1]) || Self.isDQ(b[i + 1]), b.skipSpaces(from: i + 2) == n {
                t.add(i, n, .string)
                if !nested { state = Self.isSQ(b[i + 1]) ? 4 : 5 }
                return (n, false)
            }

            // Strings.
            if Self.isSQ(c) {
                let (end, closed) = literal(b, from: i + 1, start: i, into: &t)
                if !closed { if !nested { state = 2 }; return (n, false) }
                i = end
                continue
            }
            if Self.isDQ(c) {
                let (end, closed) = expandable(b, from: i + 1, start: i, quoteEnds: true, into: &t)
                if !closed { if !nested { state = 3 }; return (n, false) }
                i = end
                continue
            }

            // Variables: $x, ${any name}, $env:PATH, $script:x, $_, $?, $$, $^; @splat.
            if c == C.dollar, i + 1 < n, b[i + 1] != C.lparen {
                if let end = Self.variableEnd(b, at: i) {
                    let isConstant = b[i + 1] != C.lbrace && Self.constants.contains(b, i + 1, end)
                    t.add(i, end, isConstant ? .constant : .variable)
                    i = end
                    continue
                }
            }
            if c == C.at, i + 1 < n, C.isIdentStart(b[i + 1]), prev.map({ !C.isIdent($0) }) ?? true {
                var j = i + 1
                while j < n, C.isIdent(b[j]) { j += 1 }
                t.add(i, j, .variable)
                i = j
                continue
            }

            // Brackets: subexpressions count towards the closing `)` of a nested run.
            if c == C.lparen { depth += 1; i += 1; continue }
            if c == C.rparen {
                if nested, depth == 0 { return (i + 1, true) }
                depth = max(0, depth - 1)
                i += 1
                continue
            }
            if c == C.lbracket, let end = typeOrAttribute(b, at: i, into: &t) {
                i = end
                continue
            }

            // -Parameter and -operator.
            if c == C.minus, i + 1 < n, C.isAlpha(b[i + 1]), prev.map({ !C.isIdent($0) && $0 != C.rbracket }) ?? true {
                var j = i + 1
                while j < n, C.isIdent(b[j]) || b[j] == C.minus && j + 1 < n && C.isAlpha(b[j + 1]) { j += 1 }
                if Self.operators.contains(b, i + 1, j) {
                    t.add(i, j, .keyword)
                } else {
                    // -Name, or -Name: (a switch given a value).
                    t.add(i, j, .attribute)
                }
                i = j
                continue
            }

            // Numbers: 42, 0x1F, 1.5e3, 10KB, 1MB, 3L, 1d.
            if C.isDigit(c) || (c == C.dot && i + 1 < n && C.isDigit(b[i + 1])), prev.map({ !C.isIdent($0) }) ?? true {
                let end = b.scanNumber(from: i)
                t.add(i, end, .number)
                i = end
                continue
            }

            if C.isIdentStart(c) {
                var j = i + 1
                while j < n, C.isIdent(b[j]) { j += 1 }
                let afterMember = prev == C.dot || (prev == C.colon && i > 1 && b[i - 2] == C.colon)
                // Verb-Noun: Get-ChildItem, ConvertTo-Json, Microsoft.PowerShell.Utility\Write-Host.
                if j + 1 < n, b[j] == C.minus, C.isAlpha(b[j + 1]), !afterMember {
                    var k = j + 1
                    while k < n, C.isIdent(b[k]) || (b[k] == C.minus && k + 1 < n && C.isAlpha(b[k + 1])) { k += 1 }
                    if Self.verbs.contains(b, i, j) || nameNext {
                        t.add(i, k, .function)
                        nameNext = false
                        i = k
                        continue
                    }
                }
                if nameNext {
                    t.add(i, j, .function)
                    nameNext = false
                } else if !afterMember, Self.keywords.contains(b, i, j) {
                    t.add(i, j, .keyword)
                    nameNext = Self.namesNext(b, i, j)
                } else if afterMember, j < n, b[j] == C.lparen {
                    t.add(i, j, .function)
                }
                i = j
                continue
            }
            nameNext = false
            i += 1
        }
        return (n, false)
    }

    /// Characters after which `#` starts a comment even without a space.
    @inline(__always) static func tokenBreak(_ c: UInt16) -> Bool {
        c == C.semicolon || c == C.lparen || c == C.lbrace || c == C.rbrace || c == C.pipe || c == C.comma || c == C.eq
    }

    /// `function`, `filter`, `workflow`, `class`, `enum`, `configuration`: a name follows.
    static let namers = WordSet(["function", "filter", "workflow", "class", "enum", "configuration"], caseInsensitive: true)
    static func namesNext(_ b: UnsafeBufferPointer<UInt16>, _ i: Int, _ j: Int) -> Bool { namers.contains(b, i, j) }

    /// The end of the variable starting with `$` at `i`, or nil (a lone `$`).
    static func variableEnd(_ b: UnsafeBufferPointer<UInt16>, at i: Int) -> Int? {
        let n = b.count
        var j = i + 1
        guard j < n else { return nil }
        let c = b[j]
        if c == C.lbrace {
            // ${any name}: ends at the first unescaped }.
            j += 1
            while j < n, b[j] != C.rbrace { j += b[j] == backtick ? 2 : 1 }
            return min(n, j + 1)
        }
        if c == C.question || c == caret || c == C.dollar { return j + 1 }
        guard C.isIdentStart(c) else { return nil }
        while j < n, C.isIdent(b[j]) { j += 1 }
        // A scope or drive: $env:PATH, $script:count, $global:x (not $a::b).
        if j + 1 < n, b[j] == C.colon, C.isIdentStart(b[j + 1]) {
            j += 1
            while j < n, C.isIdent(b[j]) { j += 1 }
        }
        return j
    }

    /// `[string]`, `[int[]]`, `[System.Collections.Generic.List[string]]`
    /// as a type; `[CmdletBinding(…)]` / `[Parameter(…)]` with the name as
    /// an attribute (the arguments are tokenized as code). Nil for an index
    /// (`$a[0]`, `$h['k']`) or anything else.
    private func typeOrAttribute(_ b: UnsafeBufferPointer<UInt16>, at i: Int, into t: inout [Token]) -> Int? {
        let n = b.count
        // After a name, `)` or `}` it is an index. After `]` it may be either
        // (`[Parameter()][string]$x`, `$a[0][1]`): a name inside makes it a type.
        if i > 0, C.isIdent(b[i - 1]) || b[i - 1] == C.rparen || b[i - 1] == C.rbrace || b[i - 1] == C.dollar {
            return nil
        }
        var j = b.skipSpaces(from: i + 1)
        guard j < n, C.isIdentStart(b[j]) else { return nil }
        let nameStart = j
        while j < n, C.isIdent(b[j]) || b[j] == C.dot || b[j] == Self.backtick { j += 1 }
        let nameEnd = j
        j = b.skipSpaces(from: j)
        guard j < n else { return nil }
        if b[j] == C.lparen {
            t.add(nameStart, nameEnd, .attribute)
            return nameEnd
        }
        // A type: names, dots, commas and nested [] up to the balancing ].
        var depth = 1
        while j < n {
            let c = b[j]
            if c == C.lbracket { depth += 1 } else if c == C.rbracket {
                depth -= 1
                if depth == 0 { t.add(i, j + 1, .type); return j + 1 }
            } else if !(C.isIdent(c) || c == C.dot || c == C.comma || C.isSpace(c) || c == Self.backtick) {
                return nil
            }
            j += 1
        }
        return nil
    }

    // MARK: Strings

    /// A `'…'` string's body from `from` (`''` is a quote); `start` is
    /// where the colouring begins.
    private func literal(_ b: UnsafeBufferPointer<UInt16>, from: Int, start: Int, into t: inout [Token]) -> (Int, Bool) {
        let n = b.count
        var i = from
        while i < n {
            if Self.isSQ(b[i]) {
                if i + 1 < n, Self.isSQ(b[i + 1]) { i += 2; continue }
                t.add(start, i + 1, .string)
                return (i + 1, true)
            }
            i += 1
        }
        t.add(start, n, .string)
        return (n, false)
    }

    /// A `"…"` string's body (or a `@"` here-string line, `quoteEnds`
    /// false): backtick escapes, `""`, and `$var` / `${…}` / `$( … )`
    /// coloured as variables and code.
    private func expandable(_ b: UnsafeBufferPointer<UInt16>, from: Int, start: Int, quoteEnds: Bool,
                            into t: inout [Token]) -> (Int, Bool) {
        let n = b.count
        var i = from
        var run = start
        while i < n {
            let c = b[i]
            if c == Self.backtick { i += 2; continue }
            if quoteEnds, Self.isDQ(c) {
                if i + 1 < n, Self.isDQ(b[i + 1]) { i += 2; continue }
                t.add(run, i + 1, .string)
                return (i + 1, true)
            }
            if c == C.dollar, i + 1 < n {
                if b[i + 1] == C.lparen {
                    t.add(run, i, .string)
                    t.add(i, i + 2, .variable)
                    var ignored: UInt32 = 0
                    let (end, closed) = code(b, from: i + 2, nested: true, state: &ignored, into: &t)
                    if closed { t.add(end - 1, end, .variable) }
                    i = end
                    run = end
                    continue
                }
                if let end = Self.variableEnd(b, at: i) {
                    t.add(run, i, .string)
                    t.add(i, end, .variable)
                    i = end
                    run = end
                    continue
                }
            }
            i += 1
        }
        t.add(run, n, .string)
        return (n, false)
    }

    // MARK: Comments

    /// A `<# … #>` comment from `from`; `commentStart` is where its colour
    /// starts. A help keyword at the first non-space from `keywordFrom`
    /// (the line start, or just after `<#`) is picked out.
    private func blockComment(_ b: UnsafeBufferPointer<UInt16>, from: Int, commentStart: Int, keywordFrom: Int,
                              into t: inout [Token]) -> (Int, Bool) {
        let n = b.count
        var end = n, closed = false
        var i = from
        while i + 1 < n {
            if b[i] == C.hash, b[i + 1] == C.gt { end = i + 2; closed = true; break }
            i += 1
        }
        commentWithHelp(b, from: commentStart, keywordSearch: keywordFrom, to: end, into: &t)
        return (end, closed)
    }

    private func lineComment(_ b: UnsafeBufferPointer<UInt16>, from i: Int, into t: inout [Token]) {
        commentWithHelp(b, from: i, keywordSearch: i + 1, to: b.count, into: &t)
    }

    /// Colours `from..<to` as a comment, with a `.KEYWORD` found at the
    /// first non-space after `keywordSearch` as a keyword.
    private func commentWithHelp(_ b: UnsafeBufferPointer<UInt16>, from: Int, keywordSearch: Int, to: Int, into t: inout [Token]) {
        let k = b.skipSpaces(from: keywordSearch)
        if k + 1 < to, b[k] == C.dot, C.isAlpha(b[k + 1]) {
            var j = k + 1
            while j < to, C.isAlpha(b[j]) { j += 1 }
            if Self.helpKeywords.contains(b, k + 1, j) {
                t.add(from, k, .comment)
                t.add(k, j, .keyword)
                t.add(j, to, .comment)
                return
            }
        }
        t.add(from, to, .comment)
    }
}

/// The functions, filters, classes and enums of a PowerShell script, for
/// the outline sidebar (as `MarkdownOutline.Heading`s: level 1, or 2 for
/// one indented inside another block). Skips block comments and here-strings.
public enum PowerShellOutline {
    private static let re = try! NSRegularExpression(
        pattern: #"^([ \t]*)(?i:function|filter|workflow|class|enum|configuration)[ \t]+([A-Za-z_][\w.-]*(?::[\w-]+)?)"#)

    public static func entries(in text: String, limit: Int = .max) -> [MarkdownOutline.Heading] {
        var out: [MarkdownOutline.Heading] = []
        var lineNo = -1
        var inComment = false
        var hereClose: String?
        text.enumerateLines { line, stop in
            lineNo += 1
            if let close = hereClose {
                if line.hasPrefix(close) { hereClose = nil }
                return
            }
            if inComment {
                if line.contains("#>") { inComment = false }
                return
            }
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("<#") {
                if !t.dropFirst(2).contains("#>") { inComment = true }
                return
            }
            if t.hasSuffix("@'") { hereClose = "'@" } else if t.hasSuffix("@\"") { hereClose = "\"@" }
            let ns = line as NSString
            guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return }
            let indented = m.range(at: 1).length > 0
            out.append(MarkdownOutline.Heading(level: indented ? 2 : 1, title: ns.substring(with: m.range(at: 2)), line: lineNo))
            if out.count >= limit { stop = true }
        }
        return out
    }
}
