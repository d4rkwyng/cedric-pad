import Foundation

/// One grammar finding as the system checker reports it: `range` is
/// relative to the sentence the result covers (NSGrammarRange), with its
/// description (NSGrammarUserDescription) and corrections
/// (NSGrammarCorrections).
public struct GrammarDetail: Equatable, Sendable {
    public let range: NSRange
    public let description: String
    public let corrections: [String]

    public init(range: NSRange, description: String, corrections: [String]) {
        self.range = range
        self.description = description
        self.corrections = corrections
    }
}

/// A grammar result: the sentence (in the checked text) and its findings.
public struct GrammarResult: Equatable, Sendable {
    public let sentence: NSRange
    public let details: [GrammarDetail]

    public init(sentence: NSRange, details: [GrammarDetail]) {
        self.sentence = sentence
        self.details = details
    }
}

/// One grammar issue in the document.
public struct GrammarIssue: Equatable, Sendable {
    /// Document range of the words the finding is about.
    public var range: NSRange
    /// The text there when it was checked.
    public let original: String
    /// The checker's description, in plain words.
    public let description: String
    public let corrections: [String]

    public init(range: NSRange, original: String, description: String, corrections: [String]) {
        self.range = range
        self.original = original
        self.description = description
        self.corrections = corrections
    }

    public var correction: String? { corrections.first }
}

/// Turns checker results into issues, issues into owl hints, and keeps
/// issues on their words as the text is edited. Pure.
public enum GrammarMap {
    /// Issues from `results` over `text` (the masked text the checker
    /// read, same offsets as the document from `offset`). Drops findings
    /// outside their sentence or the text, empty ones, ones touching a
    /// blanked (non-prose) part (`prose` ranges, document offsets), and
    /// ones whose only "correction" is the text itself.
    public static func issues(_ results: [GrammarResult], text: NSString, offset: Int = 0, prose: [NSRange]? = nil) -> [GrammarIssue] {
        var out: [GrammarIssue] = []
        for r in results {
            guard r.sentence.location >= 0, NSMaxRange(r.sentence) <= text.length else { continue }
            for d in r.details {
                let local = NSRange(location: r.sentence.location + d.range.location, length: d.range.length)
                guard d.range.location >= 0, d.range.length > 0, NSMaxRange(d.range) <= r.sentence.length,
                      NSMaxRange(local) <= text.length else { continue }
                let original = text.substring(with: local)
                guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let doc = NSRange(location: local.location + offset, length: local.length)
                if let prose, !prose.contains(where: { $0.location <= doc.location && NSMaxRange(doc) <= NSMaxRange($0) }) { continue }
                let corrections = d.corrections.filter { $0 != original }
                let issue = GrammarIssue(range: doc, original: original, description: plainWords(d.description), corrections: corrections)
                if !out.contains(where: { $0.range == issue.range }) { out.append(issue) }
            }
        }
        return out.sorted { $0.range.location < $1.range.location }
    }

    /// The checker's description, tidied: whitespace collapsed, a full stop at the end.
    public static func plainWords(_ s: String) -> String {
        var t = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if t.isEmpty { return String(localized: "This may not be grammatical.") }
        if let last = t.last, !".!?".contains(last) { t += "." }
        return t
    }

    /// "Grammar: ‘a’ → ‘an’?" (or "Grammar: ‘a’?" with no correction),
    /// at most about 60 characters.
    public static func title(_ issue: GrammarIssue) -> String {
        func cut(_ s: String, _ n: Int) -> String { s.count <= n ? s : String(s.prefix(n - 1)) + "…" }
        let o = cut(issue.original, 22)
        if let c = issue.correction { return String(localized: "Grammar: ‘\(o)’ → ‘\(cut(c, 22))’?") }
        return String(localized: "Grammar: ‘\(o)’?")
    }

    public static let idPrefix = "grammar."
    /// Turns every grammar hint off ("Don't show again").
    public static let globalID = "grammar"

    /// A stable id for the coordinator (dedupe, snooze): the words and the fix.
    public static func hintID(_ issue: GrammarIssue) -> String {
        idPrefix + issue.original.lowercased() + "→" + (issue.correction ?? "")
    }

    public static func isGrammarHint(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    /// The owl's hint for `issue`; the range relative to a context that starts at `textStart`.
    public static func hint(_ issue: GrammarIssue, textStart: Int) -> OwlHint {
        OwlHint(id: hintID(issue), kind: .fix, title: title(issue), detail: issue.description,
                range: NSRange(location: issue.range.location - textStart, length: issue.range.length),
                replacement: issue.correction, source: "rules")
    }

    /// Two copies of the same word ("the the"): the owl's own doubled-word
    /// rule offers that already, so it isn't offered twice.
    public static func isDoubledWord(_ issue: GrammarIssue) -> Bool {
        let w = issue.original.lowercased().split(whereSeparator: { $0.isWhitespace })
        return w.count == 2 && w[0] == w[1]
    }

    /// Which issue the owl offers: not a doubled word, and the first at or
    /// after `caret`, else the first.
    public static func pick(_ issues: [GrammarIssue], caret: Int, eligible: (GrammarIssue) -> Bool = { _ in true }) -> GrammarIssue? {
        let ok = issues.filter { !isDoubledWord($0) && eligible($0) }
        return ok.first { $0.range.location >= caret } ?? ok.first
    }

    /// After an edit replacing `oldRange` with `newLength` units: issues
    /// after it move, ones it touches are dropped.
    public static func shift(_ issues: [GrammarIssue], oldRange: NSRange, newLength: Int) -> [GrammarIssue] {
        let delta = newLength - oldRange.length
        return issues.compactMap { i in
            // Strictly before or after: typing right against the words changes them.
            if i.range.location > NSMaxRange(oldRange) { var m = i; m.range.location += delta; return m }
            if NSMaxRange(i.range) < oldRange.location { return i }
            return nil
        }
    }

    /// Replaces the issues inside `checked` (document range) with `fresh`,
    /// keeping those outside it.
    public static func merge(_ old: [GrammarIssue], fresh: [GrammarIssue], checked: NSRange) -> [GrammarIssue] {
        (old.filter { NSIntersectionRange($0.range, checked).length == 0 && !NSLocationInRange($0.range.location, checked) } + fresh)
            .sorted { $0.range.location < $1.range.location }
    }
}

/// When a grammar bubble may pop up by itself: never while typing (until
/// `typingPause` after the last edit), and at most one per `minInterval`
/// (unless the user clicked the owl).
public struct GrammarPopupPolicy: Sendable {
    public var minInterval: TimeInterval
    public var typingPause: TimeInterval
    public private(set) var lastShown: Date?

    public init(minInterval: TimeInterval = 600, typingPause: TimeInterval = 2) {
        self.minInterval = minInterval
        self.typingPause = typingPause
    }

    public func mayPopUp(now: Date, lastTyping: Date?, userAsked: Bool = false) -> Bool {
        if userAsked { return true }
        if let t = lastTyping, now.timeIntervalSince(t) < typingPause { return false }
        if let s = lastShown, now.timeIntervalSince(s) < minInterval { return false }
        return true
    }

    public mutating func noteShown(_ now: Date) { lastShown = now }
}

/// Fix Grammar… (the step-through): the issues found, one at a time, in
/// order from the caret to the end and round from the top. Edits move
/// the ones still to come.
public struct GrammarStepper: Sendable {
    public private(set) var pending: [GrammarIssue]
    public private(set) var current: GrammarIssue?
    public private(set) var visited = 0
    public let total: Int

    public init(issues: [GrammarIssue], caret: Int) {
        let sorted = issues.sorted { $0.range.location < $1.range.location }
        pending = sorted.filter { $0.range.location >= caret } + sorted.filter { $0.range.location < caret }
        total = pending.count
    }

    /// "3 of 12" (the current one's place).
    public var progress: String { total == 0 ? "" : "\(min(visited + (current == nil ? 0 : 1), total)) of \(total)" }

    @discardableResult
    public mutating func next() -> GrammarIssue? {
        if current != nil { visited += 1 }
        current = pending.isEmpty ? nil : pending.removeFirst()
        return current
    }

    /// The edit for Change with `replacement` (nil: nothing current).
    public func change(to replacement: String) -> (range: NSRange, replacement: String)? {
        current.map { ($0.range, replacement) }
    }

    /// Any edit (ours or the user's): the issues still to come follow it;
    /// one it touched is dropped, and so is the current one.
    public mutating func textEdited(_ oldRange: NSRange, newLength: Int) {
        let before = pending.count
        pending = GrammarMap.shift(pending, oldRange: oldRange, newLength: newLength)
        visited += before - pending.count
        if let c = current {
            current = GrammarMap.shift([c], oldRange: oldRange, newLength: newLength).first
            if current == nil { visited += 1 }
        }
    }

    public var isFinished: Bool { current == nil && pending.isEmpty }
}
