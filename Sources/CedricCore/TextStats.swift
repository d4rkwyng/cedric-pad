import Foundation

/// Words, lines and characters, for the status bar.
public struct TextCounts: Equatable, Sendable {
    public var words: Int
    public var lines: Int
    /// Unicode scalars (a surrogate pair counts once).
    public var characters: Int

    public init(words: Int, lines: Int, characters: Int) {
        self.words = words
        self.lines = lines
        self.characters = characters
    }
}

public enum TextStats {
    /// Longer ranges aren't counted (the status bar shows lines only):
    /// counting is a scan, and it runs after edits and selection changes.
    public static let maxCounted = 1_000_000

    /// Counts `range` of `text`, or nil if it is longer than `limit`.
    /// Words are runs of letters, digits and "_" (Occurrences.isWordUnit),
    /// so "don't" is two and "snake_case" one. Lines are the lines the
    /// range touches; a range ending just after a newline doesn't touch
    /// the next line. An empty range is one (empty) line.
    public static func count(_ text: NSString, range: NSRange, limit: Int = maxCounted) -> TextCounts? {
        let start = max(0, min(range.location, text.length))
        let end = min(text.length, NSMaxRange(range))
        let len = end - start
        guard len <= limit else { return nil }
        var words = 0, newlines = 0, chars = 0
        var inWord = false
        var lastWasNewline = false
        let chunk = 16_384
        var buffer = [unichar](repeating: 0, count: chunk)
        var pos = start
        while pos < end {
            let n = min(chunk, end - pos)
            buffer.withUnsafeMutableBufferPointer { p in
                text.getCharacters(p.baseAddress!, range: NSRange(location: pos, length: n))
                for k in 0..<n {
                    let c = p[k]
                    if !UTF16.isTrailSurrogate(c) { chars += 1 }
                    let w = Occurrences.isWordUnit(c)
                    if w && !inWord { words += 1 }
                    inWord = w
                    lastWasNewline = c == 10
                    if lastWasNewline { newlines += 1 }
                }
            }
            pos += n
        }
        let lines = len == 0 ? 1 : newlines + (lastWasNewline ? 0 : 1)
        return TextCounts(words: words, lines: lines, characters: chars)
    }
}
