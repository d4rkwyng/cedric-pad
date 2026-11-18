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

    /// Drops bookmarks past the last line.
    public mutating func clamp(lineCount: Int) {
        if let last = lines.last, last >= lineCount { lines = lines.filter { $0 < lineCount } }
    }
}
