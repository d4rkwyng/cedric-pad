import Foundation

/// The script check's verdict, kept honest in code whatever the model
/// says. Cedric never tells anyone a script is safe: a line that claims
/// so becomes "No obvious red flags (not a guarantee)", and the verdict is
/// forced to "Don't run it — review the flagged lines" when the offline
/// scan found a high-risk line or not all of the script was reviewed.
/// The model is told the same (OwlPrompts); this is the backstop, which
/// also holds when a script's own text talks the model into a verdict.
public enum ScriptVerdict {
    /// The three verdicts the model is asked to choose from.
    public static let noRedFlags = "No obvious red flags (not a guarantee)"
    public static let trustSource = "Run only if you trust the source"
    public static let dontRun = "Don't run it"
    /// The verdict forced by a high finding or a partial review.
    public static let forcedDontRun = "Don't run it — review the flagged lines"

    /// Why a verdict is forced.
    public enum Reason: Sendable, Equatable {
        case highFinding, truncated
        public var note: String {
            switch self {
            case .highFinding: return String(localized: "The offline scan found a high-risk line, so the verdict is fixed whatever the model says.")
            case .truncated: return String(localized: "Only part of the script was reviewed, so no reassuring verdict can be given.")
            }
        }
    }

    /// The forced reason, if any: a high finding comes first.
    public static func forcedReason(scanHasHigh: Bool, truncated: Bool) -> Reason? {
        scanHasHigh ? .highFinding : truncated ? .truncated : nil
    }

    private static let verdictLine = try! NSRegularExpression(pattern: #"^[\s>*_#-]*verdict\b"#, options: [.caseInsensitive])
    /// "safe" as a word: "safe to run", "is safe", "safe".
    private static let safeWord = try! NSRegularExpression(pattern: #"\bsafe\b"#, options: [.caseInsensitive])
    /// A claim of safety anywhere in the answer, not only the verdict.
    private static let safeClaim = try! NSRegularExpression(
        pattern: #"\bsafe\s+to\s+(?:run|use|execute|install)\b|\b(?:is|are|looks|seems|appears|perfectly|completely|totally|entirely|100%)\s+(?:\w+\s+)?safe\b"#,
        options: [.caseInsensitive])
    /// Words that negate a "safe" right after them ("not safe", "isn't really safe").
    private static let negation = try! NSRegularExpression(
        pattern: #"\b(?:not|never|no\s+longer|isn['’]t|aren['’]t|wasn['’]t|won['’]t|wouldn['’]t|cannot|can['’]t)\s+(?:\w+\s+)?$"#,
        options: [.caseInsensitive])
    /// "Don't run it" in the same line.
    private static let dontRunPhrase = try! NSRegularExpression(pattern: #"\bdon['’]t\s+run\b|\bdo\s+not\s+run\b"#, options: [.caseInsensitive])

    static func has(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// A line claims the script is safe: some "safe" in it isn't directly
    /// negated. `strict` (the verdict and final lines): any "safe" counts.
    public static func claimsSafe(_ line: String, strict: Bool) -> Bool {
        let ns = line as NSString
        for m in (strict ? safeWord : safeClaim).matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            // The word "safe" in the match, and what comes before it.
            let r = safeWord.firstMatch(in: line, range: m.range)?.range ?? m.range
            let before = ns.substring(to: r.location)
            if !has(negation, before) { return true }
        }
        return false
    }

    public static func isVerdictLine(_ line: String) -> Bool { has(verdictLine, line) }

    private static let inlineVerdict = try! NSRegularExpression(pattern: #"[*_]*\bverdict\b[*_]*\s*:.*$"#, options: [.caseInsensitive])

    /// The answer as shown: every claim of safety rewritten, and, when
    /// `forced`, any verdict the model gave replaced by `forcedDontRun`.
    public static func clamp(_ answer: String, forced: Reason? = nil) -> String {
        var lines = answer.components(separatedBy: "\n")
        // Forced: the model's verdicts go first, so none is rewritten into a reassuring line.
        if forced != nil {
            lines.removeAll { isVerdictLine($0) }
            lines = lines.map(withoutInlineVerdict)
        }
        let lastText = lines.lastIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        for i in lines.indices {
            lines[i] = clampLine(lines[i], strict: i == lastText)
        }
        if let forced {
            while let l = lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            lines += forcedLines(forced)
        }
        return lines.joined(separator: "\n")
    }

    /// One line with any safe claim rewritten. `last`: it is the answer's
    /// last line, where any "safe" counts (as on a verdict line).
    public static func clampLine(_ line: String, strict last: Bool) -> String {
        let verdict = isVerdictLine(line)
        guard claimsSafe(line, strict: verdict || last) else { return line }
        // "Safe" and "don't run" together: keep the warning, drop the claim.
        let text = has(dontRunPhrase, line) ? dontRun : noRedFlags
        return verdict ? "Verdict: " + text + "." : text + "."
    }

    /// A verdict at the end of a sentence ("… shown lines. Verdict: Don't run it") cut off.
    static func withoutInlineVerdict(_ l: String) -> String {
        guard let m = inlineVerdict.firstMatch(in: l, range: NSRange(location: 0, length: (l as NSString).length)) else { return l }
        return (l as NSString).substring(to: m.range.location).trimmingCharacters(in: .whitespaces)
    }

    /// Where a partial "Verdict" starts at the end of `s`, if one does.
    static func partialVerdictMatch(_ s: String) -> Int? {
        partialVerdict.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length))?.range.location
    }

    static func forcedLines(_ forced: Reason) -> [String] { [forced.note, "Verdict: " + forcedDontRun + "."] }

    /// The start of a "Verdict" still arriving at the end of the text ("… Verd").
    private static let partialVerdict = try! NSRegularExpression(pattern: #"[*_]*\bv(?:e(?:r(?:d(?:i(?:c(?:t)?)?)?)?)?)?[*_]*\s*$"#, options: [.caseInsensitive])
}

/// The script check's answer as it streams in: every update is clamped
/// before it is shown, so "safe to run" never appears, not even for one
/// frame, and with a forced verdict the model's own verdict never shows.
/// Incremental: finished lines are clamped once and kept; each update
/// clamps only the line still arriving (cheap however long the answer).
public struct ScriptVerdictStream: Sendable {
    public let forced: ScriptVerdict.Reason?
    /// Everything received.
    public private(set) var raw = ""
    /// Finished lines as shown (a hidden verdict line is left out).
    private var done: [String] = []
    /// Where in `raw` (UTF-8 offset) the line still arriving starts.
    private var tailOffset = 0
    private var tailStart: String.Index { raw.utf8.index(raw.utf8.startIndex, offsetBy: tailOffset) }

    public init(forced: ScriptVerdict.Reason?) {
        self.forced = forced
    }

    /// Adds a streamed piece; the text to show now.
    @discardableResult
    public mutating func append(_ piece: String) -> String {
        raw += piece
        while let nl = raw.utf8[tailStart...].firstIndex(of: 0x0A) {
            let line = String(raw[tailStart..<nl])
            tailOffset = raw.utf8.distance(from: raw.utf8.startIndex, to: nl) + 1
            if forced != nil {
                if ScriptVerdict.isVerdictLine(line) { continue }
                done.append(ScriptVerdict.clampLine(ScriptVerdict.withoutInlineVerdict(line), strict: false))
            } else {
                done.append(ScriptVerdict.clampLine(line, strict: false))
            }
        }
        return display
    }

    /// The text to show for what has arrived so far.
    public var display: String {
        var tail = String(raw[tailStart...])
        if forced != nil {
            // The model's verdict, whole or still arriving, never shows.
            if ScriptVerdict.isVerdictLine(tail) { tail = "" }
            tail = ScriptVerdict.withoutInlineVerdict(tail)
            if let m = ScriptVerdict.partialVerdictMatch(tail) {
                tail = (tail as NSString).substring(to: m).trimmingCharacters(in: .whitespaces)
            }
        }
        var lines = done + [ScriptVerdict.clampLine(tail, strict: true)]
        if let forced {
            while let l = lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            lines += ScriptVerdict.forcedLines(forced)
        }
        return lines.joined(separator: "\n")
    }
}
