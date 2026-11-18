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
        // CSV/TSV: a leading or trailing tab or space is an empty field or
        // part of a value, not indentation or stray whitespace.
        let table = c.language == Language.csv.rawValue
        if facts.isWholeDocument, !table, Self.isLetter(c.text) {
            hint(Self.letterID, .tip, String(localized: "It looks like you’re writing a letter. Would you like help?"))
        }
        if facts.isWholeDocument, let pretty = JSONFormatter.prettyIfMinified(c.text) {
            hint(Self.jsonID, .fix, String(localized: "Looks like JSON. Format it?"),
                 String(localized: "Pretty-prints it with two-space indents; key order is kept."), range: all, replacement: pretty)
        } else if !facts.isWholeDocument, Self.startsLongOneLineJSON(c) {
            // Only the start of a long one-line file is in view: no
            // replacement here. Fix it formats the whole file (the app
            // checks all of it first, see wholeDocumentJSONID).
            hint(Self.jsonID, .fix, String(localized: "Looks like JSON. Format it?"),
                 String(localized: "Pretty-prints the whole file with two-space indents; key order is kept. If the whole file isn’t valid JSON, nothing changes."))
        }
        let lines = Self.lines(text)
        moreHints(c, facts: facts, text: text, lines: lines) { hint($0, $1, $2, $3, range: $4, replacement: $5) }
        if !table, c.language != "yaml" || !out.contains(where: { $0.id == Self.yamlTabsID }), let r = mixedIndent(text, lines: lines, fileName: c.fileName) {
            hint(Self.mixedIndentID, .fix,
                 r.toTabs ? String(localized: "Mixed tabs and spaces. Convert to tabs?") : String(localized: "Mixed tabs and spaces. Convert to spaces?"),
                 r.toTabs ? String(localized: "\(r.tabs) lines indent with tabs and \(r.spaces) with spaces. Every \(tabWidth) spaces become a tab.")
                          : String(localized: "\(r.tabs) lines indent with tabs and \(r.spaces) with spaces. Tabs become \(tabWidth) spaces."),
                 range: r.range, replacement: r.replacement)
        }
        tidyHints(c, facts: facts, text: text, lines: lines) { hint($0, $1, $2, $3, range: $4, replacement: $5) }
        if c.language != "markdown", !table, let r = trailing(text, lines: lines) {
            hint(Self.trailingID, .fix, String(localized: "\(r.count) lines end in spaces. Trim?"),
                 String(localized: "Removes spaces and tabs at the ends of lines."), range: r.range, replacement: r.replacement)
        }
        fileHints(c, facts: facts, text: text) { hint($0, $1, $2, $3, range: $4, replacement: $5) }
        if !facts.isWholeDocument {
            // A window of a longer file: say that a fix covers only it.
            let note = String(localized: "Only the part of the file around what’s on screen is changed.")
            out = out.map { h in
                guard h.replacement != nil, h.range != nil else { return h }
                return OwlHint(id: h.id, kind: h.kind, title: h.title, detail: [h.detail, note].compactMap { $0 }.joined(separator: " "),
                               range: h.range, replacement: h.replacement, source: h.source)
            }
        }
        if facts.lineEnding == .crlf, !facts.mixedLineEndings {
            hint(Self.crlfID, .explain, String(localized: "Windows line endings (CRLF)."),
                 String(localized: "Cedric keeps CRLF when you save. Change it from the status bar."))
        }
        return out
    }

    // MARK: Rules

    /// A window that is the start of a file whose first line runs past it,
    /// beginning like a JSON object or array: a long minified JSON file.
    public static func startsLongOneLineJSON(_ c: OwlContext) -> Bool {
        guard c.language == "json", c.textStart == 0, !c.isWholeDocument else { return false }
        let t = c.text.drop { $0 == " " || $0 == "\t" || $0 == "\u{FEFF}" }
        return (t.first == "{" || t.first == "[") && !c.text.contains("\n")
    }

    /// Formats a whole document for the owl's Fix it on a long one-line
    /// JSON file: the pretty text, or why not (the whole file must be
    /// valid JSON). Pure; the app runs it off the main thread.
    public static func formatWholeJSON(_ s: String) -> Result<String, TextToolError> {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let pretty = try JSONFormatter.format(trimmed, pretty: true)
            return .success(pretty + (s.hasSuffix("\n") ? "\n" : ""))
        } catch let e as TextToolError {
            return .failure(e)
        } catch {
            return .failure(.invalidJSON(error.localizedDescription))
        }
    }

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
    static func rewrite(_ s: NSString, _ lines: [NSRange], _ change: (NSRange) -> String?) -> Rewrite? {
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

    /// Makefiles need tabs: never offered "Convert to spaces" there.
    static func needsTabs(_ fileName: String?) -> Bool {
        guard let n = fileName else { return false }
        return n == "Makefile" || n == "makefile" || n == "GNUmakefile" || n.hasSuffix(".mk") || n.hasSuffix(".go") || n == "go.mod"
    }

    /// Lines indented with tabs and lines indented with spaces: converts the
    /// minority to the majority (spaces on a tie, tabs in a Makefile).
    func mixedIndent(_ s: NSString, lines: [NSRange], fileName: String? = nil) -> (range: NSRange, replacement: String, tabs: Int, spaces: Int, toTabs: Bool)? {
        var tabs = 0, spaces = 0
        for r in lines where r.length > 0 {
            let c = s.character(at: r.location)
            if c == 9 { tabs += 1 } else if c == 32, r.length > 1, s.character(at: r.location + 1) == 32 { spaces += 1 }
        }
        guard tabs > 0, spaces > 0 else { return nil }
        let w = tabWidth
        let toTabs = tabs > spaces || Self.needsTabs(fileName)
        guard let rw = Self.rewrite(s, lines, { r in
            var i = r.location, col = 0, sawTab = false, sawSpace = false
            while i < NSMaxRange(r) {
                let c = s.character(at: i)
                if c == 9 { sawTab = true; col += w - col % w } else if c == 32 { sawSpace = true; col += 1 } else { break }
                i += 1
            }
            let rest = s.substring(with: NSRange(location: i, length: NSMaxRange(r) - i))
            if toTabs {
                // Only whole tab stops of spaces become tabs; a remainder (alignment) stays.
                guard sawSpace, col >= w else { return nil }
                let new = String(repeating: "\t", count: col / w) + String(repeating: " ", count: col % w)
                return new == s.substring(with: NSRange(location: r.location, length: i - r.location)) ? nil : new + rest
            }
            guard sawTab else { return nil }
            return String(repeating: " ", count: col) + rest
        }) else { return nil }
        return (rw.range, rw.replacement, tabs, spaces, toTabs)
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

/// The owl's "pretty-print this?" check, on the same validating formatter
/// as Text Tools › JSON Pretty Print (TextTools.swift), so the owl's fix and
/// the menu command always produce identical text.
extension JSONFormatter {
    /// The pretty-printed text if `s` is a JSON object or array written on
    /// one line; nil if it isn't valid JSON or already spans several lines.
    public static func prettyIfMinified(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[", !trimmed.contains("\n"),
              let pretty = try? format(trimmed, pretty: true) else { return nil }
        guard pretty.contains("\n") else { return nil } // {} or []
        return pretty + (s.hasSuffix("\n") ? "\n" : "")
    }
}
