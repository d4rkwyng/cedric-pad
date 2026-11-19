import Foundation

/// Multiple carets and column selection (0.2.0): the pure model behind
/// `EditorTextView`'s multi-caret layer. Carets are UTF-16 ranges into an
/// LF-normalised text; an empty range is a caret. Everything here is text in,
/// carets and edits out, so the editing rules are unit-tested without a view.
///
/// Edits at several carets are worked out against the text as it is, then
/// applied by the view from the last to the first (so earlier offsets stay
/// valid), each as its own storage edit (docs/architecture.md, Multiple carets).
public enum MultiCaret {
    /// The most carets Select All Occurrences makes (and ⌘D adds up to).
    public static let maxCarets = 10_000
    /// The cap in large-document mode, where every storage edit costs more.
    public static let maxCaretsLarge = 1_000

    /// One caret or selection. `anchor` stays put while ⇧-moves move `head`.
    /// `goalColumn`: the visual column ↑/↓ aim for (kept across short lines).
    public struct Caret: Equatable, Sendable {
        public var anchor: Int
        public var head: Int
        public var goalColumn: Int?

        public init(anchor: Int, head: Int, goalColumn: Int? = nil) {
            self.anchor = anchor
            self.head = head
            self.goalColumn = goalColumn
        }

        public init(_ range: NSRange) { self.init(anchor: range.location, head: NSMaxRange(range)) }

        public init(at offset: Int) { self.init(anchor: offset, head: offset) }

        public var range: NSRange { NSRange(location: min(anchor, head), length: abs(head - anchor)) }
        public var isEmpty: Bool { anchor == head }
    }

    // MARK: Normalising

    /// Sorted by position, with overlapping selections merged, carets at
    /// the same place merged, and a caret touching a selection merged into
    /// it. `primary` (an index into `carets`) follows to the caret that
    /// absorbed it.
    public static func normalize(_ carets: [Caret], primary: Int = 0) -> (carets: [Caret], primary: Int) {
        guard carets.count > 1 else { return (carets, 0) }
        let order = carets.indices.sorted {
            let a = carets[$0].range, b = carets[$1].range
            return a.location != b.location ? a.location < b.location : a.length < b.length
        }
        var out: [Caret] = []
        out.reserveCapacity(carets.count)
        var newPrimary = 0
        for i in order {
            let c = carets[i]
            let r = c.range
            if let last = out.last {
                let lr = last.range
                let end = NSMaxRange(lr)
                if r.location < end || (r.location == end && (r.length == 0 || lr.length == 0)) {
                    let u = NSUnionRange(lr, r)
                    let forward = last.anchor <= last.head
                    out[out.count - 1] = forward ? Caret(anchor: u.location, head: NSMaxRange(u), goalColumn: last.goalColumn)
                        : Caret(anchor: NSMaxRange(u), head: u.location, goalColumn: last.goalColumn)
                    if i == primary { newPrimary = out.count - 1 }
                    continue
                }
            }
            out.append(c)
            if i == primary { newPrimary = out.count - 1 }
        }
        return (out, newPrimary)
    }

    // MARK: Edits

    /// One caret's edit: `range` (in the text before any edit) becomes
    /// `replacement`; afterwards the caret's selection is `selection`,
    /// relative to `range.location` in the edited text.
    public struct Edit: Equatable, Sendable {
        public var range: NSRange
        public var replacement: String
        public var selection: NSRange

        public init(range: NSRange, replacement: String, selection: NSRange) {
            self.range = range
            self.replacement = replacement
            self.selection = selection
        }

        /// Replaces `range` and puts the caret after the inserted text.
        public init(replacing range: NSRange, with s: String) {
            self.init(range: range, replacement: s, selection: NSRange(location: (s as NSString).length, length: 0))
        }

        /// Changes nothing (an edit that only moves the caret, or a delete at the document's start).
        public var isNoOp: Bool { range.length == 0 && replacement.isEmpty }
    }

    /// Makes `edits` (one per caret) safe to apply together: sorted by
    /// position, each clipped so it starts no earlier than the previous one
    /// ends (two carets deleting the same character delete it once).
    /// Returns them in ascending order, and each input edit's selection
    /// afterwards (in the edited text's offsets), in input order.
    public static func resolve(_ edits: [Edit]) -> (edits: [Edit], selections: [NSRange]) {
        let order = edits.indices.sorted {
            edits[$0].range.location != edits[$1].range.location ? edits[$0].range.location < edits[$1].range.location : $0 < $1
        }
        var out: [Edit] = []
        out.reserveCapacity(edits.count)
        var selections = [NSRange](repeating: NSRange(location: 0, length: 0), count: edits.count)
        var prevEnd = 0
        var delta = 0
        for i in order {
            var e = edits[i]
            if e.range.location < prevEnd {
                let end = max(prevEnd, NSMaxRange(e.range))
                e.range = NSRange(location: prevEnd, length: end - prevEnd)
            }
            prevEnd = NSMaxRange(e.range)
            let start = e.range.location + delta
            selections[i] = NSRange(location: start + e.selection.location, length: e.selection.length)
            delta += (e.replacement as NSString).length - e.range.length
            out.append(e)
        }
        return (out, selections)
    }

    /// `resolve`, then the carets the edits leave, normalised, and where
    /// the primary (an index into `edits`) went.
    public static func carets(after edits: [Edit], primary: Int) -> (edits: [Edit], carets: [Caret], primary: Int) {
        let r = resolve(edits)
        let n = normalize(r.selections.map { Caret($0) }, primary: primary)
        return (r.edits, n.carets, n.primary)
    }

    /// The edits applied to `text`, last first (what the view does, for tests).
    public static func apply(_ edits: [Edit], to text: String) -> String {
        let s = NSMutableString(string: text)
        for e in edits.reversed() where !e.isNoOp { s.replaceCharacters(in: e.range, with: e.replacement) }
        return s as String
    }

    /// `s` typed or pasted at every caret, replacing its selection.
    public static func insert(_ s: String, at carets: [Caret]) -> [Edit] {
        carets.map { Edit(replacing: $0.range, with: s) }
    }

    /// Paste: with exactly as many lines as carets (2 or more; one trailing
    /// newline ignored), one line at each caret, in order; else the whole
    /// text at every caret.
    public static func paste(_ s: String, at carets: [Caret]) -> [Edit] {
        var body = s
        if body.hasSuffix("\n") { body.removeLast() }
        let lines = body.components(separatedBy: "\n")
        guard carets.count > 1, lines.count == carets.count else { return insert(s, at: carets) }
        return zip(carets, lines).map { Edit(replacing: $0.range, with: $1) }
    }

    /// The selected text of every caret with a selection, in document
    /// order, joined with "\n" (as AppKit copies several selected ranges).
    public static func copyText(_ carets: [Caret], in text: NSString) -> String {
        carets.map(\.range).filter { $0.length > 0 && NSMaxRange($0) <= text.length }.map { text.substring(with: $0) }.joined(separator: "\n")
    }

    /// What the delete keys remove from an empty caret.
    public enum Deletion: Sendable {
        case backward, forward, wordBackward, wordForward, toLineStart, toLineEnd
    }

    /// A delete key at every caret: a selection is deleted; otherwise the
    /// composed character (or word, or line part) before or after it.
    /// `pairing`: Backspace between a just-typed pair deletes both
    /// (AutoEdit.deletesPair), as with one caret.
    public static func delete(_ kind: Deletion, at carets: [Caret], in text: NSString, lines: LineIndex,
                              language: Language = .plain, pairing: Bool = false) -> [Edit] {
        carets.map { c in
            let r = c.range
            if r.length > 0 { return Edit(replacing: r, with: "") }
            let p = r.location
            let unit: (Int) -> unichar? = { $0 >= 0 && $0 < text.length ? text.character(at: $0) : nil }
            var span: NSRange
            switch kind {
            case .backward:
                if pairing, AutoEdit.deletesPair(before: unit(p - 1), after: unit(p), language: language) {
                    span = NSRange(location: p - 1, length: 2)
                } else {
                    span = p > 0 ? text.rangeOfComposedCharacterSequence(at: p - 1) : NSRange(location: 0, length: 0)
                    span = NSRange(location: span.location, length: p - span.location)
                }
            case .forward:
                span = p < text.length ? text.rangeOfComposedCharacterSequence(at: p) : NSRange(location: p, length: 0)
            case .wordBackward:
                let s = wordLeft(p, in: text)
                span = NSRange(location: s, length: p - s)
            case .wordForward:
                span = NSRange(location: p, length: wordRight(p, in: text) - p)
            case .toLineStart:
                let start = lines.starts[lines.line(containing: p)]
                span = p > start ? NSRange(location: start, length: p - start) : (p > 0 ? NSRange(location: p - 1, length: 1) : NSRange(location: p, length: 0))
            case .toLineEnd:
                let content = lines.contentRange(ofLine: lines.line(containing: p))
                let end = NSMaxRange(content)
                span = end > p ? NSRange(location: p, length: end - p) : (p < text.length ? NSRange(location: p, length: 1) : NSRange(location: p, length: 0))
            }
            return Edit(range: span, replacement: "", selection: NSRange(location: 0, length: 0))
        }
    }

    // MARK: Moving

    public enum Motion: Sendable {
        case left, right, up, down, wordLeft, wordRight, lineStart, lineEnd, documentStart, documentEnd
    }

    /// Moves every caret (or, `extend`, every selection's head). Without
    /// `extend`, ← and → on a selection collapse it to its start or end.
    /// ↑/↓ keep a visual column (tabs to `tabWidth` stops) across short
    /// lines. Lines are logical lines: wrapped rows are not stepped through.
    public static func move(_ carets: [Caret], _ motion: Motion, extend: Bool, in text: NSString, lines: LineIndex,
                            tabWidth: Int = 4) -> [Caret] {
        let n = text.length
        return carets.map { c in
            var goal: Int?
            let target: Int
            let r = c.range
            switch motion {
            case .left:
                if !extend, r.length > 0 { target = r.location } else { target = c.head > 0 ? text.rangeOfComposedCharacterSequence(at: c.head - 1).location : 0 }
            case .right:
                if !extend, r.length > 0 { target = NSMaxRange(r) } else { target = c.head < n ? NSMaxRange(text.rangeOfComposedCharacterSequence(at: c.head)) : n }
            case .up, .down:
                let line = lines.line(containing: c.head)
                let col = c.goalColumn ?? visualColumn(of: c.head, in: text, lines: lines, tabWidth: tabWidth)
                goal = col
                let to = line + (motion == .up ? -1 : 1)
                if to < 0 { target = 0 } else if to >= lines.lineCount { target = n } else {
                    target = offset(forColumn: col, line: to, in: text, lines: lines, tabWidth: tabWidth)
                }
            case .wordLeft: target = wordLeft(c.head, in: text)
            case .wordRight: target = wordRight(c.head, in: text)
            case .lineStart: target = lines.starts[lines.line(containing: c.head)]
            case .lineEnd: target = NSMaxRange(lines.contentRange(ofLine: lines.line(containing: c.head)))
            case .documentStart: target = 0
            case .documentEnd: target = n
            }
            return extend ? Caret(anchor: c.anchor, head: target, goalColumn: goal) : Caret(anchor: target, head: target, goalColumn: goal)
        }
    }

    /// The visual column of `offset` on its line (tabs advance to the next stop).
    public static func visualColumn(of offset: Int, in text: NSString, lines: LineIndex, tabWidth: Int = 4) -> Int {
        let start = lines.starts[lines.line(containing: offset)]
        var col = 0
        var i = start
        let w = max(1, tabWidth)
        while i < offset {
            let c = text.character(at: i)
            if c == 9 { col = (col / w + 1) * w } else if !UTF16.isTrailSurrogate(c) { col += 1 }
            i += 1
        }
        return col
    }

    /// The offset on `line` nearest visual column `column` (its end when
    /// the line is shorter), never inside a composed character.
    public static func offset(forColumn column: Int, line: Int, in text: NSString, lines: LineIndex, tabWidth: Int = 4) -> Int {
        let content = lines.contentRange(ofLine: line)
        let w = max(1, tabWidth)
        var col = 0
        var i = content.location
        let end = NSMaxRange(content)
        while i < end, col < column {
            let r = text.rangeOfComposedCharacterSequence(at: i)
            let c = text.character(at: i)
            let next = c == 9 ? (col / w + 1) * w : col + 1
            // A tab that jumps past the column: stop before it if that's nearer.
            if next > column, column - col < next - column { break }
            col = next
            i = min(end, NSMaxRange(r))
        }
        return i
    }

    /// The start of the word before `p` (skipping non-word units first).
    public static func wordLeft(_ p: Int, in text: NSString) -> Int {
        var i = p
        while i > 0, !Occurrences.isWordUnit(text.character(at: i - 1)) { i -= 1 }
        while i > 0, Occurrences.isWordUnit(text.character(at: i - 1)) { i -= 1 }
        return i
    }

    /// The end of the word after `p` (skipping non-word units first).
    public static func wordRight(_ p: Int, in text: NSString) -> Int {
        var i = p
        let n = text.length
        while i < n, !Occurrences.isWordUnit(text.character(at: i)) { i += 1 }
        while i < n, Occurrences.isWordUnit(text.character(at: i)) { i += 1 }
        return i
    }

    // MARK: Adding carets

    /// ⌃⇧↑ / ⌃⇧↓: a caret on the line above the topmost caret (or below
    /// the bottommost), at its visual column (its goal column if it has
    /// one). Nil at the first or last line.
    public static func caretBeside(_ carets: [Caret], below: Bool, in text: NSString, lines: LineIndex, tabWidth: Int = 4) -> Caret? {
        guard let edge = below ? carets.max(by: { $0.head < $1.head }) : carets.min(by: { $0.head < $1.head }) else { return nil }
        let line = lines.line(containing: edge.head) + (below ? 1 : -1)
        guard line >= 0, line < lines.lineCount else { return nil }
        let col = edge.goalColumn ?? visualColumn(of: edge.head, in: text, lines: lines, tabWidth: tabWidth)
        let o = offset(forColumn: col, line: line, in: text, lines: lines, tabWidth: tabWidth)
        return Caret(anchor: o, head: o, goalColumn: col)
    }

    /// ⌘D: the next occurrence of `needle` after `after`, wrapping at the
    /// end, skipping any that overlaps an existing caret. Literal and
    /// case-sensitive; `wholeWord` when it started from a bare caret.
    public static func nextOccurrence(of needle: String, wholeWord: Bool, in text: NSString, after: Int, existing: [NSRange]) -> NSRange? {
        let len = (needle as NSString).length
        guard len > 0, text.length >= len else { return nil }
        let start = max(0, min(after, text.length))
        for (from, to) in [(start, text.length), (0, min(text.length, start + len - 1))] {
            var pos = from
            while pos < to {
                let r = text.range(of: needle, options: [.literal], range: NSRange(location: pos, length: to - pos))
                if r.location == NSNotFound { break }
                let taken = existing.contains { NSIntersectionRange($0, r).length > 0 || $0 == r }
                if !taken, !wholeWord || Occurrences.isWholeWord(r, in: text) { return r }
                pos = r.location + 1
            }
        }
        return nil
    }

    /// ⌃⌘G: every occurrence of `needle`, at most `limit`, and whether
    /// there were more.
    public static func allOccurrences(of needle: String, wholeWord: Bool, in text: NSString, limit: Int = maxCarets) -> (ranges: [NSRange], capped: Bool) {
        let all = Occurrences.findAll(Occurrences.Needle(needle, wholeWord: wholeWord), in: text, limit: limit + 1)
        return (Array(all.prefix(limit)), all.count > limit)
    }

    /// Adjusts carets for an edit not made by the multi-caret layer (an
    /// input method composing at the primary, undo): carets after the
    /// edit shift, carets inside it move to its end.
    public static func shift(_ carets: [Caret], oldRange: NSRange, newLength: Int) -> [Caret] {
        let delta = newLength - oldRange.length
        let end = NSMaxRange(oldRange)
        func f(_ k: Int) -> Int {
            if k >= end { return k + delta }
            return k <= oldRange.location ? k : oldRange.location + newLength
        }
        return carets.map { c in
            // A caret exactly at an insertion point moves with the inserted text.
            if oldRange.length == 0 {
                let a = c.anchor >= oldRange.location ? c.anchor + delta : c.anchor
                let h = c.head >= oldRange.location ? c.head + delta : c.head
                return Caret(anchor: a, head: h, goalColumn: c.goalColumn)
            }
            return Caret(anchor: f(c.anchor), head: f(c.head), goalColumn: c.goalColumn)
        }
    }
}
