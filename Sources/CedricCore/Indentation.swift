import Foundation

/// How a document indents: with tabs or spaces, and how wide one step is
/// (also how wide a tab is drawn).
public struct Indentation: Codable, Equatable, Hashable, Sendable {
    public var usesTabs: Bool
    /// Columns per step and per tab stop (1…16).
    public var width: Int

    public init(usesTabs: Bool, width: Int) {
        self.usesTabs = usesTabs
        self.width = min(16, max(1, width))
    }

    /// The widths offered in menus and Settings.
    public static let widths = [2, 3, 4, 8]

    /// One indent step as text.
    public var unit: String { usesTabs ? "\t" : String(repeating: " ", count: width) }

    /// Reads the indentation the text already uses from its first lines
    /// (at most `maxUnits` UTF-16 units and `maxLines` lines, so it costs
    /// the same in any size of file). Nil when it doesn't indent enough
    /// to tell. Tabs win when more indented lines start with a tab than
    /// with spaces; the space width is the most common step between
    /// consecutive indent levels (2, 3, 4 or 8).
    public static func detect(_ text: NSString, maxLines: Int = 2000, maxUnits: Int = 128 * 1024) -> Indentation? {
        let n = min(text.length, maxUnits)
        guard n > 0 else { return nil }
        var tabs = 0, spaces = 0
        var steps: [Int: Int] = [:]
        var previous = 0
        var i = 0, lines = 0
        var buffer = [unichar](repeating: 0, count: n)
        text.getCharacters(&buffer, range: NSRange(location: 0, length: n))
        while i < n, lines < maxLines {
            lines += 1
            let start = i
            var width = 0
            var tabbed = false, spaced = false
            while i < n, buffer[i] == 32 || buffer[i] == 9 {
                if buffer[i] == 9 { if i == start { tabbed = true } } else if i == start { spaced = true }
                if buffer[i] == 32 { width += 1 }
                i += 1
            }
            let blank = i >= n || buffer[i] == 10 || buffer[i] == 13
            if !blank {
                if tabbed { tabs += 1 }
                // A lone space before "*" continues a block comment, not an indent.
                else if spaced, !(width % 2 == 1 && buffer[i] == 42) {
                    spaces += 1
                    let d = abs(width - previous)
                    if d >= 2, d <= 8 { steps[d, default: 0] += 1 }
                    previous = width
                } else if !spaced {
                    previous = 0
                }
            }
            while i < n, buffer[i] != 10 { i += 1 }
            i += 1
        }
        guard tabs + spaces >= 2 else { return nil }
        if tabs > spaces { return Indentation(usesTabs: true, width: 4) }
        // The most common step; ties go to the smaller one.
        guard let best = steps.filter({ [2, 3, 4, 8].contains($0.key) })
            .max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) else {
            return nil
        }
        return Indentation(usesTabs: false, width: best.key)
    }
}

extension LineOperations {
    /// Shift Right (Tab on several lines, ⌘]): one step more at the start
    /// of every non-blank line the selection touches. The selection keeps
    /// covering the same lines.
    public static func indent(_ sel: NSRange, in text: NSString, unit: String) -> TextEdit? {
        let block = lineBlock(sel, in: text)
        let lines = splitLines(text.substring(with: block))
        var out = ""
        var shiftFirst = 0
        var total = 0
        let u = (unit as NSString).length
        for (k, line) in lines.enumerated() {
            let blank = line.content.allSatisfy { $0 == " " || $0 == "\t" }
            if !blank {
                out += unit
                total += u
                if k == 0 { shiftFirst = u }
            }
            out += line.content + line.newline
        }
        guard total > 0 else { return nil }
        let selection = adjusted(sel, block: block, firstShift: shiftFirst, total: total, newLength: (out as NSString).length)
        return TextEdit(range: block, replacement: out, selection: selection)
    }

    /// Shift Left (⇧Tab, ⌘[): removes up to one step (a tab, or up to
    /// `width` spaces) from the start of every line the selection touches.
    /// Nil when no line is indented.
    public static func outdent(_ sel: NSRange, in text: NSString, width: Int) -> TextEdit? {
        let block = lineBlock(sel, in: text)
        let lines = splitLines(text.substring(with: block))
        var out = ""
        var removedFirst = 0
        var total = 0
        for (k, line) in lines.enumerated() {
            var drop = 0
            let units = Array(line.content.utf16)
            if units.first == 9 {
                drop = 1
            } else {
                while drop < width, drop < units.count, units[drop] == 32 { drop += 1 }
                // Spaces then a tab: the tab finishes the step.
                if drop < width, drop < units.count, units[drop] == 9 { drop += 1 }
            }
            if k == 0 { removedFirst = drop }
            total += drop
            out += String(decoding: units[drop...], as: UTF16.self) + line.newline
        }
        guard total > 0 else { return nil }
        let newLength = (out as NSString).length
        // The caret (or selection start) moves left with its line's text, never before the line start.
        let startCol = sel.location - block.location
        let start = block.location + max(0, startCol - removedFirst)
        let selection: NSRange
        if sel.length == 0 {
            selection = NSRange(location: start, length: 0)
        } else {
            let end = NSMaxRange(sel) >= NSMaxRange(block) ? block.location + newLength : max(start, NSMaxRange(sel) - total)
            selection = NSRange(location: start, length: max(0, end - start))
        }
        return TextEdit(range: block, replacement: out, selection: selection)
    }

    private static func adjusted(_ sel: NSRange, block: NSRange, firstShift: Int, total: Int, newLength: Int) -> NSRange {
        // A selection from a line start keeps starting there (so whole lines stay whole).
        let start = sel.location == block.location && sel.length > 0 ? sel.location : sel.location + firstShift
        if sel.length == 0 { return NSRange(location: start, length: 0) }
        let end = NSMaxRange(sel) >= NSMaxRange(block) ? block.location + newLength : NSMaxRange(sel) + total
        return NSRange(location: start, length: max(0, end - start))
    }

    private static func splitLines(_ s: String) -> [(content: String, newline: String)] {
        var result: [(String, String)] = []
        var parts = s.split(separator: "\n", omittingEmptySubsequences: false)
        let endsWithNewline = s.hasSuffix("\n")
        if endsWithNewline { parts.removeLast() }
        for (k, p) in parts.enumerated() {
            result.append((String(p), k < parts.count - 1 || endsWithNewline ? "\n" : ""))
        }
        if result.isEmpty { result.append(("", "")) }
        return result
    }

    /// Converts the leading whitespace of every line to `to` (tabs or
    /// spaces of `to.width`), keeping each line's visual column.
    public static func convertIndentation(_ text: String, from: Indentation, to: Indentation) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for (k, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if k > 0 { out += "\n" }
            var col = 0
            var idx = line.startIndex
            while idx < line.endIndex, line[idx] == " " || line[idx] == "\t" {
                col = line[idx] == "\t" ? (col / from.width + 1) * from.width : col + 1
                idx = line.index(after: idx)
            }
            if idx == line.startIndex { out += line; continue }
            if to.usesTabs {
                out += String(repeating: "\t", count: col / to.width) + String(repeating: " ", count: col % to.width)
            } else {
                out += String(repeating: " ", count: col)
            }
            out += line[idx...]
        }
        return out
    }
}
