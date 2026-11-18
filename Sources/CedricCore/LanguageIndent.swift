import Foundation

/// Indentation that depends on the language: YAML always indents with
/// spaces (the YAML spec forbids tabs), Python with 4 spaces unless the
/// file or the user says otherwise, and Python's block keywords: Return
/// after `return`/`pass`/`break`/`continue`/`raise` steps back out, and
/// typing the ":" of `else`, `elif`, `except` or `finally` lines the
/// clause up with its `if`/`try`/`for`/`while`.
public enum LanguageIndent {
    /// The tab's indentation and whether the Tab key types spaces, from
    /// this tab's own pick (`manual`), what the file uses (`detected`), and
    /// the default in Settings (`defaultSaved`: the user saved one).
    public static func resolve(language: Language, manual: Indentation?, detected: Indentation?,
                               default def: Indentation, defaultSaved: Bool) -> (indentation: Indentation, tabTypesSpaces: Bool) {
        if language == .yaml {
            if let manual, !manual.usesTabs { return (manual, true) }
            if let detected, !detected.usesTabs { return (detected, true) }
            return (Indentation(usesTabs: false, width: 2), true)
        }
        if let manual { return (manual, !manual.usesTabs) }
        if let found = detected {
            // A tab's width isn't in the file: the default's.
            return found.usesTabs ? (Indentation(usesTabs: true, width: def.width), false) : (found, true)
        }
        if language == .python, !(defaultSaved && def.usesTabs) {
            return (Indentation(usesTabs: false, width: defaultSaved ? def.width : 4), true)
        }
        // Nothing to go by: Ruby indents by 2 by convention.
        if !def.usesTabs, def.width == 4, language == .ruby {
            return (Indentation(usesTabs: false, width: 2), defaultSaved)
        }
        return (def, !def.usesTabs && defaultSaved)
    }

    static let dedenters: Set<String> = ["return", "pass", "break", "continue", "raise"]

    /// Whether a Python line (its text before the caret) ends a block:
    /// it starts with `return`, `pass`, `break`, `continue` or `raise`.
    public static func pythonEndsBlock(_ head: String) -> Bool {
        let t = head.drop { $0 == " " || $0 == "\t" }
        let word = t.prefix { $0.isLetter }
        guard dedenters.contains(String(word)) else { return false }
        let after = t.dropFirst(word.count).first
        return after == nil || after == " " || after == "(" || after == ";"
    }

    /// `indent` one step out: a tab, or up to `width` spaces.
    public static func dedent(_ indent: String, width: Int) -> String {
        if indent.hasSuffix("\t") { return String(indent.dropLast()) }
        var s = indent
        var n = 0
        while n < width, s.hasSuffix(" ") { s.removeLast(); n += 1 }
        return s
    }

    static let clauseOpeners: [String: Set<String>] = [
        "else": ["if", "elif", "for", "while", "try", "except"],
        "elif": ["if", "elif"],
        "except": ["try", "except"],
        "finally": ["try", "except", "else"],
    ]

    static func keyword<S: StringProtocol>(_ s: S) -> String {
        String(s.drop { $0 == " " || $0 == "\t" }.prefix { $0.isLetter })
    }

    static func columns<S: StringProtocol>(_ s: S, tabWidth: Int) -> Int { MarkdownLists.columns(s, tabWidth: tabWidth) }

    /// Python, typing ":" after `else`, `elif …`, `except …` or `finally`
    /// (`head` is the line before the caret, without the ":"): the indent
    /// of the `if`/`try`/… it belongs to, when the line is indented more
    /// than that; nil when it's already lined up or nothing matches.
    /// `above` gives the lines above the caret's line, nearest first (the
    /// caller stops after a few hundred).
    public static func pythonClauseIndent(head: String, above: [String], tabWidth: Int) -> String? {
        let word = keyword(head)
        guard let openers = clauseOpeners[word] else { return nil }
        let rest = head.drop { $0 == " " || $0 == "\t" }.dropFirst(word.count)
        // "else" and "finally" are the whole line; "elif x" / "except E" go on.
        if word == "else" || word == "finally" { guard rest.allSatisfy({ $0 == " " }) else { return nil } }
        else if let f = rest.first, f.isLetter || f.isNumber || f == "_" { return nil }
        let col = columns(head, tabWidth: tabWidth)
        var limit = col
        for line in above {
            let t = line.drop { $0 == " " || $0 == "\t" }
            if t.isEmpty || t.hasPrefix("#") { continue }
            let c = columns(line, tabWidth: tabWidth)
            guard c <= limit else { continue }
            if openers.contains(keyword(line)), t.hasSuffix(":") || t.contains(":") {
                let indent = String(line.prefix { $0 == " " || $0 == "\t" })
                return c == col ? nil : indent
            }
            // A statement at this column closes any block opened deeper.
            limit = c - 1
            if limit < 0 { return nil }
        }
        return nil
    }
}
