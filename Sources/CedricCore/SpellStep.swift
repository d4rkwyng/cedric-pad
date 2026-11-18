import Foundation

/// One flagged word in the document.
public struct SpellStepItem: Equatable, Sendable {
    public var range: NSRange
    public let word: String

    public init(range: NSRange, word: String) {
        self.range = range
        self.word = word
    }
}

/// An edit the step-through wants made: replace `range` with `replacement`.
public struct SpellStepEdit: Equatable, Sendable {
    public let range: NSRange
    public let replacement: String
}

/// Edit › Spelling and Grammar › Fix Typos… (and the owl's "Fix Typos…"):
/// the pure part of stepping through the misspelled words one at a time.
///
/// The words come in order from the caret to the end, then from the top
/// back to the caret (one pass). The document is scanned in chunks
/// (`chunks`), so a huge document is never checked in one go: the app
/// asks for the next chunk only when it needs more words (large mode) or
/// in idle run-loop turns. Offsets of everything not yet visited follow
/// every edit, the step-through's own (Change, Change All) and the user's
/// (typing in the document while the panel is open, ⌘Z).
public struct SpellStepper: Sendable {
    /// Where the pass started (moves with edits before it).
    public private(set) var anchor: Int
    /// Found and not visited yet, in pass order.
    public private(set) var pending: [SpellStepItem] = []
    /// The word shown now.
    public private(set) var current: SpellStepItem?
    /// Words passed: changed, skipped or ignored.
    public private(set) var visited = 0
    public private(set) var changed = 0
    /// Ignore All (this document) and Learn Word: never shown again in this pass.
    public private(set) var ignored: Set<String> = []
    /// Change All: later occurrences, as they are found, are changed too.
    public private(set) var changeAll: [String: String] = [:]
    /// Chunks not scanned yet, in pass order.
    public private(set) var unscanned: [NSRange]

    public var scanComplete: Bool { unscanned.isEmpty }
    /// Nothing more to show.
    public var isFinished: Bool { current == nil && pending.isEmpty && scanComplete }

    public init(anchor: Int, chunks: [NSRange]) {
        self.anchor = anchor
        self.unscanned = chunks
    }

    /// A pass over `text` from `caret`: the start of the word the caret is
    /// in, then chunks of at most `chunkLength` to the end and from the
    /// top back to there.
    public init(text: NSString, caret: Int, chunkLength: Int = 16_384) {
        let a = Self.wordStart(text, min(max(0, caret), text.length))
        self.init(anchor: a, chunks: Self.chunks(text, from: a, to: text.length, chunkLength: chunkLength)
                                + Self.chunks(text, from: 0, to: a, chunkLength: chunkLength))
    }

    /// Back to the start of the word at `offset` (at most 256 characters).
    static func wordStart(_ text: NSString, _ offset: Int) -> Int {
        var s = offset
        let ws = CharacterSet.whitespacesAndNewlines
        while s > 0, offset - s < 256, let u = UnicodeScalar(text.character(at: s - 1)), !ws.contains(u) { s -= 1 }
        return s
    }

    /// `from..<to` cut into pieces of at most `chunkLength`, each ending
    /// after a newline when there is one in its second half, else after
    /// whitespace, so no word is cut (a single "word" longer than half a
    /// chunk may be).
    public static func chunks(_ text: NSString, from: Int, to: Int, chunkLength: Int) -> [NSRange] {
        var out: [NSRange] = []
        var s = from
        let limit = max(16, chunkLength)
        while s < to {
            var e = min(to, s + limit)
            if e < to {
                let half = s + limit / 2
                var nl = -1, sp = -1
                var i = e
                while i > half {
                    let c = text.character(at: i - 1)
                    if c == 10 || c == 13 { nl = i; break }
                    if sp < 0, c == 32 || c == 9 { sp = i }
                    i -= 1
                }
                if nl > 0 { e = nl } else if sp > 0 { e = sp }
            }
            out.append(NSRange(location: s, length: e - s))
            s = e
        }
        return out
    }

    /// The next chunk to scan (removed from `unscanned`).
    public mutating func nextChunk() -> NSRange? {
        unscanned.isEmpty ? nil : unscanned.removeFirst()
    }

    func key(_ loc: Int) -> (Int, Int) { loc >= anchor ? (0, loc) : (1, loc) }

    /// Words found in a scanned chunk. Ignored words are dropped; words
    /// with a Change All rule are changed at once: the returned edits
    /// (offsets already applied here) are for the app to make, last first.
    @discardableResult
    public mutating func add(_ found: [SpellStepItem]) -> [SpellStepEdit] {
        var auto: [SpellStepItem] = []
        for item in found where !ignored.contains(item.word) {
            if changeAll[item.word] != nil { auto.append(item); continue }
            guard !pending.contains(where: { $0.range == item.range }), current?.range != item.range else { continue }
            let k = key(item.range.location)
            let i = pending.firstIndex { key($0.range.location) > k } ?? pending.count
            pending.insert(item, at: i)
        }
        return replace(auto)
    }

    /// Shows the next word (nil: none found yet, or finished).
    @discardableResult
    public mutating func advance() -> SpellStepItem? {
        current = pending.isEmpty ? nil : pending.removeFirst()
        return current
    }

    /// Skip: on to the next word.
    public mutating func skip() {
        guard current != nil else { return }
        visited += 1
        current = nil
    }

    /// Ignore All (or Learn Word): this word is passed everywhere.
    public mutating func ignoreAll() {
        guard let c = current else { return }
        ignored.insert(c.word)
        let n = pending.count
        pending.removeAll { $0.word == c.word }
        visited += 1 + (n - pending.count)
        current = nil
    }

    /// Change: the edit for the current word.
    public mutating func change(to replacement: String) -> SpellStepEdit? {
        guard let c = current else { return nil }
        current = nil
        pendingReplacement = replacement
        return replace([c]).first
    }

    /// Change All: the current word and every found occurrence of it,
    /// last first (apply them in this order, as one undo step). Later
    /// occurrences found by the scan come back from `add`.
    public mutating func changeAll(to replacement: String) -> [SpellStepEdit] {
        guard let c = current else { return [] }
        changeAll[c.word] = replacement
        current = nil
        var items = [c]
        items += pending.filter { $0.word == c.word }
        pending.removeAll { $0.word == c.word }
        return replace(items)
    }

    /// Replaces `items` (with the current word's replacement for each word),
    /// last first, adjusting every offset.
    private mutating func replace(_ items: [SpellStepItem]) -> [SpellStepEdit] {
        var edits: [SpellStepEdit] = []
        for item in items.sorted(by: { $0.range.location > $1.range.location }) {
            guard let rep = pendingReplacement ?? changeAll[item.word] else { continue }
            edits.append(SpellStepEdit(range: item.range, replacement: rep))
        }
        pendingReplacement = nil
        for e in edits { textEdited(e.range, newLength: (e.replacement as NSString).length) }
        visited += edits.count
        changed += edits.count
        return edits
    }

    /// Change's replacement, for `replace`.
    private var pendingReplacement: String?

    /// The text changed: `oldRange` (in the text before) now holds
    /// `newLength` characters. Words after it move; words it touched are
    /// dropped (the current one too: the app shows the next); chunks it
    /// touched grow or shrink with it.
    public mutating func textEdited(_ oldRange: NSRange, newLength: Int) {
        let loc = oldRange.location, end = NSMaxRange(oldRange)
        let delta = newLength - oldRange.length
        func moved(_ r: NSRange) -> NSRange? {
            if NSMaxRange(r) <= loc && !(r.length == 0 && r.location == loc) { return r }
            if r.location >= end { return NSRange(location: r.location + delta, length: r.length) }
            return nil
        }
        pending = pending.compactMap { p in moved(p.range).map { SpellStepItem(range: $0, word: p.word) } }
        if let c = current { current = moved(c.range).map { SpellStepItem(range: $0, word: c.word) } }
        unscanned = unscanned.compactMap { r in
            if let m = moved(r) { return m }
            let s = min(r.location, loc), e = max(NSMaxRange(r), end) + delta
            return e > s ? NSRange(location: s, length: e - s) : nil
        }
        if anchor >= end { anchor += delta } else if anchor > loc { anchor = loc }
    }

    /// "N of M": the current word's number and how many there are so far
    /// (`final` once the whole document has been scanned).
    public var progress: (index: Int, total: Int, final: Bool) {
        let shown = current == nil ? 0 : 1
        return (visited + shown, visited + shown + pending.count, scanComplete)
    }
}
