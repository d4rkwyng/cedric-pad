import Foundation

/// What Owlink's offline checks currently say about a document, as a short
/// list for Ask Cedric (0.4.0): the check_document tool for models trusted
/// with tools, and the same list put into the prompt before the call for
/// a model without tools (Apple Intelligence) when the question is about
/// problems (TN3193's "run the tool before you call the model").
///
/// The sources are the ones the owl already has: the rules (writing
/// checks for Markdown links, headings and footnotes, the code checks of
/// each language pack, Style Check when it is on) and the grammar
/// checker's current findings, which the app passes in the snapshot. No
/// AI, nothing sent anywhere. Pure.
public enum OwlChecks {
    public struct Finding: Sendable, Equatable {
        /// 1-based line.
        public var line: Int
        /// The rule's id without the "rules." prefix ("md.broken-anchor"),
        /// or "grammar".
        public var rule: String
        public var message: String
    }

    public struct Report: Sendable, Equatable {
        public var findings: [Finding]
        /// The lines the rules read: all of them, or a window around the
        /// visible text of a document too long to check whole.
        public var firstLine: Int
        public var lastLine: Int
        public var whole: Bool
    }

    /// The rules read at most this much text (UTF-16 units) in one go: a
    /// longer document is checked around the visible text.
    public static let ruleCap = 64 * 1024
    /// Findings listed, at most.
    public static let maxFindings = 30

    /// Hints that are about the file's state, not problems in its text.
    static let notProblems: Set<String> = [RulesHintProvider.reloadID, RulesHintProvider.saveCopyID,
                                           RulesHintProvider.letterID, RulesHintProvider.crlfID]

    /// Runs the rules over the snapshot (whole, or the window around the
    /// visible text) and adds the grammar findings, sorted by line.
    public static func run(_ s: OwlDocumentSnapshot) -> Report {
        let ns = s.text as NSString
        let window = OwlContextWindow(text: ns, visible: s.visible, selection: nil, fileName: s.fileName, language: s.language,
                                      documentID: UUID(), editGeneration: s.generation, cap: ruleCap)
        var facts = s.facts
        facts.isWholeDocument = window.isWholeDocument
        // The file's state (changed on disk, unsaved for hours) isn't a problem in its text.
        facts.changedOnDisk = false
        facts.unsavedSince = nil
        let hints = RulesHintProvider().check(window.context, facts: facts)
        var out: [Finding] = []
        for h in hints where !notProblems.contains(h.id) && h.kind != .explain {
            let rule = h.id.hasPrefix("rules.") ? String(h.id.dropFirst(6)) : h.id
            let line = h.range.map { s.lineNumber(at: $0.location + window.offset) } ?? 1
            // A rule reports its first place "(and 3 more)": the others, each on its line.
            let others = h.detail.flatMap(andMore).flatMap { Int($0) }.map { more(h, count: $0, window: window.context, facts: facts) } ?? []
            var message = h.title
            if others.isEmpty, let d = h.detail, let n = andMore(d) { message += " (\(n) more like it)" }
            out.append(Finding(line: line, rule: rule, message: message))
            for o in others { out.append(Finding(line: s.lineNumber(at: o.offset + window.offset), rule: rule, message: o.title)) }
        }
        for g in s.grammar where NSMaxRange(g.range) <= s.length {
            var m = "“\(g.original.prefix(40))”: \(g.description)"
            if let c = g.correction { m += " Suggestion: “\(c.prefix(40))”." }
            out.append(Finding(line: s.lineNumber(at: g.range.location), rule: "grammar", message: m))
        }
        out.sort { $0.line < $1.line }
        let first = s.lineNumber(at: window.offset)
        let last = s.lineNumber(at: max(window.offset, window.offset + (window.context.text as NSString).length - 1))
        return Report(findings: out, firstLine: first, lastLine: last, whole: window.isWholeDocument)
    }

    /// The rest of a language rule's places: the rule again with each place
    /// found blanked (same length, newlines kept), at most `count` (and 10).
    static func more(_ h: OwlHint, count: Int, window c: OwlContext, facts: OwlDocumentFacts) -> [(offset: Int, title: String)] {
        guard var r = h.range, let rule = RulesHintProvider.languageRules.first(where: { $0.id == h.id }) else { return [] }
        var units = Array((c.text as NSString).length > 0 ? c.text.utf16 : "".utf16)
        var out: [(Int, String)] = []
        for _ in 0..<min(count, 10) {
            guard NSMaxRange(r) <= units.count else { break }
            for i in r.location..<NSMaxRange(r) where units[i] != 10 { units[i] = 32 }
            let text = String(utf16CodeUnits: units, count: units.count)
            let ctx = OwlContext(fileName: c.fileName, language: c.language, text: text, textStart: c.textStart, visibleRange: c.visibleRange,
                                 selection: nil, documentID: c.documentID, editGeneration: c.editGeneration, isWholeDocument: c.isWholeDocument)
            let ns = text as NSString
            var next: (NSRange, String)?
            RulesHintProvider().languageHints(ctx, facts: facts, text: ns, lines: RulesHintProvider.lines(ns), rules: [rule]) { _, _, title, _, range, _ in
                if next == nil, let range { next = (range, title) }
            }
            guard let (nr, title) = next, nr != r else { break }
            out.append((nr.location, title))
            r = nr
        }
        return out
    }

    /// "(and 3 more)" in a hint's detail: "3".
    static func andMore(_ detail: String) -> String? {
        guard let r = detail.range(of: #"\(and (\d+) more\)"#, options: .regularExpression) else { return nil }
        return detail[r].filter(\.isNumber)
    }

    /// "12| md.broken-anchor: The link …" per finding, capped at `bytes`
    /// (and `maxFindings`), with a header saying what was checked.
    public static func listing(_ r: Report, bytes: Int = OwlTools.maxOutputBytes) -> String {
        var head = r.whole ? "Offline checks of the whole document" : "Offline checks of lines \(r.firstLine)-\(r.lastLine) (the file is too long to check whole)"
        if r.findings.isEmpty { return head + ": no problems found." }
        head += ": \(r.findings.count) finding\(r.findings.count == 1 ? "" : "s") (line| rule: message)"
        var lines = [head]
        for f in r.findings.prefix(maxFindings) { lines.append("\(f.line)| \(f.rule): \(f.message)") }
        if r.findings.count > maxFindings { lines.append("(\(r.findings.count - maxFindings) more not listed)") }
        return OwlTools.cap(lines.joined(separator: "\n"), bytes: bytes)
    }

    /// A typed question about problems, errors or the checks ("what
    /// problems does this file have?", "any broken links?", "check my
    /// grammar"): the one a model without tools gets the list for.
    public static func asksAboutProblems(_ question: String) -> Bool {
        let words = Set(question.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
        let q = question.lowercased()
        if !words.isDisjoint(with: problemWords) { return true }
        return ["what's wrong", "what is wrong", "whats wrong", "anything wrong", "go wrong", "proofread", "lint"].contains { q.contains($0) }
    }

    static let problemWords: Set<String> = ["problem", "problems", "error", "errors", "issue", "issues", "mistake", "mistakes",
                                            "broken", "check", "checks", "checker", "warning", "warnings", "typo", "typos",
                                            "grammar", "bug", "bugs", "wrong", "invalid", "dead", "lint", "linter", "fix", "fixes"]
}
