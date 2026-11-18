import Foundation

/// Whether a document is writing meant for people (an email, a letter,
/// notes, a story) rather than code, configuration, a log or a table, so
/// grammar checking may look at it. Pure and bounded: it reads at most
/// `sampleLimit` UTF-16 units (the owl's window or the start of the file).
///
/// A document counts as prose when its language is Plain Text or Markdown,
/// its file name isn't a data or log name, and the sample, with Markdown's
/// code, front matter, tables, inline code and URLs blanked out
/// (`ProseMask`), reads as sentences:
///
/// - at least `minWords` words, and most tokens (`minWordShare`) are
///   words: letters only (an apostrophe or hyphen inside is fine), not
///   camelCase or snake_case, not numbers or paths;
/// - common function words ("the", "and", "to", "de", "und", …) make up
///   at least `minFunctionShare` of the words: sentences have them, lists
///   of names, settings and log fields mostly don't;
/// - there is sentence punctuation, and the average sentence is between
///   `sentenceWords` words long;
/// - few symbols and operators (`{}[]<>=;|\/_*&^%$#@~` and backticks):
///   at most `maxSymbolDensity` of the visible characters;
/// - at most `maxCodeLineShare` of the lines look like code, config, a
///   log line or a CSV row (`looksLikeCode`).
///
/// Short bullet lists (a shopping list, "- eggs / - milk") do NOT count:
/// they have no sentences and next to no function words. A bulleted list
/// of whole sentences ("- Call Sam about the invoice before Friday.") does.
public enum ProseDetector {
    public static let sampleLimit = 8_192
    public static let minWords = 8
    public static let minWordShare = 0.75
    public static let minFunctionShare = 0.12
    public static let sentenceWords: ClosedRange<Double> = 3...60
    public static let maxSymbolDensity = 0.04
    public static let maxCodeLineShare = 0.25

    /// File extensions that open as Plain Text but are data or logs.
    public static let dataExtensions: Set<String> = ["log", "csv", "tsv", "psv", "tab", "out", "err", "conf", "cfg",
                                                     "lock", "sum", "pid", "properties", "env", "ini", "toml"]

    public struct Signals: Equatable, Sendable {
        public var words = 0
        public var tokens = 0
        public var functionWords = 0
        public var sentences = 0
        public var lines = 0
        public var codeLines = 0
        public var symbols = 0
        public var visible = 0

        public var wordShare: Double { tokens == 0 ? 0 : Double(words) / Double(tokens) }
        public var functionShare: Double { words == 0 ? 0 : Double(functionWords) / Double(words) }
        public var averageSentence: Double { sentences == 0 ? 0 : Double(words) / Double(sentences) }
        public var symbolDensity: Double { visible == 0 ? 0 : Double(symbols) / Double(visible) }
        public var codeLineShare: Double { lines == 0 ? 0 : Double(codeLines) / Double(lines) }

        public var readsAsProse: Bool {
            words >= ProseDetector.minWords && wordShare >= ProseDetector.minWordShare
                && functionShare >= ProseDetector.minFunctionShare
                && sentences > 0 && ProseDetector.sentenceWords.contains(averageSentence)
                && symbolDensity <= ProseDetector.maxSymbolDensity
                && codeLineShare <= ProseDetector.maxCodeLineShare
        }
    }

    /// Plain Text or Markdown, and not a data or log file by name.
    public static func languageAllows(_ language: Language, fileName: String?) -> Bool {
        guard language == .plain || language == .markdown else { return false }
        guard let name = fileName else { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return !dataExtensions.contains(ext)
    }

    /// The whole decision: language, file name, and the sample (at most
    /// `sampleLimit` units of `text`, from `start`).
    public static func isProse(_ text: NSString, language: Language, fileName: String? = nil, start: Int = 0) -> Bool {
        guard languageAllows(language, fileName: fileName) else { return false }
        let s = max(0, min(start, text.length))
        let sample = text.substring(with: NSRange(location: s, length: min(sampleLimit, text.length - s))) as NSString
        return signals(ProseMask.masked(sample, language: language)).readsAsProse
    }

    /// The measurements over already-masked text.
    public static func signals(_ masked: String) -> Signals {
        var g = Signals()
        for rawLine in masked.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            g.lines += 1
            if looksLikeCode(line) { g.codeLines += 1 }
            for u in line.unicodeScalars where !CharacterSet.whitespaces.contains(u) {
                g.visible += 1
                if symbolSet.contains(u) { g.symbols += 1 }
            }
            var previousWasWord = false
            for raw in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                let token = String(raw)
                let core = token.trimmingCharacters(in: edgePunctuation)
                if core.isEmpty { continue } // a dash, an ellipsis
                g.tokens += 1
                let isWord = isWordShaped(core)
                if isWord {
                    g.words += 1
                    if functionWords.contains(core.lowercased()) { g.functionWords += 1 }
                }
                // A sentence ends at . ! ? (also before a closing quote or
                // bracket) after a word: not "3.5", "e.g." counts once.
                if let last = token.trimmingCharacters(in: closers).unicodeScalars.last,
                   sentenceEnders.contains(last), isWord || previousWasWord {
                    g.sentences += 1
                }
                previousWasWord = isWord
            }
        }
        return g
    }

    // MARK: Pieces

    static let symbolSet = CharacterSet(charactersIn: "{}[]<>=;|\\/_*&^%$#@~`+")
    static let sentenceEnders = CharacterSet(charactersIn: ".!?…")
    static let closers = CharacterSet(charactersIn: "\"'”’)]»")
    static let edgePunctuation = CharacterSet(charactersIn: "\"'“”‘’()[]{}«».,;:!?…—–-*_")

    /// Letters only (an apostrophe or hyphen between letters is fine), not
    /// camelCase, at most 24 letters.
    static func isWordShaped(_ s: String) -> Bool {
        guard s.count <= 24 else { return false }
        var previousLower = false
        var previous: Character = " "
        for c in s {
            if c.isLetter {
                if c.isUppercase && previousLower { return false } // camelCase
                previousLower = c.isLowercase
            } else if c == "'" || c == "’" || c == "-" {
                guard previous.isLetter else { return false }
                previousLower = false
            } else {
                return false
            }
            previous = c
        }
        return previous.isLetter
    }

    /// A line that reads as code, config, a log entry or a table row.
    public static func looksLikeCode(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let first = t.first, let last = t.last else { return false }
        // Statement and block ends, arrows.
        if "{};".contains(last) || t.hasSuffix("=>") || t.hasSuffix("->") || t.hasSuffix("):") { return true }
        // Comments, shebangs, preprocessor, tags.
        for p in ["//", "/*", "#!", "#include", "#define", "<?", "</", "*/"] where t.hasPrefix(p) { return true }
        if first == "<", t.contains(">") { return true }
        // Keywords at the start of a line of code.
        let head = t.prefix { $0.isLetter || $0 == "_" }
        if ["def", "func", "function", "class", "import", "return", "var", "let", "const", "if", "for", "while",
            "elif", "else", "struct", "enum", "public", "private", "static", "void", "int", "fn", "package", "export"].contains(String(head)),
           t.count > head.count, t.contains("(") || t.contains("=") || t.contains(":") || t.contains("{") {
            // "If you can make it, let me know." is prose: needs code punctuation too.
            if !(last == "." || last == "?" || last == "!" || last == ",") { return true }
        }
        // A call or index with no space before the bracket: print(x), a[1].
        if t.range(of: #"[A-Za-z_]\w*[\(\[][^\s].*[\)\]]"#, options: .regularExpression) != nil,
           !(last == "." || last == "?" || last == "!") { return true }
        // Log lines: a timestamp, a date, or a level first.
        if t.range(of: #"^\[?\d{1,4}[-/:.]\d{1,2}"#, options: .regularExpression) != nil { return true }
        if t.range(of: #"^\[?(INFO|WARN|WARNING|ERROR|DEBUG|TRACE|FATAL|NOTICE|CRIT)\b"#, options: .regularExpression) != nil { return true }
        if t.range(of: #"\b(INFO|WARN|ERROR|DEBUG|TRACE|FATAL)\b[\]:]"#, options: .regularExpression) != nil { return true }
        // key = value, key: value (a key with no spaces and a one-token value or a code-ish key).
        if let m = t.range(of: #"^[A-Za-z_][\w.\-\[\]]*\s*="#, options: .regularExpression), !t[m].contains("==") { return true }
        if let colon = t.firstIndex(of: ":"), colon != t.startIndex {
            let key = t[..<colon], value = t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.contains(" "), key.count <= 40 {
                let codeKey = key.contains(where: { $0 == "_" || $0 == "." || $0 == "-" || $0.isNumber })
                let oneToken = !value.isEmpty && !value.contains(" ")
                let valueIsData = value.isEmpty || value.first.map { $0.isNumber || "\"'[{/~$".contains($0) } == true
                    || ["true", "false", "null", "yes", "no", "on", "off"].contains(value.lowercased())
                if codeKey || valueIsData || (oneToken && !(last == "." || last == "!" || last == "?")) { return true }
            }
        }
        // A table row: three or more fields split by commas, tabs, semicolons or pipes, mostly short.
        for sep: Character in [",", "\t", ";", "|"] {
            let fields = t.split(separator: sep, omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }
            let short = fields.filter { $0.split(separator: " ").count <= 3 }.count
            if sep != "," || (Double(short) / Double(fields.count) >= 0.8 && !(last == "." || last == "!" || last == "?")) { return true }
        }
        // Dense with symbols.
        let visible = t.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) }
        let symbols = visible.filter { symbolSet.contains($0) }.count
        if visible.count >= 6, Double(symbols) / Double(visible.count) > 0.12 { return true }
        return false
    }

    /// The most common short words of English, French, German, Spanish,
    /// Italian, Portuguese and Dutch: articles, pronouns, prepositions,
    /// conjunctions, auxiliaries.
    static let functionWords: Set<String> = [
        // English
        "a", "an", "the", "and", "or", "but", "if", "so", "of", "to", "in", "on", "at", "by", "for", "with", "from", "as",
        "into", "about", "over", "after", "before", "than", "then", "that", "this", "these", "those", "there", "here",
        "i", "you", "he", "she", "it", "we", "they", "me", "him", "her", "us", "them", "my", "your", "his", "its", "our",
        "their", "is", "are", "was", "were", "be", "been", "being", "am", "do", "does", "did", "have", "has", "had", "will",
        "would", "can", "could", "should", "shall", "may", "might", "must", "not", "no", "what", "which", "who", "when",
        "where", "why", "how", "all", "some", "any", "just", "very", "too", "also", "up", "out", "there's", "it's", "i'm",
        "don't", "didn't", "can't", "won't", "i'll", "we're", "you're", "they're", "let's", "let",
        // French
        "le", "la", "les", "un", "une", "des", "du", "de", "et", "est", "je", "tu", "il", "elle", "nous", "vous", "ils",
        "que", "qui", "pas", "pour", "dans", "sur", "avec", "ce", "ne", "au", "aux", "mais", "ou", "son", "sa", "ses",
        // German
        "der", "die", "das", "und", "ist", "ich", "du", "er", "sie", "es", "wir", "ihr", "nicht", "ein", "eine", "zu",
        "mit", "auf", "für", "von", "den", "dem", "im", "sich", "auch", "aber", "wie", "noch", "war", "hat", "haben",
        // Spanish, Italian, Portuguese
        "el", "los", "las", "y", "en", "es", "por", "con", "una", "lo", "se", "del", "al", "su", "pero", "como",
        "il", "di", "che", "non", "per", "sono", "gli", "della", "e", "o", "os", "um", "uma", "não", "com", "do", "da",
        // Dutch
        "het", "een", "en", "van", "ik", "je", "niet", "op", "te", "dat", "met", "zijn", "voor", "maar",
    ]
}

/// The prose of a document with everything that isn't prose blanked out
/// (replaced by spaces, newlines kept), so offsets stay the document's:
/// Markdown front matter, fenced code, tables, inline code, URLs, link
/// targets, HTML tags and markup characters (heading #, list markers,
/// emphasis). In Plain Text only URLs and email addresses are blanked.
/// The grammar checker sees this text, so it never reads code.
public enum ProseMask {
    public static func masked(_ text: NSString, language: Language) -> String {
        var units = [unichar](repeating: 0, count: text.length)
        text.getCharacters(&units, range: NSRange(location: 0, length: text.length))
        mask(&units, markdown: language == .markdown)
        return String(utf16CodeUnits: units, count: units.count)
    }

    /// The ranges of `text` that are prose (what `masked` keeps), merged.
    public static func proseRanges(_ text: NSString, language: Language) -> [NSRange] {
        var units = [unichar](repeating: 0, count: text.length)
        text.getCharacters(&units, range: NSRange(location: 0, length: text.length))
        let original = units
        mask(&units, markdown: language == .markdown)
        var out: [NSRange] = []
        var start: Int?
        for i in 0..<units.count {
            if units[i] == original[i] {
                if start == nil { start = i }
            } else if let s = start {
                out.append(NSRange(location: s, length: i - s)); start = nil
            }
        }
        if let s = start { out.append(NSRange(location: s, length: units.count - s)) }
        return out
    }

    static let space: unichar = 32, newline: unichar = 10

    static func blank(_ u: inout [unichar], _ from: Int, _ to: Int) {
        var i = max(0, from)
        while i < min(to, u.count) {
            if u[i] != newline { u[i] = space }
            i += 1
        }
    }

    static func mask(_ u: inout [unichar], markdown: Bool) {
        // Lines.
        var lines: [Range<Int>] = []
        var s = 0
        for i in 0..<u.count where u[i] == newline { lines.append(s..<i); s = i + 1 }
        if s <= u.count { lines.append(s..<u.count) }
        func str(_ r: Range<Int>) -> String { String(utf16CodeUnits: Array(u[r]), count: r.count) }

        if markdown {
            var li = 0
            // Front matter: "---" first line through the next "---" or "...".
            if let first = lines.first, str(first).trimmingCharacters(in: .whitespaces) == "---" {
                var j = 1
                while j < lines.count, j < 400 {
                    let t = str(lines[j]).trimmingCharacters(in: .whitespaces)
                    if t == "---" || t == "..." { break }
                    j += 1
                }
                if j < lines.count, j < 400 {
                    blank(&u, lines[0].lowerBound, lines[j].upperBound)
                    li = j + 1
                }
            }
            var fence: String?
            while li < lines.count {
                let r = lines[li]
                let line = str(r)
                let t = line.trimmingCharacters(in: .whitespaces)
                li += 1
                if let f = fence {
                    blank(&u, r.lowerBound, r.upperBound)
                    if t.hasPrefix(f) { fence = nil }
                    continue
                }
                if t.hasPrefix("```") || t.hasPrefix("~~~") {
                    fence = String(t.prefix(3))
                    blank(&u, r.lowerBound, r.upperBound)
                    continue
                }
                // Indented code (four spaces or a tab) after a blank line.
                if (line.hasPrefix("    ") || line.hasPrefix("\t")), li >= 2,
                   str(lines[li - 2]).trimmingCharacters(in: .whitespaces).isEmpty,
                   !t.hasPrefix("-"), !t.hasPrefix("*"), !t.hasPrefix("+"), t.first?.isNumber != true {
                    blank(&u, r.lowerBound, r.upperBound)
                    continue
                }
                // Tables.
                if t.hasPrefix("|") || t.filter({ $0 == "|" }).count >= 2 {
                    blank(&u, r.lowerBound, r.upperBound)
                    continue
                }
                // Markers at the start: headings, quotes, list bullets, numbers, checkboxes.
                var i = r.lowerBound
                while i < r.upperBound, u[i] == space || u[i] == 9 { i += 1 }
                let markerStart = i
                while i < r.upperBound, [35, 62].contains(u[i]) { i += 1 } // # >
                if i == markerStart, i + 1 < r.upperBound, [45, 42, 43].contains(u[i]), u[i + 1] == space { i += 2 } // - * +
                if i == markerStart {
                    var j = i
                    while j < r.upperBound, (48...57).contains(u[j]) { j += 1 }
                    if j > i, j + 1 < r.upperBound, u[j] == 46 || u[j] == 41, u[j + 1] == space { i = j + 2 } // 1. 1)
                }
                if i + 2 < r.upperBound, u[i] == 91, u[i + 2] == 93, [32, 120, 88].contains(u[i + 1]) { i += 3 } // [ ] [x]
                blank(&u, markerStart, i)
                inline(&u, r, markdown: true)
            }
        } else {
            for r in lines { inline(&u, r, markdown: false) }
        }
    }

    /// Inline code, URLs, emails, link targets, tags and emphasis markers in one line.
    static func inline(_ u: inout [unichar], _ r: Range<Int>, markdown: Bool) {
        var i = r.lowerBound
        while i < r.upperBound {
            let c = u[i]
            if markdown, c == 96 { // `code`
                var j = i + 1
                while j < r.upperBound, u[j] != 96 { j += 1 }
                if j < r.upperBound { blank(&u, i, j + 1); i = j + 1; continue }
            }
            if markdown, c == 93, i + 1 < r.upperBound, u[i + 1] == 40 { // ](target)
                var j = i + 2
                while j < r.upperBound, u[j] != 41 { j += 1 }
                blank(&u, i, min(j + 1, r.upperBound))
                // and the opening [
                var k = i - 1
                while k >= r.lowerBound, u[k] != 91 { k -= 1 }
                if k >= r.lowerBound { u[k] = space; if k > r.lowerBound, u[k - 1] == 33 { u[k - 1] = space } }
                i = j + 1
                continue
            }
            if markdown, c == 60 { // <tag> or <autolink>
                var j = i + 1
                while j < r.upperBound, u[j] != 62, u[j] != space || j - i < 2 { j += 1 }
                if j < r.upperBound, u[j] == 62, j > i + 1 { blank(&u, i, j + 1); i = j + 1; continue }
            }
            if markdown, c == 42 || c == 126 || (c == 95 && (i == r.lowerBound || u[i - 1] == space || (i + 1 < r.upperBound && u[i + 1] == space))) {
                u[i] = space; i += 1; continue // * ~ _ emphasis
            }
            // A whitespace-delimited chunk with :// or www. or @ (URL, email).
            if c != space, c != 9, i == r.lowerBound || u[i - 1] == space || u[i - 1] == 9 || u[i - 1] == 40 || u[i - 1] == 60 {
                var j = i
                while j < r.upperBound, u[j] != space, u[j] != 9 { j += 1 }
                let chunk = String(utf16CodeUnits: Array(u[i..<j]), count: j - i).lowercased()
                if !(markdown && chunk.hasPrefix("[")), chunk.contains("://") || chunk.hasPrefix("www.") || (chunk.contains("@") && chunk.contains(".")) {
                    blank(&u, i, j)
                    i = j
                    continue
                }
            }
            i += 1
        }
    }
}
