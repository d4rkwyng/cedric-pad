import Foundation

/// The hints Cedric gives without any AI: plain checks on the text in view
/// and on the document facts. Pure and fast (one pass over at most 8 KB).
public struct RulesHintProvider: OwlFactsAwareProvider {
    public static let jsonID = "rules.json-format"
    public static let mixedIndentID = "rules.mixed-indent"
    public static let reloadID = "rules.changed-on-disk"
    public static let saveCopyID = "rules.unsaved-long"
    public static let trailingID = "rules.trailing-whitespace"
    public static let crlfID = "rules.crlf"
    public static let letterID = "rules.letter"

    public let name = "rules"
    /// Unsaved this long → "Save a copy?".
    public var unsavedThreshold: TimeInterval = 2 * 3600
    /// At least this many lines ending in spaces or tabs → "Trim?".
    public var trailingMinLines = 5
    public var tabWidth = 4
    public var now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func hints(for context: OwlContext) async -> [OwlHint] {
        check(context, facts: OwlDocumentFacts())
    }

    public func hints(for context: OwlContext, facts: OwlDocumentFacts) async -> [OwlHint] {
        check(context, facts: facts)
    }

    /// All the rules, most useful first.
    public func check(_ c: OwlContext, facts: OwlDocumentFacts) -> [OwlHint] {
        var out: [OwlHint] = []
        let text = c.text as NSString
        let all = NSRange(location: 0, length: text.length)
        func hint(_ id: String, _ kind: OwlHint.Kind, _ title: String, _ detail: String? = nil, range: NSRange? = nil, replacement: String? = nil) {
            out.append(OwlHint(id: id, kind: kind, title: title, detail: detail, range: range, replacement: replacement, source: "rules"))
        }

        if facts.changedOnDisk {
            hint(Self.reloadID, .warning, String(localized: "This file changed on disk. Reload?"),
                 String(localized: "Another app saved it since you opened it. Reloading replaces your unsaved changes (you can undo it)."))
        }
        if let since = facts.unsavedSince, now().timeIntervalSince(since) > unsavedThreshold {
            hint(Self.saveCopyID, .tip, String(localized: "Unsaved for over 2 hours. Save a copy?"),
                 String(localized: "Cedric keeps unsaved tabs across launches, but a copy on disk is safer."))
        }
        if facts.isWholeDocument, Self.isLetter(c.text) {
            hint(Self.letterID, .tip, String(localized: "It looks like you’re writing a letter. Would you like help?"))
        }
        if facts.isWholeDocument, let pretty = JSONFormatter.prettyIfMinified(c.text) {
            hint(Self.jsonID, .fix, String(localized: "Looks like JSON. Format it?"),
                 String(localized: "Pretty-prints it with two-space indents; key order is kept."), range: all, replacement: pretty)
        }
        let lines = Self.lines(text)
        if let r = mixedIndent(text, lines: lines) {
            hint(Self.mixedIndentID, .fix, String(localized: "Mixed tabs and spaces. Convert to spaces?"),
                 String(localized: "\(r.tabs) lines indent with tabs and \(r.spaces) with spaces. Tabs become \(tabWidth) spaces."),
                 range: r.range, replacement: r.replacement)
        }
        if c.language != "markdown", let r = trailing(text, lines: lines) {
            hint(Self.trailingID, .fix, String(localized: "\(r.count) lines end in spaces. Trim?"),
                 String(localized: "Removes spaces and tabs at the ends of lines."), range: r.range, replacement: r.replacement)
        }
        if facts.lineEnding == .crlf {
            hint(Self.crlfID, .explain, String(localized: "Windows line endings (CRLF)."),
                 String(localized: "Cedric keeps CRLF when you save. Change it from the status bar."))
        }
        return out
    }

    // MARK: Rules

    /// "Dear …" and more than three lines.
    public static func isLetter(_ s: String) -> Bool {
        guard s.hasPrefix("Dear ") else { return false }
        var lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines.count > 3
    }

    /// Content ranges of each line (without the newline).
    static func lines(_ s: NSString) -> [NSRange] {
        var out: [NSRange] = []
        var i = 0
        let n = s.length
        while i < n {
            var end = i
            while end < n, s.character(at: end) != 10 { end += 1 }
            out.append(NSRange(location: i, length: end - i))
            i = end + 1
        }
        return out
    }

    struct Rewrite { var range: NSRange; var replacement: String; var count: Int }

    /// Rewrites the span from the first to the last changed line.
    private static func rewrite(_ s: NSString, _ lines: [NSRange], _ change: (NSRange) -> String?) -> Rewrite? {
        var first = -1, last = -1, count = 0
        var changed: [Int: String] = [:]
        for (i, r) in lines.enumerated() {
            if let new = change(r) {
                changed[i] = new
                if first < 0 { first = i }
                last = i
                count += 1
            }
        }
        guard first >= 0 else { return nil }
        let span = NSRange(location: lines[first].location, length: NSMaxRange(lines[last]) - lines[first].location)
        var out = ""
        for i in first...last {
            if i > first { out += "\n" }
            out += changed[i] ?? s.substring(with: lines[i])
        }
        return Rewrite(range: span, replacement: out, count: count)
    }

    func mixedIndent(_ s: NSString, lines: [NSRange]) -> (range: NSRange, replacement: String, tabs: Int, spaces: Int)? {
        var tabs = 0, spaces = 0
        for r in lines where r.length > 0 {
            let c = s.character(at: r.location)
            if c == 9 { tabs += 1 } else if c == 32, r.length > 1, s.character(at: r.location + 1) == 32 { spaces += 1 }
        }
        guard tabs > 0, spaces > 0 else { return nil }
        let w = tabWidth
        guard let rw = Self.rewrite(s, lines, { r in
            var i = r.location, col = 0, sawTab = false
            while i < NSMaxRange(r) {
                let c = s.character(at: i)
                if c == 9 { sawTab = true; col += w - col % w } else if c == 32 { col += 1 } else { break }
                i += 1
            }
            guard sawTab else { return nil }
            return String(repeating: " ", count: col) + s.substring(with: NSRange(location: i, length: NSMaxRange(r) - i))
        }) else { return nil }
        return (rw.range, rw.replacement, tabs, spaces)
    }

    func trailing(_ s: NSString, lines: [NSRange]) -> Rewrite? {
        let rw = Self.rewrite(s, lines) { r in
            var e = NSMaxRange(r)
            while e > r.location, s.character(at: e - 1) == 32 || s.character(at: e - 1) == 9 { e -= 1 }
            // A whitespace-only line is left alone (often an editor's auto-indent).
            guard e < NSMaxRange(r), e > r.location else { return nil }
            return s.substring(with: NSRange(location: r.location, length: e - r.location))
        }
        guard let rw, rw.count >= trailingMinLines else { return nil }
        return rw
    }
}

/// Re-indents JSON without reordering keys (JSONSerialization would sort
/// them through NSDictionary).
public enum JSONFormatter {
    /// The pretty-printed text if `s` is a JSON object or array written on
    /// one line; nil if it isn't JSON or already spans several lines.
    public static func prettyIfMinified(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[", !trimmed.contains("\n"),
              !hasTrailingComma(trimmed), // JSONSerialization lets these through
              (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil else { return nil }
        let pretty = format(trimmed)
        guard pretty.contains("\n") else { return nil } // {} or []
        return pretty + (s.hasSuffix("\n") ? "\n" : "")
    }

    /// A comma right before a closing bracket, outside strings.
    static func hasTrailingComma(_ s: String) -> Bool {
        var inString = false, escaped = false, lastComma = false
        for c in s.utf8 {
            if inString {
                if escaped { escaped = false } else if c == 92 { escaped = true } else if c == 34 { inString = false }
                continue
            }
            switch c {
            case 34: inString = true; lastComma = false
            case 44: lastComma = true
            case 125, 93: if lastComma { return true }
            case 32, 9, 10, 13: break
            default: lastComma = false
            }
        }
        return false
    }

    /// Two-space indents, one member per line, "key": value.
    public static func format(_ s: String, indent: String = "  ") -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count * 2)
        var depth = 0
        var inString = false, escaped = false
        let chars = Array(s)
        var i = 0
        func newline() { out.append("\n"); for _ in 0..<depth { out.append(indent) } }
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                i += 1
                continue
            }
            switch c {
            case "\"": inString = true; out.append(c)
            case "{", "[":
                // Empty object or array stays on one line.
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == (c == "{" ? "}" : "]") {
                    out.append(c); out.append(chars[j]); i = j
                } else {
                    out.append(c); depth += 1; newline()
                }
            case "}", "]": depth = max(0, depth - 1); newline(); out.append(c)
            case ",": out.append(c); newline()
            case ":": out.append(": ")
            case " ", "\t", "\n", "\r": break
            default: out.append(c)
            }
            i += 1
        }
        return out
    }
}
