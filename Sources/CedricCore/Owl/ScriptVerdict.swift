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

    /// The answer as shown: every claim of safety rewritten, and, when
    /// `forced`, any verdict the model gave replaced by `forcedDontRun`.
    public static func clamp(_ answer: String, forced: Reason? = nil) -> String {
        var lines = answer.components(separatedBy: "\n")
        let lastText = lines.lastIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        for i in lines.indices {
            let verdict = isVerdictLine(lines[i])
            let strict = verdict || i == lastText
            guard claimsSafe(lines[i], strict: strict) else { continue }
            // "Safe" and "don't run" together: keep the warning, drop the claim.
            let text = has(dontRunPhrase, lines[i]) ? dontRun : noRedFlags
            lines[i] = verdict ? "Verdict: " + text + "." : text + "."
        }
        if let forced {
            lines.removeAll { isVerdictLine($0) }
            while let l = lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            lines.append(forced.note)
            lines.append("Verdict: " + forcedDontRun + ".")
        }
        return lines.joined(separator: "\n")
    }
}
