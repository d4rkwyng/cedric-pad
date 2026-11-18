import Foundation

/// One edit to apply: replace `range` with `replacement`, then select
/// `selection` (in the edited text).
public struct TextEdit: Equatable, Sendable {
    public var range: NSRange
    public var replacement: String
    public var selection: NSRange

    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }

    /// The edit applied to `text` (for tests and previews).
    public func applied(to text: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: replacement)
    }
}

/// How a language writes a comment, for Toggle Comment.
public struct CommentSyntax: Equatable, Sendable {
    /// "//" or "#": put in front of each line.
    public var line: String?
    /// "/*", "*/" or "<!--", "-->": around the lines.
    public var block: (start: String, end: String)?

    public init(line: String? = nil, block: (start: String, end: String)? = nil) {
        self.line = line
        self.block = block
    }

    public static func == (a: CommentSyntax, b: CommentSyntax) -> Bool {
        a.line == b.line && a.block?.start == b.block?.start && a.block?.end == b.block?.end
    }
}

extension Language {
    /// How this language comments, or nil (plain text, JSON).
    public var commentSyntax: CommentSyntax? {
        switch self {
        case .swift, .javascript, .typescript, .c: return CommentSyntax(line: "//")
        case .python, .yaml, .shell, .ruby: return CommentSyntax(line: "#")
        case .css: return CommentSyntax(block: ("/*", "*/"))
        case .html, .markdown, .xml: return CommentSyntax(block: ("<!--", "-->"))
        case .sql: return CommentSyntax(line: "--")
        case .ini: return CommentSyntax(line: "#")
        case .plain, .json, .diff: return nil
        }
    }
}

/// Duplicate, move, delete and comment whole lines: pure functions from
/// the text and the selection to one `TextEdit`. They touch only the lines
/// of the selection (and one neighbour for a move), so they cost the same
/// in a big document.
public enum LineOperations {
    /// The whole lines the selection touches, newline of the last one
    /// included. A selection ending at the very start of a line doesn't
    /// take that line (as when whole lines are selected by dragging).
    public static func lineBlock(_ sel: NSRange, in text: NSString) -> NSRange {
        var end = NSMaxRange(sel)
        if sel.length > 0, end > sel.location, end <= text.length, text.character(at: end - 1) == 10 { end -= 1 }
        let first = text.lineRange(for: NSRange(location: min(sel.location, text.length), length: 0))
        let last = text.lineRange(for: NSRange(location: min(max(end, sel.location), text.length), length: 0))
        return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
    }

    private static func endsWithNewline(_ r: NSRange, _ text: NSString) -> Bool {
        r.length > 0 && text.character(at: NSMaxRange(r) - 1) == 10
    }

    /// Copies the selected lines below themselves; the selection moves to
    /// the copy.
    public static func duplicate(_ sel: NSRange, in text: NSString) -> TextEdit {
        let block = lineBlock(sel, in: text)
        let body = text.substring(with: block)
        let insertion: String, at: Int, shift: Int
        if endsWithNewline(block, text) {
            insertion = body
            at = NSMaxRange(block)
            shift = block.length
        } else {
            // The last line has no newline: add one between the copies.
            insertion = "\n" + body
            at = NSMaxRange(block)
            shift = block.length + 1
        }
        return TextEdit(range: NSRange(location: at, length: 0), replacement: insertion,
                        selection: NSRange(location: sel.location + shift, length: sel.length))
    }

    /// Swaps the selected lines with the line above; nil on the first line.
    public static func moveUp(_ sel: NSRange, in text: NSString) -> TextEdit? {
        let block = lineBlock(sel, in: text)
        guard block.location > 0 else { return nil }
        let above = text.lineRange(for: NSRange(location: block.location - 1, length: 0))
        var b = text.substring(with: block)
        var a = text.substring(with: above)
        if !endsWithNewline(block, text) {
            // Moving the last line up: it gains a newline, the line above loses its own.
            b += "\n"
            a.removeLast()
        }
        let span = NSRange(location: above.location, length: NSMaxRange(block) - above.location)
        return TextEdit(range: span, replacement: b + a,
                        selection: NSRange(location: sel.location - above.length, length: sel.length))
    }

    /// Swaps the selected lines with the line below; nil on the last line.
    public static func moveDown(_ sel: NSRange, in text: NSString) -> TextEdit? {
        let block = lineBlock(sel, in: text)
        guard NSMaxRange(block) < text.length, endsWithNewline(block, text) else { return nil }
        let below = text.lineRange(for: NSRange(location: NSMaxRange(block), length: 0))
        var b = text.substring(with: block)
        var a = text.substring(with: below)
        if !endsWithNewline(below, text) {
            // The line below is the last one, without a newline.
            a += "\n"
            b.removeLast()
        }
        let span = NSRange(location: block.location, length: NSMaxRange(below) - block.location)
        return TextEdit(range: span, replacement: a + b,
                        selection: NSRange(location: sel.location + (a as NSString).length, length: sel.length))
    }

    /// The range Delete Line and Cut Line remove: the selected lines with
    /// their newline (the last line takes the newline before it instead).
    public static func deletionRange(_ sel: NSRange, in text: NSString) -> NSRange {
        let block = lineBlock(sel, in: text)
        if !endsWithNewline(block, text), block.location > 0 {
            return NSRange(location: block.location - 1, length: block.length + 1)
        }
        return block
    }

    /// Deletes the selected lines; the caret goes to the start of the line
    /// that takes their place.
    public static func deleteLines(_ sel: NSRange, in text: NSString) -> TextEdit {
        let r = deletionRange(sel, in: text)
        let block = lineBlock(sel, in: text)
        // Deleting the last line: the caret goes to the start of the line before.
        let caret = r.location < block.location ? text.lineRange(for: NSRange(location: r.location, length: 0)).location : r.location
        return TextEdit(range: r, replacement: "", selection: NSRange(location: caret, length: 0))
    }

    // MARK: Comments

    private static func isBlank(_ s: Substring) -> Bool { s.allSatisfy { $0 == " " || $0 == "\t" } }

    private static func indentWidth(_ s: Substring) -> Int { s.prefix { $0 == " " || $0 == "\t" }.utf16.count }

    /// Comments the selected lines out, or back in if every non-blank one
    /// is already commented. Line comments go at the smallest indent of
    /// the block, followed by a space; block comments wrap the lines. Nil
    /// if the language has no comments.
    public static func toggleComment(_ sel: NSRange, in text: NSString, syntax: CommentSyntax?) -> TextEdit? {
        guard let syntax else { return nil }
        let block = lineBlock(sel, in: text)
        let hasNewline = endsWithNewline(block, text)
        let content = text.substring(with: NSRange(location: block.location, length: block.length - (hasNewline ? 1 : 0)))
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let newContent: String
        // The caret's offset change, on its own line.
        var caretShift = 0
        if let prefix = syntax.line {
            let filled = lines.filter { !isBlank($0) }
            guard !filled.isEmpty else { return nil }
            let commented = filled.allSatisfy { $0.drop { $0 == " " || $0 == "\t" }.hasPrefix(prefix) }
            if commented {
                newContent = lines.map { line -> String in
                    let indent = line.prefix { $0 == " " || $0 == "\t" }
                    var rest = line.dropFirst(indent.count)
                    guard rest.hasPrefix(prefix) else { return String(line) }
                    rest = rest.dropFirst(prefix.count)
                    if rest.first == " " { rest = rest.dropFirst() }
                    return String(indent) + rest
                }.joined(separator: "\n")
                let first = lines[0]
                if !isBlank(first) { caretShift = -((prefix as NSString).length + (first.drop { $0 == " " || $0 == "\t" }.dropFirst(prefix.count).first == " " ? 1 : 0)) }
            } else {
                let col = filled.map(indentWidth).min() ?? 0
                newContent = lines.map { line -> String in
                    if isBlank(line) { return String(line) }
                    let u = Array(line.utf16)
                    let head = String(decoding: u[0..<col], as: UTF16.self)
                    let tail = String(decoding: u[col...], as: UTF16.self)
                    return head + prefix + " " + tail
                }.joined(separator: "\n")
                if !isBlank(lines[0]) { caretShift = (prefix as NSString).length + 1 }
            }
        } else if let pair = syntax.block {
            let start = pair.start, end = pair.end
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let indent = String(content.prefix { $0 == " " || $0 == "\t" })
            let trailing = String(content.reversed().prefix { $0 == " " || $0 == "\t" })
            if trimmed.hasPrefix(start), trimmed.hasSuffix(end), trimmed.count >= start.count + end.count {
                var inner = trimmed.dropFirst(start.count).dropLast(end.count)
                if inner.first == " " { inner = inner.dropFirst() }
                if inner.last == " " { inner = inner.dropLast() }
                newContent = indent + inner + trailing
                caretShift = -((start as NSString).length + (trimmed.dropFirst(start.count).first == " " ? 1 : 0))
            } else {
                newContent = indent + start + " " + trimmed + " " + end + trailing
                caretShift = (start as NSString).length + 1
            }
        } else {
            return nil
        }
        let replaced = NSRange(location: block.location, length: block.length - (hasNewline ? 1 : 0))
        let newLength = (newContent as NSString).length
        let selection: NSRange
        if sel.length == 0 {
            // The caret stays with its text (but not before the line start).
            let firstLineIndent = indentWidth(lines[0])
            let col = sel.location - block.location
            let loc = col < firstLineIndent ? sel.location : max(block.location + firstLineIndent, sel.location + caretShift)
            selection = NSRange(location: min(loc, block.location + newLength), length: 0)
        } else {
            selection = NSRange(location: block.location, length: newLength + (hasNewline ? 1 : 0))
        }
        return TextEdit(range: replaced, replacement: newContent, selection: selection)
    }
}
