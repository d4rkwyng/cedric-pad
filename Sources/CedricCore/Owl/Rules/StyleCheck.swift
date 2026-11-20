import Foundation

/// Style Check (0.4.0, after iA Writer's and Ulysses'): filler words,
/// redundancies ("past history") and clichés in prose, offline, no AI.
/// Off by default (Settings › Style Check). It reads only prose: in
/// Markdown, `ProseMask` blanks code blocks, code spans, link targets,
/// URLs, tables, HTML and front matter first (what the grammar checker
/// reads); in Plain Text only text that reads as prose, never a data file.
///
/// Each phrase found is its own owl hint (`rules.style.<kind>:<phrase>`),
/// so they come one at a time, each with why and "Ignore this word"
/// (Settings' exceptions). The lists are per language (`StyleCheck.lists`):
/// to add one, add a `StyleList` with its code.
public enum StyleCheck {
    public enum Kind: String, Sendable, CaseIterable {
        case filler, redundancy, cliche
    }

    public struct Entry: Sendable, Equatable {
        /// Lower case; words separated by one space; a final `*` matches any
        /// word ending ("utiliz*").
        public var phrase: String
        public var kind: Kind
        /// What to write instead ("" to cut it); nil: no fix, rephrase.
        public var replacement: String?

        public init(_ phrase: String, _ kind: Kind, replacement: String? = nil) {
            self.phrase = phrase
            self.kind = kind
            self.replacement = replacement
        }
    }

    public struct StyleList: Sendable {
        /// ISO 639-1 code ("en").
        public var language: String
        public var entries: [Entry]
    }

    /// The settings the rules see (`OwlDocumentFacts.styleCheck`; nil: off).
    public struct Settings: Sendable, Equatable {
        public var language: String
        /// The user's own phrases to flag (same syntax as the lists).
        public var extra: [String]
        /// Phrases never flagged (also turns a list entry off).
        public var exceptions: [String]

        public init(language: String = "en", extra: [String] = [], exceptions: [String] = []) {
            self.language = language
            self.extra = extra
            self.exceptions = exceptions
        }
    }

    public struct Hit: Sendable, Equatable {
        public var range: NSRange
        /// The text found, normalised (lower case, single spaces).
        public var phrase: String
        public var entry: Entry
    }

    public static let idPrefix = "rules.style."
    /// At most this many hints per query (the owl shows one at a time).
    public static let maxHints = 5

    /// The lists by language code.
    public static let lists: [String: StyleList] = ["en": english]

    public static func isStyleHint(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    /// "rules.style.filler:very" → "very".
    public static func phrase(fromHintID id: String) -> String? {
        guard isStyleHint(id), let colon = id.firstIndex(of: ":") else { return nil }
        return String(id[id.index(after: colon)...])
    }

    public static func hintID(_ hit: Hit) -> String { idPrefix + hit.entry.kind.rawValue + ":" + hit.phrase }

    /// Lower case, single spaces, curly apostrophes straight.
    public static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: Matching

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var key: String?
        var value: (NSRegularExpression, [Entry])?
    }
    private static let cache = Cache()

    /// One case-insensitive regular expression for all the entries (longest
    /// first, so "very very" never wins over "past history"), with the
    /// entry of each alternative. Cached for the last settings.
    static func matcher(_ settings: Settings) -> (NSRegularExpression, [Entry])? {
        let key = settings.language + "\u{1}" + settings.extra.joined(separator: "\u{2}")
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if cache.key == key, let v = cache.value { return v }
        var entries = lists[settings.language]?.entries ?? []
        for e in settings.extra {
            let p = normalize(e)
            guard !p.isEmpty, p.count <= 60, !entries.contains(where: { $0.phrase == p }) else { continue }
            entries.append(Entry(p, .filler))
        }
        entries.sort { $0.phrase.count > $1.phrase.count }
        guard !entries.isEmpty else { return nil }
        let alts = entries.map { e -> String in
            var p = e.phrase
            let wild = p.hasSuffix("*")
            if wild { p.removeLast() }
            let words = p.split(separator: " ").map { w in
                NSRegularExpression.escapedPattern(for: String(w)).replacingOccurrences(of: "'", with: "['’]")
            }
            return "(" + words.joined(separator: #"\s+"#) + (wild ? #"[\p{L}\p{M}]*"# : "") + ")"
        }
        let pattern = #"(?<![\p{L}\p{M}\p{N}'’-])(?:"# + alts.joined(separator: "|") + #")(?![\p{L}\p{M}\p{N}-])"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        cache.key = key
        cache.value = (re, entries)
        return (re, entries)
    }

    /// The phrases in `text` (offsets in `text`), in order. `masked` is
    /// the text with everything that isn't prose blanked (same offsets).
    public static func hits(masked: String, settings: Settings) -> [Hit] {
        guard let (re, entries) = matcher(settings) else { return [] }
        let except = Set(settings.exceptions.map(normalize).filter { !$0.isEmpty })
        let ns = masked as NSString
        var out: [Hit] = []
        for m in re.matches(in: masked, range: NSRange(location: 0, length: ns.length)) {
            // Which alternative matched: its group.
            var i = 1
            while i <= entries.count, m.range(at: i).location == NSNotFound { i += 1 }
            guard i <= entries.count else { continue }
            let entry = entries[i - 1]
            let phrase = normalize(ns.substring(with: m.range))
            if except.contains(phrase) || except.contains(entry.phrase) { continue }
            out.append(Hit(range: m.range, phrase: phrase, entry: entry))
        }
        return out
    }

    // MARK: Hints

    /// Style Check's hints for the rules provider: one per phrase (the first
    /// place it appears), at most `maxHints`, as (id, kind, title, detail,
    /// range, replacement). Markdown and Plain Text only, prose only.
    static func hints(_ c: OwlContext, facts: OwlDocumentFacts, text: NSString, lines: [NSRange]) -> [(String, OwlHint.Kind, String, String?, NSRange, String?)] {
        guard let settings = facts.styleCheck else { return [] }
        guard let language = Language(rawValue: c.language), language == .markdown || language == .plain,
              ProseDetector.languageAllows(language, fileName: c.fileName) else { return [] }
        if language == .plain, !ProseDetector.isProse(text, language: .plain, fileName: c.fileName) { return [] }
        // A window of a longer Markdown file that may start inside a fence: its code could read as prose.
        if language == .markdown, !facts.isWholeDocument, c.textStart > 0, MarkdownRules.structure(text, lines: lines).unclosed != nil { return [] }
        let masked = ProseMask.masked(text, language: language)
        let found = hits(masked: masked, settings: settings)
        guard !found.isEmpty else { return [] }
        var counts: [String: Int] = [:]
        for h in found { counts[h.phrase, default: 0] += 1 }
        var seen = Set<String>()
        var out: [(String, OwlHint.Kind, String, String?, NSRange, String?)] = []
        for h in found where seen.insert(h.phrase).inserted {
            let shown = text.substring(with: h.range)
            let edit = fix(h, text: text)
            let more = RulesHintProvider.andMore(counts[h.phrase] ?? 1)
            let (title, why) = words(h, shown: shown, edit: edit)
            out.append((hintID(h), edit == nil ? .tip : .fix, title, why + more, edit?.range ?? h.range, edit?.replacement))
            if out.count >= maxHints { break }
        }
        return out
    }

    /// The bubble's words for a phrase.
    static func words(_ h: Hit, shown: String, edit: (range: NSRange, replacement: String)?) -> (String, String) {
        let q = "“\(shown.prefix(40))”"
        switch h.entry.kind {
        case .filler:
            return (edit == nil ? String(localized: "\(q) is a filler word.") : String(localized: "\(q) is a filler word. Cut it?"),
                    String(localized: "Words like this rarely add meaning; the sentence is usually stronger without it."))
        case .redundancy:
            let instead = h.entry.replacement ?? ""
            return (String(localized: "\(q) says the same thing twice. Use “\(instead)”?"),
                    String(localized: "Part of the phrase repeats what the rest already says."))
        case .cliche:
            return (String(localized: "\(q) is a cliché."),
                    String(localized: "Readers have seen it many times; saying it plainly, in your own words, reads fresher."))
        }
    }

    /// The fix: a filler cut with the space after it (or before it, at the
    /// end of a sentence) and a comma right after it; the next word gets the
    /// capital when the filler started the sentence. A redundancy becomes
    /// its short form, keeping a capital. nil for a cliché.
    static func fix(_ h: Hit, text s: NSString) -> (range: NSRange, replacement: String)? {
        guard let rep = h.entry.replacement else { return nil }
        let original = s.substring(with: h.range)
        let capital = original.first?.isUppercase == true
        if !rep.isEmpty {
            let r = capital ? rep.prefix(1).uppercased() + rep.dropFirst() : rep
            return (h.range, r)
        }
        // The next word takes the capital only when the filler starts a
        // sentence ("Well, I think that we" keeps "we").
        var before = h.range.location
        while before > 0, s.character(at: before - 1) == 32 { before -= 1 }
        let startsSentence = before == 0 || [10, 46, 33, 63, 35, 62, 42, 45].contains(s.character(at: before - 1))   // \n . ! ? # > * -
        let capitalNext = capital && startsSentence
        var end = NSMaxRange(h.range)
        if end < s.length, s.character(at: end) == 44 { end += 1 }   // ,
        var spaceAfter = end
        while spaceAfter < s.length, s.character(at: spaceAfter) == 32 { spaceAfter += 1 }
        if spaceAfter > end {
            // "Basically, we" → "We".
            if capitalNext, spaceAfter < s.length, let u = UnicodeScalar(s.character(at: spaceAfter)), CharacterSet.lowercaseLetters.contains(u) {
                let letter = s.substring(with: NSRange(location: spaceAfter, length: 1)).uppercased()
                return (NSRange(location: h.range.location, length: spaceAfter + 1 - h.range.location), letter)
            }
            return (NSRange(location: h.range.location, length: spaceAfter - h.range.location), "")
        }
        // Last word before punctuation: the space before it goes.
        var start = h.range.location
        while start > 0, s.character(at: start - 1) == 32 { start -= 1 }
        guard start < h.range.location else { return nil }
        return (NSRange(location: start, length: end - start), "")
    }
}

extension RulesHintProvider {
    /// Style Check's hints (`StyleCheck.hints`), when it is on.
    func styleHints(_ c: OwlContext, facts: OwlDocumentFacts, text: NSString, lines: [NSRange],
                    hint: (String, OwlHint.Kind, String, String?, NSRange?, String?) -> Void) {
        for h in StyleCheck.hints(c, facts: facts, text: text, lines: lines) { hint(h.0, h.1, h.2, h.3, h.4, h.5) }
    }
}
