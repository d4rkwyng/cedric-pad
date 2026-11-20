import Foundation

/// The command palette's matching and ranking (View › Command Palette,
/// ⇧⌘P; CommandPalette.swift in the app). Pure and Foundation only, so it
/// is unit-tested here; the app builds the candidates from the live menu.
///
/// Matching is fuzzy: the query's letters (spaces ignored, case ignored)
/// must appear in order in the title, or else in the menu path plus the
/// title ("Format › Markdown › Bold"). Each candidate gets the best-scoring
/// alignment (a small dynamic programme, not a greedy left-to-right pick),
/// so "fa" prefers the F and A of "Fold All" to the F and a of "Format".
public enum CommandMatcher {
    public struct Candidate: Sendable, Equatable {
        /// Stable identity, used for the recent list: the menu path and title.
        public var id: String
        public var title: String
        /// The menus above the item, "Edit › Text Tools" (may be empty).
        public var path: String
        public var enabled: Bool

        public init(id: String, title: String, path: String, enabled: Bool = true) {
            self.id = id
            self.title = title
            self.path = path
            self.enabled = enabled
        }
    }

    // Scores. A title match always beats a path-only match.
    static let matchPoint = 1
    static let wordStartBonus = 8
    static let consecutiveBonus = 6
    static let firstCharBonus = 10
    /// Each jump over unmatched text between two matched characters, so a
    /// run of letters beats the same letters scattered over word starts.
    static let gapPenalty = 5
    /// The whole query found as one run anywhere in the text.
    static let substringBonus = 25
    static let titleBonus = 1000
    /// The whole query typed at the start of the text, or of one of its words.
    static let prefixBonus = 60
    static let wordPrefixBonus = 30

    /// One character folded for matching, as a number: case, diacritics
    /// and width ignored (ASCII on a fast path: menu titles are mostly
    /// ASCII). Comparing numbers, not Characters, keeps a keystroke's
    /// ranking of a few hundred commands well under a millisecond.
    @inline(__always)
    static func fold(_ c: Character) -> UInt32 {
        if let a = c.asciiValue { return UInt32((a >= 65 && a <= 90) ? a + 32 : a) }
        let f = String(c).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let scalars = f.unicodeScalars
        return scalars.count == 1 ? scalars.first!.value : (c.unicodeScalars.first?.value ?? 0)
    }

    /// The query's characters, folded, without whitespace.
    static func fold(_ s: String) -> [UInt32] { s.filter { !$0.isWhitespace }.map(fold) }

    /// A text prepared once for scoring against many queries: its folded
    /// characters and the bonus a match earns at each position (start of
    /// the text, start of a word: after a non-alphanumeric, or a lower to
    /// upper case step).
    public struct Prepared: Sendable {
        let folded: [UInt32]
        let bonus: [Int]

        public init(_ text: String) {
            let raw = Array(text)
            folded = raw.map(CommandMatcher.fold)
            var b = [Int](repeating: CommandMatcher.matchPoint, count: raw.count)
            for j in raw.indices {
                if j == 0 {
                    b[j] += CommandMatcher.firstCharBonus + CommandMatcher.wordStartBonus
                } else {
                    let prev = raw[j - 1], cur = raw[j]
                    if !(prev.isLetter || prev.isNumber) || (prev.isLowercase && cur.isUppercase) { b[j] += CommandMatcher.wordStartBonus }
                }
            }
            bonus = b
        }
    }

    /// The best score of `query` (already folded) as a subsequence of
    /// `text`, or nil when it isn't one. Higher is better.
    static func score(_ query: [UInt32], in text: String) -> Int? { score(query, in: Prepared(text)) }

    static func score(_ query: [UInt32], in p: Prepared) -> Int? {
        guard !query.isEmpty else { return 0 }
        let t = p.folded, bonus = p.bonus
        let n = t.count, m = query.count
        guard m <= n else { return nil }
        // prev[j]: the best score with query[i-1] matched at text[j].
        let none = Int.min / 2
        var prev = [Int](repeating: none, count: n)
        var any = false
        for j in 0..<n where t[j] == query[0] { prev[j] = bonus[j]; any = true }
        guard any else { return nil }
        var cur = [Int](repeating: none, count: n)
        for i in 1..<m {
            for j in 0..<n { cur[j] = none }
            var bestBefore = none // the best of prev[0 ..< j-1]
            any = false
            for j in i..<n {
                if j >= 2 { bestBefore = max(bestBefore, prev[j - 2]) }
                guard t[j] == query[i] else { continue }
                let run = prev[j - 1] > none ? prev[j - 1] + consecutiveBonus : none
                let best = max(run, bestBefore > none ? bestBefore - gapPenalty : none)
                if best > none { cur[j] = best + bonus[j]; any = true }
            }
            guard any else { return nil }
            swap(&prev, &cur)
        }
        let best = prev.max() ?? none
        guard best > none else { return nil }
        return best + prefixScore(query, p)
    }

    /// prefixBonus when the text starts with the query, wordPrefixBonus
    /// when one of its words does, substringBonus when it is in there
    /// as one run ("Save" and "Save As…" for "save", over "Show Avatar
    /// Very Early"; "UPPERCASE" for "case" over "Cedric AI Settings").
    static func prefixScore(_ q: [UInt32], _ p: Prepared) -> Int {
        let t = p.folded, m = q.count
        guard m <= t.count else { return 0 }
        var best = 0
        var j = 0
        while j + m <= t.count {
            if t[j] == q[0] {
                var k = 1
                while k < m && t[j + k] == q[k] { k += 1 }
                if k == m {
                    if j == 0 { return prefixBonus }
                    best = max(best, p.bonus[j] > matchPoint ? wordPrefixBonus : substringBonus)
                }
            }
            j += 1
        }
        return best
    }

    /// The score of a query against a candidate: the title first (with a
    /// large bonus), else "path title". nil: no match.
    public static func score(_ query: String, _ c: Candidate) -> Int? {
        CommandIndex([c]).score(fold(query), 0)
    }

    /// The candidates to show, as indices into `candidates`, best first
    /// (see CommandIndex.rank).
    public static func rank(_ candidates: [Candidate], query: String, recent: [String] = []) -> [Int] {
        CommandIndex(candidates).rank(query: query, recent: recent)
    }
}

/// Candidates prepared once (when the palette's first query is typed) and
/// ranked on each keystroke.
public struct CommandIndex: Sendable {
    public let candidates: [CommandMatcher.Candidate]
    let titles: [CommandMatcher.Prepared]
    let full: [CommandMatcher.Prepared?]

    public init(_ candidates: [CommandMatcher.Candidate]) {
        self.candidates = candidates
        titles = candidates.map { CommandMatcher.Prepared($0.title) }
        full = candidates.map { $0.path.isEmpty ? nil : CommandMatcher.Prepared($0.path + " " + $0.title) }
    }

    /// The order for an empty query without preparing anything (the
    /// palette's open path): the recent commands, newest first, then the
    /// rest in menu order.
    public static func emptyQueryOrder(_ candidates: [CommandMatcher.Candidate], recent: [String]) -> [Int] {
        var first: [Int] = [], rest: [Int] = []
        var at: [String: Int] = [:]
        for (r, id) in recent.enumerated() where at[id] == nil { at[id] = r }
        var recentHits: [(Int, Int)] = []
        for (i, c) in candidates.enumerated() {
            if let r = at[c.id] { recentHits.append((r, i)) } else { rest.append(i) }
        }
        first = recentHits.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }.map { $0.1 }
        return first + rest
    }

    func score(_ q: [UInt32], _ i: Int) -> Int? {
        if q.isEmpty { return 0 }
        if let s = CommandMatcher.score(q, in: titles[i]) { return s + CommandMatcher.titleBonus }
        return full[i].flatMap { CommandMatcher.score(q, in: $0) }
    }

    /// The candidates to show, as indices into `candidates`, best first.
    ///
    /// - Empty query: the recent commands (newest first), then every other
    ///   candidate in menu order.
    /// - Otherwise: the recent commands that match (newest first), then the
    ///   rest that match, by score, an enabled command before a disabled
    ///   one with the same score, then menu order.
    ///
    /// Disabled candidates are kept (the palette shows them dimmed).
    public func rank(query: String, recent: [String] = []) -> [Int] {
        var recentRank: [String: Int] = [:]
        for (r, id) in recent.enumerated() where recentRank[id] == nil { recentRank[id] = r }
        let q = CommandMatcher.fold(query)
        var hits: [(index: Int, recent: Int, score: Int, enabled: Bool)] = []
        hits.reserveCapacity(candidates.count)
        for (i, c) in candidates.enumerated() {
            guard let s = score(q, i) else { continue }
            hits.append((i, recentRank[c.id] ?? Int.max, s, c.enabled))
        }
        hits.sort { a, b in
            if a.recent != b.recent { return a.recent < b.recent }
            if a.score != b.score { return a.score > b.score }
            if a.enabled != b.enabled { return a.enabled }
            return a.index < b.index
        }
        return hits.map { $0.index }
    }
}

/// The palette's recent commands: newest first, no repeats, at most
/// `limit` (5, as VS Code keeps its "recently used" group short). Kept
/// for the app's run, not written to disk.
public struct CommandRecents: Sendable, Equatable {
    public static let limit = 5
    public private(set) var ids: [String] = []

    public init(_ ids: [String] = []) { self.ids = Array(ids.prefix(Self.limit)) }

    public mutating func note(_ id: String) {
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        if ids.count > Self.limit { ids.removeLast(ids.count - Self.limit) }
    }
}
