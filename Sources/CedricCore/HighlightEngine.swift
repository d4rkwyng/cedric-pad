import Foundation

/// Incremental, viewport-driven highlighting. Holds the state at the start
/// of each line for the lines scanned so far; an edit drops the cached
/// states below the edited line, and `tokens(forLines:)` only scans from the
/// last valid state to the end of the requested range. For tokenizers that
/// carry no state between lines (JSON, YAML, plain) nothing above the
/// requested lines is ever scanned, so a jump to the end of a 50 MB file
/// costs the same as the top.
///
/// Not thread-safe: the app calls it on the main thread, against the text
/// storage's current string.
public final class HighlightEngine {
    public private(set) var language: Language
    private var tokenizer: Tokenizer
    /// `states[i]` = state at the start of line i, valid for i < states.count.
    private var states: [UInt32] = [0]
    private var buffer: [UInt16] = []
    private var scratch: [Token] = []

    public init(language: Language) {
        self.language = language
        tokenizer = Languages.tokenizer(for: language)
    }

    public func setLanguage(_ language: Language) {
        self.language = language
        tokenizer = Languages.tokenizer(for: language)
        states = [0]
    }

    /// Call after an edit: line `line`'s content changed.
    public func invalidate(fromLine line: Int) {
        if line + 1 < states.count { states.removeSubrange((line + 1)...) }
    }

    public func invalidateAll() { states = [0] }

    /// How many lines have a known start state (for tests and diagnostics).
    public var validStateCount: Int { states.count }

    /// Tokens for each line in `lines`, with offsets absolute in `text`.
    public func tokens(forLines lines: Range<Int>, in text: NSString, index: LineIndex) -> [Token] {
        let lines = lines.clamped(to: 0..<index.lineCount)
        guard !lines.isEmpty else { return [] }
        var state: UInt32 = 0
        if tokenizer.carriesState {
            // Walk forward from the last line with a known state.
            var line = states.count - 1
            state = states[line]
            while line < lines.lowerBound {
                scratch.removeAll(keepingCapacity: true)
                scan(line: line, text: text, index: index, state: &state, into: &scratch)
                line += 1
                states.append(state)
            }
            state = states[lines.lowerBound]
        }
        var out: [Token] = []
        for line in lines {
            scratch.removeAll(keepingCapacity: true)
            scan(line: line, text: text, index: index, state: &state, into: &scratch)
            let base = index.starts[line]
            for t in scratch { out.append(Token(base + t.start, t.length, t.kind)) }
            if tokenizer.carriesState, line + 1 == states.count, line + 1 < index.lineCount { states.append(state) }
        }
        return out
    }

    private func scan(line: Int, text: NSString, index: LineIndex, state: inout UInt32, into tokens: inout [Token]) {
        let r = index.contentRange(ofLine: line)
        // Very long lines (minified JSON, logs): colour the first 20k
        // characters; scanning megabytes on every viewport pass isn't worth it.
        let len = min(r.length, 20_000)
        if buffer.count < len { buffer = [UInt16](repeating: 0, count: max(len, 1024)) }
        buffer.withUnsafeMutableBufferPointer { p in
            if len > 0 { text.getCharacters(p.baseAddress!, range: NSRange(location: r.location, length: len)) }
            tokenizer.tokenize(UnsafeBufferPointer(rebasing: p[0..<len]), state: &state, into: &tokens)
        }
    }
}
