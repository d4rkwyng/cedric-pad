import Foundation

/// One language-specific rule of the owl (0.3.0): which files it runs for,
/// whether it needs the whole document, its tier, and a pure check that
/// returns at most one finding (several hits are aggregated into it).
///
/// The table `RulesHintProvider.languageRules` is in priority order (data
/// loss, then a run-time break, then a silent wrong result, then tidy): the
/// coordinator shows only the first eligible hint, so order is priority.
struct LintRule: Sendable {
    enum Tier: Sendable {
        /// Always on: it breaks, or silently does the wrong thing.
        case correctness
        /// Style: only with Settings › "Style tips in code".
        case style
    }
    let id: String
    let tier: Tier
    /// The language (raw value) and file name the rule runs for.
    let applies: @Sendable (_ language: String, _ fileName: String?) -> Bool
    /// Its claim is about the whole file: never on a window of a longer one.
    let wholeDocument: Bool
    let check: @Sendable (LintInput) -> LintFinding?

    init(_ id: String, tier: Tier = .correctness, wholeDocument: Bool = false,
         applies: @escaping @Sendable (String, String?) -> Bool, check: @escaping @Sendable (LintInput) -> LintFinding?) {
        self.id = id
        self.tier = tier
        self.wholeDocument = wholeDocument
        self.applies = applies
        self.check = check
    }

    static func languages(_ set: Set<String>) -> @Sendable (String, String?) -> Bool { { l, _ in set.contains(l) } }
}

/// What a rule sees. The mask is built on first use, once per query.
final class LintInput {
    let context: OwlContext
    let facts: OwlDocumentFacts
    let text: NSString
    let lines: [NSRange]
    private var builtMask: CodeMask??

    init(context: OwlContext, facts: OwlDocumentFacts, text: NSString, lines: [NSRange]) {
        self.context = context
        self.facts = facts
        self.text = text
        self.lines = lines
    }

    var string: String { context.text }
    var language: String { context.language }
    var fileName: String? { context.fileName }
    var whole: Bool { facts.isWholeDocument }

    /// Strings and comments of the window (nil for languages without a lexer).
    var mask: CodeMask? {
        if let m = builtMask { return m }
        let m = CodeMask.make(text, language: context.language, window: !facts.isWholeDocument && context.textStart > 0)
        builtMask = .some(m)
        return m
    }

    /// The mask's blanked code (or the text itself without a lexer).
    var code: String { mask?.code ?? context.text }
    var codeNS: NSString { mask?.codeNS ?? text }

    private var memo: [String: Any] = [:]
    /// Work shared by several rules of one query (the shell's commands,
    /// the YAML entries), done once.
    func shared<T>(_ key: String, _ make: () -> T) -> T {
        // (memo[key] first: `nil as? T` succeeds when T is itself optional.)
        if let stored = memo[key], let v = stored as? T { return v }
        let v = make()
        memo[key] = v
        return v
    }
    func isCode(_ offset: Int) -> Bool { mask?.isCode(offset) ?? true }

    /// "on line 12" or "near here" (see `RulesHintProvider.whereText`).
    func at(_ offset: Int) -> String { RulesHintProvider.whereText(text, offset, whole: whole) }
}

struct LintFinding {
    var kind: OwlHint.Kind
    var title: String
    var detail: String?
    var range: NSRange?
    var replacement: String?
}

extension RulesHintProvider {
    /// Python string prefix letters before the quote at `quote` ("r", "rb",
    /// "f"…, lower case), or "".
    static func pythonPrefix(_ s: NSString, _ quote: Int) -> String {
        var j = quote
        while j > 0, quote - j < 2, let u = UnicodeScalar(s.character(at: j - 1)), "rRbBfFuU".unicodeScalars.contains(u) { j -= 1 }
        guard j < quote else { return "" }
        if j > 0, let u = UnicodeScalar(s.character(at: j - 1)), CharacterSet.alphanumerics.contains(u) || u == "_" { return "" }
        return s.substring(with: NSRange(location: j, length: quote - j)).lowercased()
    }

    /// The rules for 0.3.0's language packs, most serious first.
    static let languageRules: [LintRule] = [
        // Data loss.
        ShellRules.cdUnchecked,
        ShellRules.unquotedVariable,
        // It won't run, or won't load.
        ShellRules.crlf,
        ConfigRules.xmlInvalid,
        ShellRules.testBrackets,
        ShellRules.assignmentSpaces,
        ShellRules.pastedPunctuation,
        PythonRules.printStatement,
        ConfigRules.tomlBareString,
        ConfigRules.tomlDuplicate,
        ConfigRules.envSpaces,
        MarkdownRules.unclosedFence,
        DataRules.unclosedQuote,
        // It silently does the wrong thing.
        ConfigRules.yamlDuplicateKey,
        ConfigRules.jsonDuplicateKey,
        ConfigRules.envDuplicateKey,
        ConfigRules.yamlVersionFloat,
        JSRules.nanCompare,
        JSRules.typeofTypo,
        PythonRules.mutableDefault,
        PythonRules.isLiteral,
        PythonRules.invalidEscape,
        PythonRules.noneCompare,
        DataRules.raggedRows,
        MarkdownRules.brokenRelativeLink,
        MarkdownRules.brokenAnchor,
        // Left behind, or missing.
        JSRules.debuggerLeftIn,
        ShellRules.missingShebang,
    ]

    /// The language rules that apply to this file, in order, as hints.
    /// Style rules only with `facts.styleTips`; whole-document rules only
    /// on the whole document. Only the rules for the file's language ever
    /// run, so a file pays for 3 to 8 of them.
    func languageHints(_ c: OwlContext, facts: OwlDocumentFacts, text: NSString, lines: [NSRange],
                       rules: [LintRule] = RulesHintProvider.languageRules,
                       hint: (String, OwlHint.Kind, String, String?, NSRange?, String?) -> Void) {
        let lang = c.language, name = c.fileName
        // Minified or generated code (a line of thousands of characters): a
        // window may start anywhere in it, so the lexer can't be trusted.
        if ["javascript", "typescript", "python", "shell"].contains(lang), lines.contains(where: { $0.length > 2000 }) { return }
        if lang == "shell", ShellRules.looksGenerated(c.text) { return }
        var input: LintInput?
        for rule in rules where rule.applies(lang, name) {
            if rule.tier == .style, !facts.styleTips { continue }
            if rule.wholeDocument, !facts.isWholeDocument { continue }
            let i = input ?? LintInput(context: c, facts: facts, text: text, lines: lines)
            input = i
            // A window of Python that may sit wholly inside a long docstring.
            if lang == "python", i.proseInCode { return }
            if let f = rule.check(i) { hint(rule.id, f.kind, f.title, f.detail, f.range, f.replacement) }
        }
    }

    // MARK: Shared helpers

    /// TOML and .env files open as INI: told apart by name.
    @Sendable static func isTOMLFile(_ language: String, _ name: String?) -> Bool {
        guard language == "ini" else { return false }
        let n = name ?? ""
        return ext(n) == "toml" || ["Pipfile", "Cargo.lock", "poetry.lock", "uv.lock"].contains(n)
    }

    @Sendable static func isEnvFile(_ language: String, _ name: String?) -> Bool {
        guard language == "ini", let n = name else { return false }
        return n == ".env" || n.hasPrefix(".env.") || ext(n) == "env"
    }

    /// The file's extension, lower case ("" if none).
    static func ext(_ name: String?) -> String { ((name ?? "") as NSString).pathExtension.lowercased() }

    /// Each match of `re` in `s` (in `range`, default all).
    static func matches(_ re: NSRegularExpression, _ s: String, in range: NSRange? = nil) -> [NSTextCheckingResult] {
        re.matches(in: s, range: range ?? NSRange(location: 0, length: (s as NSString).length))
    }

    /// Applies `edits` (sorted, not overlapping, relative to the text) as
    /// one replacement of the span from the first to the last.
    static func spanEdit(_ s: NSString, _ edits: [(NSRange, String)]) -> (range: NSRange, replacement: String)? {
        let sorted = edits.sorted { $0.0.location < $1.0.location }
        guard let first = sorted.first, let last = sorted.last else { return nil }
        let span = NSRange(location: first.0.location, length: NSMaxRange(last.0) - first.0.location)
        var out = "", at = span.location
        for (r, rep) in sorted {
            guard r.location >= at else { return nil }   // overlapping
            out += s.substring(with: NSRange(location: at, length: r.location - at)) + rep
            at = NSMaxRange(r)
        }
        return (span, out)
    }

    /// The line range (without its newline) containing `offset`.
    static func lineRange(_ lines: [NSRange], containing offset: Int) -> NSRange? {
        var lo = 0, hi = lines.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = lines[mid]
            if offset < r.location { hi = mid - 1 } else if offset > NSMaxRange(r) { lo = mid + 1 } else { return r }
        }
        return nil
    }

    /// "3 places" style counts in details: "" for one, " (and 2 more)" otherwise.
    static func andMore(_ count: Int) -> String {
        count <= 1 ? "" : String(localized: " (and \(count - 1) more)")
    }
}
