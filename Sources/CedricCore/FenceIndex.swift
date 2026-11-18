import Foundation

/// Which lines of a Markdown document are inside a ``` or ~~~ fence, for
/// the editing keys (Return, Tab) that must leave code alone. Like the
/// highlight engine it caches the state at each line start, scanned once
/// from the top and kept: an edit drops the states from the edited line
/// down, so the next question only rescans from there to the caret. Each
/// line costs one short read of its first characters.
///
/// Not thread-safe: the app uses it on the main thread.
public final class FenceIndex {
    /// `states[i]`: the fence open at the start of line i (its character
    /// << 16 | its length), 0 for none; valid for i < states.count.
    private var states: [UInt32] = [0]
    private var buffer = [unichar](repeating: 0, count: 64)

    public init() {}

    /// Line `line`'s content changed (and every line after it may have moved).
    public func invalidate(fromLine line: Int) {
        let keep = max(1, line + 1)
        if keep < states.count { states.removeSubrange(keep...) }
    }

    public func invalidateAll() { states = [0] }

    /// How many line starts are known (for tests).
    public var validCount: Int { states.count }

    /// Whether line `line` is inside a fence or is one of its fence lines.
    public func isInFence(_ text: NSString, index: LineIndex, line: Int) -> Bool {
        guard line >= 0, line < index.lineCount, index.length == text.length else { return false }
        while states.count <= line {
            let l = states.count - 1
            states.append(Self.next(states[l], line: l, text: text, index: index, buffer: &buffer))
        }
        let open = states[line]
        if open != 0 { return true }
        // Not open at its start: in a fence only if this line opens one.
        return Self.next(0, line: line, text: text, index: index, buffer: &buffer) != 0
    }

    /// The state after line `l`, given `state` at its start.
    static func next(_ state: UInt32, line l: Int, text: NSString, index: LineIndex, buffer: inout [unichar]) -> UInt32 {
        let r = index.contentRange(ofLine: l)
        let n = min(r.length, buffer.count)
        guard n >= 3 else { return state }
        buffer.withUnsafeMutableBufferPointer { p in text.getCharacters(p.baseAddress!, range: NSRange(location: r.location, length: n)) }
        var i = 0
        while i < 4, i < n, buffer[i] == 32 { i += 1 }
        guard i <= 3, i < n else { return state }
        let c = buffer[i]
        guard c == 96 || c == 126 else { return state }
        var run = 0
        while i + run < n, buffer[i + run] == c { run += 1 }
        guard run >= 3 else { return state }
        if state == 0 { return UInt32(c) << 16 | UInt32(min(run, 0xFFFF)) }
        // Closes only with the same character, at least as long.
        return UInt32(c) == state >> 16 && run >= Int(state & 0xFFFF) ? 0 : state
    }
}
