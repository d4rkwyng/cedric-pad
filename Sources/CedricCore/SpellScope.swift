import Foundation

/// What the spell checker looks at. Prose (Plain Text, Markdown) is
/// checked except for code, links and markup; in code only comments and
/// strings are, never identifiers. The checking itself is the system's
/// (NSSpellChecker, in the app); this decides where, and which flagged
/// words the owl may fix by himself.
public enum SpellScope {
    public static func isProse(_ l: Language) -> Bool { l == .plain || l == .markdown }

    /// Data, not writing: JSON, YAML, TOML/INI/.env, XML, CSV/TSV and .reg. Their values
    /// are names, ids and settings, so nothing in them is checked.
    public static func isData(_ l: Language) -> Bool { l == .json || l == .yaml || l == .ini || l == .xml || l == .csv || l == .registry }

    /// File names whose text is data even though it opens as Plain Text
    /// (CSV and TSV tables; certificates, keys and requests in PEM).
    public static func isDataFile(_ fileName: String?) -> Bool {
        guard let ext = fileName.map({ ($0 as NSString).pathExtension.lowercased() }) else { return false }
        return ["csv", "tsv", "tab", "psv", "pem", "crt", "cer", "csr", "key", "p7b", "p7c"].contains(ext)
    }

    /// Whether spelling is checked at all for this document.
    public static func checks(language: Language, fileName: String?) -> Bool {
        !isData(language) && !(language == .plain && isDataFile(fileName))
    }

    /// Whether the owl may offer "Fix N typos?" (Fix All applies the first
    /// guess for each word blind): only in writing for people, by the same
    /// test as grammar (ProseDetector: Plain Text or Markdown, not a data
    /// or log file by name, and the sample reads as sentences). A log's
    /// `dur=0ms` or a config's `valeu` is data, not a typo. `text` is the
    /// owl's window (at most `ProseDetector.sampleLimit` of it is read).
    public static func offersTypoFix(_ text: NSString, language: Language, fileName: String?) -> Bool {
        isProse(language) && checks(language: language, fileName: fileName)
            && ProseDetector.isProse(text, language: language, fileName: fileName)
    }

    /// Token kinds that are words in code.
    static let codeChecked: Set<TokenKind> = [.comment, .string]
    /// Token kinds that aren't words in prose (Markdown).
    static let proseSkipped: Set<TokenKind> = [.code, .link, .tag, .attribute, .key, .punctuation,
                                                    .embeddedCode, .keyword, .type, .string, .number, .constant, .comment, .function,
                                                    .variable, .preprocessor]

    /// The parts of `range` to check, given the highlighter's tokens for
    /// the lines it covers (absolute offsets, sorted by start).
    public static func ranges(language: Language, tokens: [Token], in range: NSRange) -> [NSRange] {
        let end = NSMaxRange(range)
        if isData(language) { return [] }
        if isProse(language) {
            // The whole range minus the skipped tokens.
            var out: [NSRange] = []
            var at = range.location
            for t in tokens where proseSkipped.contains(t.kind) && t.end > range.location && t.start < end {
                if t.start > at { out.append(NSRange(location: at, length: t.start - at)) }
                at = max(at, t.end)
            }
            if at < end { out.append(NSRange(location: at, length: end - at)) }
            return out
        }
        return tokens.compactMap { t in
            guard codeChecked.contains(t.kind) else { return nil }
            let s = max(t.start, range.location), e = min(t.end, end)
            return e > s ? NSRange(location: s, length: e - s) : nil
        }
    }

    /// Whether the owl may fix this flagged word on his own: not ALL CAPS
    /// (acronyms), no digits, not part of a URL or a path.
    public static func isFixable(_ word: String, in text: NSString, at range: NSRange) -> Bool {
        guard word.count >= 2, word.rangeOfCharacter(from: .decimalDigits) == nil else { return false }
        if word == word.uppercased() { return false }
        return !isInLinkOrPath(text, at: range)
    }

    /// Whether the flagged word at `range` is part of a URL, a path or an
    /// email address (the whitespace-delimited chunk it sits in).
    public static func isInLinkOrPath(_ text: NSString, at range: NSRange) -> Bool {
        var s = range.location, e = NSMaxRange(range)
        let ws = CharacterSet.whitespacesAndNewlines
        // At most 512 characters each way (a huge line without spaces).
        while s > 0, range.location - s < 512, let u = UnicodeScalar(text.character(at: s - 1)), !ws.contains(u) { s -= 1 }
        while e < text.length, e - NSMaxRange(range) < 512, let u = UnicodeScalar(text.character(at: e)), !ws.contains(u) { e += 1 }
        let chunk = text.substring(with: NSRange(location: s, length: e - s)).lowercased()
        return chunk.contains("://") || chunk.hasPrefix("www.") || chunk.contains("/") || chunk.contains("@")
    }

    /// Typos to fix (range, replacement), as one edit: the span from the
    /// first to the last, with each replaced. Nil when there are none.
    public static func combinedFix(_ text: NSString, _ fixes: [(range: NSRange, replacement: String)]) -> (range: NSRange, replacement: String)? {
        let sorted = fixes.sorted { $0.range.location < $1.range.location }
        guard let first = sorted.first, let last = sorted.last else { return nil }
        let span = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        var out = ""
        var at = span.location
        for f in sorted {
            guard f.range.location >= at else { continue } // overlapping: skip
            out += text.substring(with: NSRange(location: at, length: f.range.location - at))
            out += f.replacement
            at = NSMaxRange(f.range)
        }
        return (span, out)
    }
}
