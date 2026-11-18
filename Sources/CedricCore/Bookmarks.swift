import Foundation

/// Bookmarked lines (0-based), sorted, kept on their text as lines are
/// inserted and deleted above or inside them. Every operation is
/// O(bookmarks) or better; nothing scans the document.
public struct Bookmarks: Equatable, Sendable {
    public private(set) var lines: [Int] = []

    public init(_ lines: [Int] = []) {
        self.lines = Array(Set(lines.filter { $0 >= 0 })).sorted()
    }

    public var isEmpty: Bool { lines.isEmpty }
    public var count: Int { lines.count }

    public func contains(_ line: Int) -> Bool { index(of: line) != nil }

    private func index(of line: Int) -> Int? {
        var lo = 0, hi = lines.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid] == line { return mid }
            if lines[mid] < line { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    public mutating func toggle(_ line: Int) {
        if let i = index(of: line) { lines.remove(at: i) } else { self = Bookmarks(lines + [line]) }
    }

    public mutating func insert<S: Sequence>(contentsOf more: S) where S.Element == Int {
        self = Bookmarks(lines + Array(more))
    }

    public mutating func removeAll() { lines = [] }

    /// The next bookmark after `line`, wrapping to the first.
    public func next(after line: Int) -> Int? {
        lines.first { $0 > line } ?? lines.first
    }

    /// The bookmark before `line`, wrapping to the last.
    public func previous(before line: Int) -> Int? {
        lines.last { $0 < line } ?? lines.last
    }

    /// After an edit that replaced old lines `firstLine…firstLine+removed`
    /// (the newlines it removed) with text holding `inserted` newlines.
    /// `wholeLines`: the edit started at a line start and ended at one
    /// (whole lines replaced, or text inserted at a line start). Then the
    /// replaced lines lose their bookmarks and the line after keeps its
    /// own; otherwise lines merged into `firstLine` take their bookmark
    /// to it. Lines below shift.
    public mutating func adjust(firstLine: Int, removed: Int, inserted: Int, wholeLines: Bool) {
        guard !lines.isEmpty, removed != 0 || inserted != 0 else { return }
        let lastOld = firstLine + removed
        let delta = inserted - removed
        var out: [Int] = []
        out.reserveCapacity(lines.count)
        for b in lines {
            if b < firstLine {
                out.append(b)
            } else if b > lastOld {
                out.append(b + delta)
            } else if wholeLines {
                if b == lastOld { out.append(b + delta) }
            } else {
                out.append(firstLine)
            }
        }
        self = Bookmarks(out)
    }

    /// After lines `block` swapped places with the line above (`by` = -1)
    /// or below (`by` = +1): their bookmarks go with them.
    public mutating func moveLines(_ block: Range<Int>, by: Int) {
        guard !lines.isEmpty, by == 1 || by == -1 else { return }
        let other = by < 0 ? block.lowerBound - 1 : block.upperBound
        self = Bookmarks(lines.map { b in
            if block.contains(b) { return b + by }
            if b == other { return by < 0 ? block.upperBound - 1 : block.lowerBound }
            return b
        })
    }

    /// Bookmarks after `range` of `text` is replaced with `replacement`,
    /// for edits made in one go (Replace All, Toggle Comment, Text Tools,
    /// Delete Line): the whole lines the edit touches are compared before
    /// and after, so a line whose text survives keeps its bookmark, and a
    /// changed line keeps it where as many lines replaced as many (the
    /// counts-only `adjust` would merge them all onto the first line).
    /// `firstLine`: the line holding `range.location`. Costs nothing
    /// without bookmarks; only the touched lines are read.
    public func replacing(_ range: NSRange, with replacement: String, in text: NSString, firstLine: Int) -> Bookmarks {
        guard !lines.isEmpty else { return self }
        let block = text.lineRange(for: range)
        let old = text.substring(with: block)
        let new = text.substring(with: NSRange(location: block.location, length: range.location - block.location))
            + replacement
            + text.substring(with: NSRange(location: NSMaxRange(range), length: NSMaxRange(block) - NSMaxRange(range)))
        // A block that ends with its newline is followed by the next line
        // (not part of it); one that doesn't runs to the end of the text.
        let endsLine = old.hasSuffix("\n")
        return replacingBlock(firstLine: firstLine, old: Self.splitLines(old, endsLine), new: Self.splitLines(new, endsLine))
    }

    static func splitLines(_ s: String, _ endsLine: Bool) -> [Substring] {
        if endsLine, s.isEmpty { return [] }
        var parts = s.split(separator: "\n", omittingEmptySubsequences: false)
        if endsLine, parts.count > 1, parts.last == "" { parts.removeLast() }
        return parts
    }

    /// Past this many changed lines on either side, changed lines are
    /// matched by position only, without a diff.
    static let diffLimit = 1000

    /// Bookmarks after lines `firstLine..<firstLine+old.count` became `new`.
    public func replacingBlock(firstLine: Int, old: [Substring], new: [Substring]) -> Bookmarks {
        guard !lines.isEmpty else { return self }
        let end = firstLine + old.count
        // Common start and end of the block keep their lines.
        var pre = 0
        while pre < old.count, pre < new.count, old[pre] == new[pre] { pre += 1 }
        var suf = 0
        while suf < old.count - pre, suf < new.count - pre, old[old.count - 1 - suf] == new[new.count - 1 - suf] { suf += 1 }
        let oldMid = Array(old[pre..<(old.count - suf)]), newMid = Array(new[pre..<(new.count - suf)])
        // Old line (in the middle) → new line (in the middle), or nil: gone.
        var map: [Int: Int] = [:]
        func positional(_ a: Range<Int>, _ b: Range<Int>) {
            // As many replaced as many: each keeps its place. Otherwise a
            // replaced line's bookmark goes to the replacement's line at the
            // same place, or its last; with nothing in its place, it goes.
            guard !b.isEmpty else { return }
            for (k, i) in a.enumerated() { map[i] = b.lowerBound + min(k, b.count - 1) }
        }
        let touched = lines.contains { $0 >= firstLine + pre && $0 < end - suf }
        if touched {
            if oldMid.count == newMid.count || oldMid.count > Self.diffLimit || newMid.count > Self.diffLimit {
                positional(0..<oldMid.count, 0..<newMid.count)
            } else {
                var dels: [Int] = [], ins: [Int] = []
                func flush() { positional(dels.first.map { $0..<($0 + dels.count) } ?? 0..<0,
                                          ins.first.map { $0..<($0 + ins.count) } ?? 0..<0); dels = []; ins = [] }
                for op in LineDiff.diff(oldMid.map(String.init), newMid.map(String.init)) {
                    switch op {
                    case .equal(let i, let j): flush(); map[i] = j
                    case .delete(let i): dels.append(i)
                    case .insert(let j): ins.append(j)
                    }
                }
                flush()
            }
        }
        let delta = new.count - old.count
        var out: [Int] = []
        out.reserveCapacity(lines.count)
        for b in lines {
            if b < firstLine + pre {
                out.append(b)
            } else if b >= end - suf {
                out.append(b + delta)
            } else if let j = map[b - firstLine - pre] {
                out.append(firstLine + pre + j)
            }
        }
        return Bookmarks(out)
    }

    /// Drops bookmarks past the last line.
    public mutating func clamp(lineCount: Int) {
        if let last = lines.last, last >= lineCount { lines = lines.filter { $0 < lineCount } }
    }
}
