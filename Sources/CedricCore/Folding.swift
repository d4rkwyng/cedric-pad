import Foundation

/// How a language's text folds (Text › Folding).
public enum FoldKind: Sendable, Equatable {
    /// No folding: plain text, CSV, diff, batch, .reg, HTML/XML (tags are
    /// for a later version).
    case none
    /// `{ }`, `[ ]`, `( )` outside strings and comments, plus multi-line
    /// block comments.
    case brackets
    /// A line followed by deeper-indented lines.
    case indentation
    /// INI / TOML `[section]` headers, each to the next.
    case sections
    /// Markdown ATX headings, each to the next heading of the same or a
    /// higher level, outside fenced code.
    case headings
}

extension Language {
    public var foldKind: FoldKind {
        switch self {
        case .swift, .javascript, .typescript, .c, .css, .json, .powershell: return .brackets
        case .python, .yaml, .shell, .ruby, .sql: return .indentation
        case .ini: return .sections
        case .markdown: return .headings
        case .plain, .csv, .diff, .batch, .registry, .html, .xml: return .none
        }
    }
}

/// A foldable region: the header line stays visible, lines
/// `header + 1 … last` hide.
public struct FoldRegion: Equatable, Sendable {
    public var header: Int
    public var last: Int
    /// 1 for an outermost region (set by `allRegions`; 0 otherwise).
    public var depth: Int

    public init(header: Int, last: Int, depth: Int = 0) {
        self.header = header
        self.last = last
        self.depth = depth
    }
}

/// Finds fold regions on demand. Nothing is precomputed: "does line L
/// start a region?" reads line L (and, for indentation, the next non-blank
/// line); the region's end is found only when it is folded, by a forward
/// scan bounded to `scanLimit` lines. `allRegions` (Fold All, Fold to
/// Level) is one linear pass.
///
/// Brackets and block comments come from the highlighter's tokens, so a
/// brace in a string or a comment never counts; the app passes its tab's
/// `HighlightEngine`, whose start-of-line states are already cached for
/// the visible lines. Not thread-safe (main thread, like the engine).
public final class FoldScanner {
    public static let scanLimit = 50_000
    /// The highlighter colours (and so tokenizes) only the first 20,000
    /// characters of a line; brackets past that aren't counted either.
    static let lineLimit = 20_000

    public let language: Language
    public let kind: FoldKind
    let text: NSString
    let index: LineIndex
    let engine: HighlightEngine
    let inFence: ((Int) -> Bool)?
    let tabWidth: Int
    private var tokens: [Token] = []
    private var units: [UInt16] = []

    public init(language: Language, text: NSString, index: LineIndex, engine: HighlightEngine? = nil,
                inFence: ((Int) -> Bool)? = nil, tabWidth: Int = 4) {
        self.language = language
        kind = language.foldKind
        self.text = text
        self.index = index
        self.engine = engine.flatMap { $0.language == language ? $0 : nil } ?? HighlightEngine(language: language)
        self.inFence = inFence
        self.tabWidth = max(1, tabWidth)
    }

    // MARK: Questions per line

    /// Whether line `line` starts a region (cheap: this line, and for
    /// indentation the next non-blank one). The region may still turn out
    /// empty (a bracket closed on the next line); `region(at:)` says.
    public func startsRegion(_ line: Int) -> Bool {
        guard line >= 0, line < index.lineCount else { return false }
        switch kind {
        case .none: return false
        case .brackets:
            let s = scanBrackets(line)
            return s.open > 0 || (s.endsInComment && !endsInComment(line - 1))
        case .indentation: return !startsInString(line) && indentStart(line) != nil
        case .sections: return isSection(line)
        case .headings: return headingLevel(line) != nil
        }
    }

    /// The region line `line` starts, its end found by a forward scan;
    /// nil when it starts none, it would hide nothing, or the end is more
    /// than `scanLimit` lines away.
    public func region(at line: Int) -> FoldRegion? {
        guard line >= 0, line < index.lineCount else { return nil }
        let r: FoldRegion?
        switch kind {
        case .none: r = nil
        case .brackets: r = bracketRegion(line)
        case .indentation: r = startsInString(line) ? nil : indentRegion(line, indents: nil, continuation: nil)
        case .sections: r = sectionRegion(line, sections: nil)
        case .headings: r = headingRegion(line)
        }
        guard let r, r.last > r.header else { return nil }
        return r
    }

    /// The innermost region that holds line `line` in its hidden part, or
    /// starts on it, looking up at most `scanLimit` lines.
    public func enclosingRegion(of line: Int, excluding skip: (FoldRegion) -> Bool = { _ in false }) -> FoldRegion? {
        if startsRegion(line), let r = region(at: line), !skip(r) { return r }
        var l = line - 1
        let stop = max(0, line - Self.scanLimit)
        while l >= stop {
            if startsRegion(l), let r = region(at: l), r.last >= line, !skip(r) { return r }
            l -= 1
        }
        return nil
    }

    // MARK: Every region (Fold All, Fold to Level)

    /// Every region, sorted by header, with its nesting depth (1 = outermost).
    public func allRegions() -> [FoldRegion] {
        var out: [FoldRegion] = []
        switch kind {
        case .none: return []
        case .brackets: out = allBracketRegions()
        case .indentation:
            let n = index.lineCount
            var indents = [Int?](repeating: nil, count: n)
            for l in 0..<n { indents[l] = indent(l) }
            let cont = language == .python ? pythonContinuations() : nil
            for l in 0..<n where cont?[l] != true && indentStart(l, indents: indents) != nil {
                if let r = indentRegion(l, indents: indents, continuation: cont), r.last > l { out.append(r) }
            }
        case .sections:
            let n = index.lineCount
            let sections = (0..<n).filter(isSection)
            for l in sections { if let r = sectionRegion(l, sections: sections), r.last > l { out.append(r) } }
        case .headings: out = allHeadingRegions()
        }
        out.sort { $0.header < $1.header }
        // Depth: how many regions hold each one (regions nest or are disjoint).
        var stack: [Int] = []
        for i in out.indices {
            while let top = stack.last, top < out[i].header { stack.removeLast() }
            out[i].depth = stack.count + 1
            stack.append(out[i].last)
        }
        return out
    }

    // MARK: Lines

    private func loadUnits(_ line: Int) -> Int {
        let r = index.contentRange(ofLine: line)
        let len = min(r.length, Self.lineLimit)
        if units.count < len { units = [UInt16](repeating: 0, count: max(len, 256)) }
        if len > 0 { units.withUnsafeMutableBufferPointer { text.getCharacters($0.baseAddress!, range: NSRange(location: r.location, length: len)) } }
        return len
    }

    /// Leading whitespace width (tabs to `tabWidth` stops); nil for a blank line.
    func indent(_ line: Int) -> Int? {
        let r = index.contentRange(ofLine: line)
        var w = 0
        var i = r.location
        let end = NSMaxRange(r)
        while i < end {
            let c = text.character(at: i)
            if c == 32 { w += 1 } else if c == 9 { w = (w / tabWidth + 1) * tabWidth } else if c == 13 { } else { return w }
            i += 1
        }
        return nil
    }

    private func firstNonSpace(_ line: Int) -> (UInt16, Int)? {
        let r = index.contentRange(ofLine: line)
        var i = r.location
        while i < NSMaxRange(r) {
            let c = text.character(at: i)
            if c != 32 && c != 9 { return (c, i - r.location) }
            i += 1
        }
        return nil
    }

    // MARK: Brackets and block comments

    private static let skipKinds: Set<TokenKind> = [.string, .comment, .key]

    /// The line's brackets outside strings and comments: how many of its
    /// openers are still open at its end, and whether it ends inside a
    /// block comment.
    private func scanBrackets(_ line: Int, visit: ((Int) -> Void)? = nil) -> (open: Int, endsInComment: Bool) {
        let states = engine.lineTokens(line, in: text, index: index, into: &tokens)
        let len = loadUnits(line)
        var depth = 0
        var t = 0
        var i = 0
        while i < len {
            while t < tokens.count, tokens[t].end <= i { t += 1 }
            if t < tokens.count, tokens[t].start <= i, Self.skipKinds.contains(tokens[t].kind) {
                i = tokens[t].end
                continue
            }
            let c = units[i]
            if c == C.lbrace || c == C.lbracket || c == C.lparen {
                depth += 1
                visit?(1)
            } else if c == C.rbrace || c == C.rbracket || c == C.rparen {
                if depth > 0 { depth -= 1 }
                visit?(-1)
            }
            i += 1
        }
        return (depth, lineEndsInComment(len: len, states: states))
    }

    /// Ends inside a block comment: the line's last token is a comment that
    /// runs to its end and the tokenizer carries a state to the next line.
    /// A blank line keeps the line above's answer (a short look up).
    private func lineEndsInComment(len: Int, states: (start: UInt32, end: UInt32)) -> Bool {
        guard states.end != 0 else { return false }
        if let last = tokens.last { return last.kind == .comment && last.end >= len }
        return false
    }

    func endsInComment(_ line: Int) -> Bool {
        var l = line
        var steps = 0
        while l >= 0, steps < 1000 {
            let states = engine.lineTokens(l, in: text, index: index, into: &tokens)
            guard states.end != 0 else { return false }
            if !tokens.isEmpty {
                let len = min(index.contentRange(ofLine: l).length, Self.lineLimit)
                return lineEndsInComment(len: len, states: states)
            }
            // Blank (or token-less) line with a state open: as the line above.
            if states.start != states.end { return false }
            l -= 1
            steps += 1
        }
        return false
    }

    private func bracketRegion(_ line: Int) -> FoldRegion? {
        let s = scanBrackets(line)
        if s.open > 0 {
            var depth = s.open
            let stop = min(index.lineCount, line + 1 + Self.scanLimit)
            var m = line + 1
            while m < stop {
                var closedAt = false
                _ = scanBrackets(m) { d in
                    guard !closedAt else { return }
                    depth += d
                    if depth == 0 { closedAt = true }
                }
                if closedAt { return FoldRegion(header: line, last: m - 1) }
                m += 1
            }
            return nil
        }
        if s.endsInComment, !endsInComment(line - 1) { return commentRegion(line) }
        return nil
    }

    /// A block comment from `line`: through its closing line when nothing
    /// but whitespace follows the close, else up to the line before.
    private func commentRegion(_ line: Int) -> FoldRegion? {
        let stop = min(index.lineCount, line + 1 + Self.scanLimit)
        var m = line + 1
        while m < stop {
            if !endsInComment(m) {
                _ = engine.lineTokens(m, in: text, index: index, into: &tokens)
                let len = loadUnits(m)
                var closeEnd = 0
                if let c = tokens.first(where: { $0.kind == .comment }) { closeEnd = c.end }
                var restBlank = true
                var i = closeEnd
                while i < len { if units[i] != 32 && units[i] != 9 && units[i] != 13 { restBlank = false; break }; i += 1 }
                return FoldRegion(header: line, last: restBlank ? m : m - 1)
            }
            m += 1
        }
        return nil
    }

    private func allBracketRegions() -> [FoldRegion] {
        var out: [FoldRegion] = []
        // Open brackets: the line each opened on, and whether it is the
        // region opener of that line (the outermost still open at its end).
        var stack: [(line: Int, region: Bool)] = []
        var commentStart: Int?
        var prevInComment = false
        let n = index.lineCount
        for l in 0..<n {
            let s = scanBrackets(l) { d in
                if d > 0 {
                    stack.append((l, false))
                } else if let top = stack.popLast(), top.region, l - 1 > top.line {
                    out.append(FoldRegion(header: top.line, last: l - 1))
                }
            }
            // The lowest bracket this line left open (they sit on top of the stack).
            var k = stack.count
            while k > 0, stack[k - 1].line == l { k -= 1 }
            if k < stack.count { stack[k].region = true }
            // Block comments: a run of lines ending inside one.
            var inComment = s.endsInComment
            if !inComment, tokens.isEmpty, prevInComment {
                // A blank line inside a comment carries the state on.
                let st = engine.lineTokens(l, in: text, index: index, into: &tokens)
                inComment = st.end != 0 && st.start == st.end
            }
            if inComment, !prevInComment, s.open == 0 { commentStart = l }
            if !inComment, prevInComment, let c = commentStart {
                commentStart = nil
                if let r = commentRegion(c), r.last > c { out.append(r) }
            }
            if !inComment { commentStart = nil }
            prevInComment = inComment
        }
        return out
    }

    // MARK: Indentation

    /// The line's indent when the next non-blank line is deeper (YAML: or
    /// a "- " item under a "key:" at the same indent).
    private func indentStart(_ line: Int, indents: [Int?]? = nil) -> Int? {
        func ind(_ l: Int) -> Int? { indents.map { $0[l] } ?? indent(l) }
        guard let i = ind(line) else { return nil }
        let stop = min(index.lineCount, line + 1 + 1000)
        var m = line + 1
        while m < stop {
            if let j = ind(m) {
                if j > i { return i }
                if j == i, yamlListUnderKey(line, m) { return i }
                return nil
            }
            m += 1
        }
        return nil
    }

    private func yamlListUnderKey(_ key: Int, _ item: Int) -> Bool {
        guard language == .yaml else { return false }
        let k = index.contentRange(ofLine: key)
        let trimmed = text.substring(with: k).trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(":"), !trimmed.hasPrefix("-") else { return false }
        guard let (c, at) = firstNonSpace(item), c == C.minus else { return false }
        let r = index.contentRange(ofLine: item)
        return r.length == at + 1 || (at + 1 < r.length && (text.character(at: r.location + at + 1) == 32 || text.character(at: r.location + at + 1) == 9))
    }

    private func isYAMLItem(_ line: Int, indent i: Int) -> Bool {
        guard let (c, at) = firstNonSpace(line), c == C.minus, at == i else { return false }
        let r = index.contentRange(ofLine: line)
        return r.length == at + 1 || text.character(at: r.location + at + 1) == 32
    }

    /// Python: lines that start inside a triple-quoted string belong to
    /// the block above whatever their indent.
    private func pythonContinuations() -> [Bool] {
        let n = index.lineCount
        var out = [Bool](repeating: false, count: n)
        for l in 0..<n { out[l] = engine.lineTokens(l, in: text, index: index, into: &tokens).start != 0 }
        return out
    }

    /// Python: the line starts inside a triple-quoted string.
    private func startsInString(_ line: Int) -> Bool {
        language == .python && engine.lineTokens(line, in: text, index: index, into: &tokens).start != 0
    }

    private func indentRegion(_ line: Int, indents: [Int?]?, continuation: [Bool]?) -> FoldRegion? {
        func ind(_ l: Int) -> Int? { indents.map { $0[l] } ?? indent(l) }
        guard let i = indentStart(line, indents: indents) else { return nil }
        let listUnderKey = language == .yaml && {
            var m = line + 1
            while m < index.lineCount, ind(m) == nil { m += 1 }
            return m < index.lineCount && ind(m) == i && yamlListUnderKey(line, m)
        }()
        var last = line
        let stop = min(index.lineCount, line + 1 + Self.scanLimit)
        var m = line + 1
        while m < stop {
            let inString = language == .python && (continuation.map { $0[m] } ?? (engine.lineTokens(m, in: text, index: index, into: &tokens).start != 0))
            if inString { last = m; m += 1; continue }
            guard let j = ind(m) else { m += 1; continue }
            if j > i || (listUnderKey && j == i && isYAMLItem(m, indent: i)) { last = m; m += 1; continue }
            return FoldRegion(header: line, last: last)
        }
        return m >= index.lineCount ? FoldRegion(header: line, last: last) : nil
    }

    // MARK: INI / TOML sections

    func isSection(_ line: Int) -> Bool {
        guard let (c, _) = firstNonSpace(line), c == C.lbracket else { return false }
        return text.substring(with: index.contentRange(ofLine: line)).trimmingCharacters(in: .whitespaces).hasSuffix("]")
    }

    private func lastNonBlank(from end: Int, above header: Int) -> Int {
        var l = end
        while l > header, indent(l) == nil { l -= 1 }
        return l
    }

    private func sectionRegion(_ line: Int, sections: [Int]?) -> FoldRegion? {
        guard isSection(line) else { return nil }
        var next = index.lineCount
        if let sections, let k = sections.firstIndex(where: { $0 > line }) {
            next = sections[k]
        } else if sections == nil {
            let stop = min(index.lineCount, line + 1 + Self.scanLimit)
            var m = line + 1
            while m < stop, !isSection(m) { m += 1 }
            if m == stop, stop < index.lineCount { return nil }
            next = m
        }
        return FoldRegion(header: line, last: lastNonBlank(from: next - 1, above: line))
    }

    // MARK: Markdown headings

    /// The ATX heading level (1–6) of a line outside fenced code, else nil.
    func headingLevel(_ line: Int) -> Int? {
        let r = index.contentRange(ofLine: line)
        guard r.length > 0 else { return nil }
        var i = r.location
        let end = NSMaxRange(r)
        var spaces = 0
        while i < end, text.character(at: i) == 32, spaces < 4 { i += 1; spaces += 1 }
        guard spaces <= 3, i < end, text.character(at: i) == C.hash else { return nil }
        var level = 0
        while i < end, text.character(at: i) == C.hash { level += 1; i += 1 }
        guard level <= 6, i == end || text.character(at: i) == 32 || text.character(at: i) == 9 else { return nil }
        if let inFence, inFence(line) { return nil }
        return level
    }

    private func headingRegion(_ line: Int) -> FoldRegion? {
        guard let h = headingLevel(line) else { return nil }
        let stop = min(index.lineCount, line + 1 + Self.scanLimit)
        var m = line + 1
        while m < stop {
            if let k = headingLevel(m), k <= h { break }
            m += 1
        }
        if m == stop, stop < index.lineCount { return nil }
        return FoldRegion(header: line, last: lastNonBlank(from: m - 1, above: line))
    }

    private func allHeadingRegions() -> [FoldRegion] {
        var out: [FoldRegion] = []
        var stack: [(line: Int, level: Int)] = []
        func close(before next: Int) {
            let top = stack.removeLast()
            let last = lastNonBlank(from: next - 1, above: top.line)
            if last > top.line { out.append(FoldRegion(header: top.line, last: last)) }
        }
        for l in 0..<index.lineCount {
            guard let h = headingLevel(l) else { continue }
            while let top = stack.last, top.level >= h { close(before: l) }
            stack.append((l, h))
        }
        while !stack.isEmpty { close(before: index.lineCount) }
        return out
    }
}

/// The folded regions of a document, as character ranges: each from the
/// start of the line after its header to the end of its last hidden line
/// (newline included). Folds may nest (an inner fold stays folded inside
/// an outer one). `hidden` is their union, merged, for the per-paragraph
/// "is this hidden?" question during layout (a binary search).
public struct FoldState: Equatable, Sendable {
    public private(set) var folds: [NSRange] = []
    public private(set) var hidden: [NSRange] = []

    public init(_ folds: [NSRange] = []) {
        for f in folds { add(f) }
    }

    public var isEmpty: Bool { folds.isEmpty }

    public mutating func add(_ r: NSRange) {
        guard r.length > 0, !folds.contains(r) else { return }
        folds.append(r)
        folds.sort { $0.location != $1.location ? $0.location < $1.location : $0.length > $1.length }
        rebuild()
    }

    public mutating func remove(_ r: NSRange) {
        folds.removeAll { $0 == r }
        rebuild()
    }

    public mutating func removeAll() {
        folds = []
        hidden = []
    }

    private mutating func rebuild() {
        var out: [NSRange] = []
        for f in folds {
            if let last = out.last, f.location <= NSMaxRange(last) {
                out[out.count - 1] = NSUnionRange(last, f)
            } else {
                out.append(f)
            }
        }
        hidden = out
    }

    /// The merged hidden range holding `offset`, if any.
    public func hiddenRange(containing offset: Int) -> NSRange? {
        var lo = 0, hi = hidden.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = hidden[mid]
            if offset < r.location { hi = mid - 1 } else if offset >= NSMaxRange(r) { lo = mid + 1 } else { return r }
        }
        return nil
    }

    public func isHidden(_ offset: Int) -> Bool { hiddenRange(containing: offset) != nil }

    /// A caret at `p` would be in hidden text. `length`: the document's;
    /// `endsWithNewline`: whether it ends in "\n" (then the end is the
    /// empty last line, visible; else the end of the last line).
    public func caretIsHidden(_ p: Int, length: Int, endsWithNewline: Bool) -> NSRange? {
        if let h = hiddenRange(containing: p) { return h }
        if p == length, !endsWithNewline, let h = hidden.last, NSMaxRange(h) == length { return h }
        return nil
    }

    /// Where a caret moved by a key to `p` (from `old`) goes: past the
    /// hidden text in the direction it moved, to the line after it (or
    /// the end of the header line when nothing visible follows).
    public func navigationTarget(_ p: Int, from old: Int, length: Int, endsWithNewline: Bool) -> Int {
        guard let h = caretIsHidden(p, length: length, endsWithNewline: endsWithNewline) else { return p }
        let after = NSMaxRange(h)
        if p >= old, after < length || (after == length && endsWithNewline) { return after }
        return max(0, h.location - 1)
    }

    /// The folds a selection change to `range` should open: those holding
    /// one of its ends (a whole fold inside a selection stays folded).
    public func foldsToOpen(for range: NSRange, length: Int, endsWithNewline: Bool) -> [NSRange] {
        var out: [NSRange] = []
        func take(_ inside: (NSRange) -> Bool) {
            for f in folds where inside(f) && !out.contains(f) { out.append(f) }
        }
        let s = range.location, e = NSMaxRange(range)
        if range.length == 0 {
            guard caretIsHidden(s, length: length, endsWithNewline: endsWithNewline) != nil else { return [] }
            take { ($0.location <= s && s < NSMaxRange($0)) || (s == length && NSMaxRange($0) == length) }
            return out
        }
        // A selection's start in hidden text, or its end strictly inside a fold.
        if isHidden(s) { take { $0.location <= s && s < NSMaxRange($0) } }
        take { $0.location < e && e < NSMaxRange($0) }
        return out
    }

    /// Follows an edit that replaced `oldRange` with `newLength`
    /// characters. Folds after it stay, folds before it shift, and a fold
    /// the edit touches opens: inside it, across its header line's
    /// newline, or a line break typed at the end of its header line.
    /// Text appended at the end of a document whose last fold runs to
    /// the end opens it too (it would join the hidden last line).
    /// Returns whether anything opened.
    @discardableResult
    public mutating func adjust(oldRange: NSRange, newLength: Int, insertsNewline: Bool, oldLength: Int) -> Bool {
        guard !folds.isEmpty else { return false }
        let delta = newLength - oldRange.length
        let a = oldRange.location, b = NSMaxRange(oldRange)
        var opened = false
        var out: [NSRange] = []
        for f in folds {
            let headerEnd = f.location - 1 // the header line's "\n"
            if b <= headerEnd && !(oldRange.length == 0 && a == headerEnd && insertsNewline) {
                out.append(NSRange(location: f.location + delta, length: f.length))
            } else if a >= NSMaxRange(f) && !(a == oldLength && NSMaxRange(f) == oldLength) {
                out.append(f)
            } else {
                opened = true
            }
        }
        folds = out
        rebuild()
        return opened
    }
}
