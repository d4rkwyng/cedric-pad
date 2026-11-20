import Foundation

/// "Line 123" and "Lines 12–40" in an Ask Cedric answer, turned into links
/// the editor can follow. Read-only: the link names a line, it never
/// carries an edit. Fenced code, inline code and existing markdown links
/// are left alone, so a sample that mentions a line is not a button.
public enum LineCitations {
    public static let scheme = "owlink-line"

    private static let citation: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"(?i)\b(?:lines?)\s+([1-9]\d{0,6})(?:\s*[-–—]\s*[1-9]\d{0,6})?"#)
    }()

    /// The line a citation link names (1-based), or nil.
    public static func line(from url: URL) -> Int? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let raw = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let n = Int(raw), n >= 1 else { return nil }
        return n
    }

    /// 1-based lines named in `markdown`, in order. A range contributes its
    /// first line.
    public static func lines(in markdown: String) -> [Int] {
        hits(in: markdown).map(\.line)
    }

    /// `markdown` with each citation wrapped as `[Line 123](owlink-line://123)`.
    /// The words stay as written; only the link is added.
    public static func linked(_ markdown: String) -> String {
        let ns = markdown as NSString
        var out = ""
        var last = 0
        for hit in hits(in: markdown) {
            out += ns.substring(with: NSRange(location: last, length: hit.range.location - last))
            out += "[\(ns.substring(with: hit.range))](\(scheme)://\(hit.line))"
            last = hit.range.location + hit.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    private struct Hit {
        var range: NSRange
        var line: Int
    }

    private static func hits(in markdown: String) -> [Hit] {
        let ns = markdown as NSString
        let dead = inactiveRanges(ns)
        return citation.matches(in: markdown, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard dead.allSatisfy({ NSIntersectionRange($0, m.range).length == 0 }) else { return nil }
            guard m.numberOfRanges > 1, let n = Int(ns.substring(with: m.range(at: 1))), n >= 1 else { return nil }
            return Hit(range: m.range, line: n)
        }
    }

    /// Fenced code, inline code, and markdown links. Citations in there are
    /// text, not jumps.
    private static func inactiveRanges(_ text: NSString) -> [NSRange] {
        let n = text.length
        var ranges: [NSRange] = []
        var lineStart = 0
        var fenceStart: Int?
        var fenceChar: unichar = 0
        var i = 0
        while i <= n {
            let atEnd = i == n
            if atEnd || text.character(at: i) == 10 {
                let lineLen = i - lineStart
                if fenceStart == nil {
                    if let marker = openingFence(text, lineStart: lineStart, lineLen: lineLen) {
                        fenceStart = lineStart
                        fenceChar = marker
                    }
                } else if closingFence(text, lineStart: lineStart, lineLen: lineLen, marker: fenceChar) {
                    ranges.append(NSRange(location: fenceStart!, length: i - fenceStart!))
                    fenceStart = nil
                }
                lineStart = i + 1
            }
            if atEnd { break }
            i += 1
        }
        if let fenceStart { ranges.append(NSRange(location: fenceStart, length: n - fenceStart)) }

        var index = 0
        while index < n {
            if let cover = ranges.first(where: { NSLocationInRange(index, $0) }) {
                index = NSMaxRange(cover)
                continue
            }
            let c = text.character(at: index)
            if c == 96 {
                var ticks = 0
                while index + ticks < n, text.character(at: index + ticks) == 96 { ticks += 1 }
                var j = index + ticks
                var closed = false
                while j < n {
                    if ranges.contains(where: { NSLocationInRange(j, $0) }) { break }
                    if text.character(at: j) == 96 {
                        var m = 0
                        while j + m < n, text.character(at: j + m) == 96 { m += 1 }
                        if m == ticks {
                            ranges.append(NSRange(location: index, length: j + m - index))
                            index = j + m
                            closed = true
                            break
                        }
                        j += m
                    } else {
                        j += 1
                    }
                }
                if !closed { index += ticks }
            } else if c == 91 {
                if let link = markdownLink(text, from: index, limit: n, avoiding: ranges) {
                    ranges.append(link)
                    index = NSMaxRange(link)
                } else {
                    index += 1
                }
            } else {
                index += 1
            }
        }
        return ranges
    }

    /// A CommonMark opening fence: up to three spaces, then at least three
    /// backticks or tildes. An info string is allowed.
    private static func openingFence(_ text: NSString, lineStart: Int, lineLen: Int) -> unichar? {
        let ticks = fenceTicks(text, lineStart: lineStart, lineLen: lineLen)
        guard ticks.count >= 3 else { return nil }
        return ticks.char
    }

    /// A closing fence: the same marker, at least as many, and nothing after
    /// it but whitespace.
    private static func closingFence(_ text: NSString, lineStart: Int, lineLen: Int, marker: unichar) -> Bool {
        let ticks = fenceTicks(text, lineStart: lineStart, lineLen: lineLen)
        guard ticks.char == marker, ticks.count >= 3 else { return false }
        var k = ticks.end
        let end = lineStart + lineLen
        while k < end {
            let c = text.character(at: k)
            if c != 32 && c != 9 { return false }
            k += 1
        }
        return true
    }

    private static func fenceTicks(_ text: NSString, lineStart: Int, lineLen: Int) -> (char: unichar, count: Int, end: Int) {
        var k = lineStart
        let end = lineStart + lineLen
        var spaces = 0
        while k < end, spaces < 4 {
            let c = text.character(at: k)
            if c != 32 && c != 9 { break }
            spaces += 1
            k += 1
        }
        guard k < end, spaces < 4 else { return (0, 0, k) }
        let c = text.character(at: k)
        guard c == 96 || c == 126 else { return (0, 0, k) }
        var count = 0
        while k < end, text.character(at: k) == c { count += 1; k += 1 }
        return (c, count, k)
    }

    /// `[label](destination)` starting at `from`, not crossing a dead range.
    private static func markdownLink(_ text: NSString, from: Int, limit: Int, avoiding dead: [NSRange]) -> NSRange? {
        var i = from + 1
        while i < limit, text.character(at: i) != 93, text.character(at: i) != 10 { // ] or newline
            if dead.contains(where: { NSLocationInRange(i, $0) }) { return nil }
            i += 1
        }
        guard i + 1 < limit, text.character(at: i) == 93, text.character(at: i + 1) == 40 else { return nil }
        i += 2
        while i < limit, text.character(at: i) != 41, text.character(at: i) != 10 {
            i += 1
        }
        guard i < limit, text.character(at: i) == 41 else { return nil }
        return NSRange(location: from, length: i + 1 - from)
    }
}
