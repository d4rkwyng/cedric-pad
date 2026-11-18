import Foundation

extension Language {
    /// The language a fenced code block's info string names (```` ```swift ````,
    /// ```` ```py title="x" ````, ```` ```{.js} ````), or nil.
    public init?<S: StringProtocol>(fenceInfo info: S) {
        let word = String(info).split(whereSeparator: { (c: Character) in c == " " || c == "\t" || c == "," }).first.map(String.init) ?? ""
        let name = word.trimmingCharacters(in: CharacterSet(charactersIn: "{}.")).lowercased()
        guard !name.isEmpty else { return nil }
        if let l = Self.fenceNames[name] ?? LanguageDetector.byExtension[name] ?? Language(rawValue: name) {
            self = l
        } else {
            return nil
        }
    }

    private static let fenceNames: [String: Language] = [
        "python3": .python, "py3": .python, "node": .javascript, "ecmascript": .javascript,
        "shell": .shell, "console": .shell, "shellsession": .shell, "sh-session": .shell, "fish": .shell,
        "c++": .c, "objc": .c, "objective-c": .c, "objectivec": .c, "objc++": .c, "cuda": .c,
        "postgres": .sql, "postgresql": .sql, "sqlite": .sql, "plsql": .sql,
        "dotenv": .ini, "scss": .css, "less": .css, "xhtml": .html, "vue": .html,
        "md": .markdown, "text": .plain, "txt": .plain, "plaintext": .plain,
    ]

    /// Whether a fenced block in this language gets its own colours (a
    /// Markdown block inside Markdown, plain text and CSV stay flat).
    public var colorsFencedCode: Bool { self != .plain && self != .markdown && self != .csv }
}

/// Code coloured as HTML spans by Cedric's own tokenizers (no JavaScript
/// highlighter in the page): `<span class="tk-keyword">…</span>`, so the
/// page's stylesheet gives each kind the theme's colour.
public enum CodeHTML {
    /// Longer code is shown escaped but uncoloured.
    public static let maxLength = 200_000

    public static func highlight(_ code: String, language: Language) -> String {
        guard language.colorsFencedCode, code.utf16.count <= maxLength else { return Markdown.escape(code) }
        let tokenizer = Languages.tokenizer(for: language)
        var state = tokenizer.initialState
        var out = ""
        out.reserveCapacity(code.utf8.count + code.utf8.count / 4)
        var first = true
        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            if !first { out += "\n" }
            first = false
            let units = Array(line.utf16)
            var tokens: [Token] = []
            units.withUnsafeBufferPointer { tokenizer.tokenize($0, state: &state, into: &tokens) }
            var at = 0
            func text(_ a: Int, _ b: Int) -> String { Markdown.escape(String(decoding: units[a..<b], as: UTF16.self)) }
            for t in tokens where t.start >= at && t.end <= units.count {
                if t.start > at { out += text(at, t.start) }
                out += "<span class=\"tk-\(t.kind)\">\(text(t.start, t.end))</span>"
                at = t.end
            }
            if at < units.count { out += text(at, units.count) }
        }
        return out
    }
}
