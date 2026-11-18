import Foundation

/// The languages Cedric colours. `.plain` is everything else.
public enum Language: String, CaseIterable, Codable, Sendable {
    case plain, swift, python, javascript, typescript, json, yaml, markdown, html, css, shell, c, ruby, xml, sql, diff, ini, csv
    case powershell, batch, registry

    public var displayName: String {
        switch self {
        case .plain: return String(localized: "Plain Text")
        case .swift: return "Swift"
        case .python: return "Python"
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .json: return "JSON"
        case .yaml: return "YAML"
        case .markdown: return "Markdown"
        case .html: return "HTML"
        case .css: return "CSS"
        case .shell: return String(localized: "Shell Script")
        case .c: return "C"
        case .ruby: return "Ruby"
        case .xml: return "XML"
        case .sql: return "SQL"
        case .diff: return String(localized: "Diff / Patch")
        case .ini: return String(localized: "INI / TOML / .env")
        case .csv: return "CSV / TSV"
        case .powershell: return "PowerShell"
        case .batch: return String(localized: "Batch (.bat / .cmd)")
        case .registry: return String(localized: "Registry (.reg)")
        }
    }

    /// Whether View › Show Outline lists something: Markdown's headings,
    /// PowerShell's functions.
    public var hasOutline: Bool { self == .markdown || self == .powershell }

    /// Whether the side-by-side preview applies.
    public var hasPreview: Bool { self == .markdown || self == .html || self == .csv }
}

/// Picks a language from a file name, a shebang line, or the content.
public enum LanguageDetector {
    static let byExtension: [String: Language] = [
        "swift": .swift,
        "py": .python, "pyw": .python, "pyi": .python,
        "js": .javascript, "mjs": .javascript, "cjs": .javascript, "jsx": .javascript,
        "ts": .typescript, "tsx": .typescript, "mts": .typescript, "cts": .typescript,
        "json": .json, "jsonc": .json, "geojson": .json, "webmanifest": .json,
        "yaml": .yaml, "yml": .yaml,
        "md": .markdown, "markdown": .markdown, "mdown": .markdown, "mkd": .markdown,
        "html": .html, "htm": .html, "xhtml": .html, "svg": .html,
        "xml": .xml, "ps1xml": .xml, "plist": .xml, "xsd": .xml, "xsl": .xml, "xslt": .xml, "rss": .xml, "atom": .xml, "xib": .xml, "storyboard": .xml,
        "csproj": .xml, "resx": .xml, "pom": .xml, "kml": .xml, "gpx": .xml,
        "sql": .sql, "ddl": .sql, "psql": .sql, "mysql": .sql,
        "diff": .diff, "patch": .diff, "rej": .diff,
        "ini": .ini, "cfg": .ini, "conf": .ini, "toml": .ini, "properties": .ini, "env": .ini, "desktop": .ini,
        "gitconfig": .ini, "editorconfig": .ini, "service": .ini,
        "css": .css,
        "csv": .csv, "tsv": .csv, "tab": .csv, "psv": .csv,
        "sh": .shell, "bash": .shell, "zsh": .shell, "ksh": .shell, "command": .shell,
        "c": .c, "h": .c, "m": .c, "cc": .c, "cpp": .c, "cxx": .c, "hpp": .c, "hh": .c, "mm": .c,
        "rb": .ruby, "rake": .ruby, "gemspec": .ruby,
        "ps1": .powershell, "psm1": .powershell, "psd1": .powershell,
        "bat": .batch, "cmd": .batch,
        "reg": .registry,
    ]
    static let byName: [String: Language] = [
        "Gemfile": .ruby, "Rakefile": .ruby, "Podfile": .ruby, "Brewfile": .ruby,
        ".bashrc": .shell, ".zshrc": .shell, ".profile": .shell, ".bash_profile": .shell, ".zprofile": .shell, ".zshenv": .shell,
        "Package.resolved": .json, ".babelrc": .json, ".eslintrc": .json,
        ".env": .ini, ".gitconfig": .ini, ".editorconfig": .ini, ".npmrc": .ini, ".gitmodules": .ini, "Pipfile": .ini,
        "Cargo.lock": .ini, "poetry.lock": .ini,
    ]

    /// By file name (extension or a well-known name), else nil.
    public static func language(forFileName name: String) -> Language? {
        if let l = byName[name] { return l }
        if name.hasPrefix(".env.") { return .ini } // .env.local, .env.production
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        return byExtension[name[name.index(after: dot)...].lowercased()]
    }

    /// By a `#!` line: `#!/usr/bin/env python3`, `#!/bin/zsh`, …
    public static func language(forShebang firstLine: Substring) -> Language? {
        guard firstLine.hasPrefix("#!") else { return nil }
        let words = firstLine.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard var prog = words.first.map({ String($0.split(separator: "/").last ?? $0) }) else { return nil }
        if prog == "env", words.count > 1 {
            prog = words.dropFirst().first { !$0.hasPrefix("-") }.map(String.init) ?? prog
        }
        if prog.hasPrefix("python") { return .python }
        if ["sh", "bash", "zsh", "ksh", "dash", "fish"].contains(prog) { return .shell }
        if prog.hasPrefix("node") || prog == "deno" || prog == "bun" { return .javascript }
        if prog.hasPrefix("ruby") { return .ruby }
        if prog == "swift" { return .swift }
        if prog == "pwsh" || prog.hasPrefix("pwsh-") || prog == "powershell" { return .powershell }
        return nil
    }

    /// The best guess for a file: its name, then its shebang, then its content.
    public static func detect(fileName: String?, content: String) -> Language {
        if let fileName, let l = language(forFileName: fileName) { return l }
        return sniff(content)
    }

    /// Guesses from content alone (pasted text in an untitled tab). Looks
    /// at the first few KB only, so it is cheap on any size.
    public static func sniff(_ content: String) -> Language {
        let head = String(content.utf16.prefix(4096)) ?? String(content.prefix(4096))
        let trimmed = head.drop { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }
        let firstLine = trimmed.prefix { $0 != "\n" }
        if let l = language(forShebang: firstLine) { return l }
        guard !trimmed.isEmpty else { return .plain }

        let lower = trimmed.prefix(200).lowercased()
        if lower.hasPrefix("<!doctype html") || lower.hasPrefix("<html") { return .html }
        if lower.hasPrefix("windows registry editor version") || lower.hasPrefix("regedit4") { return .registry }
        if lower.hasPrefix("@echo off") { return .batch }
        if lower.hasPrefix("<?xml") { return lower.contains("<html") || lower.contains("<!doctype html") ? .html : .xml }
        // A unified diff: "diff --git …", or "--- a" followed by "+++ b".
        if trimmed.hasPrefix("diff --git ") || trimmed.hasPrefix("diff -") || trimmed.hasPrefix("Index: ")
            || (trimmed.hasPrefix("--- ") && trimmed.split(separator: "\n", maxSplits: 2).dropFirst().first?.hasPrefix("+++ ") == true) {
            return .diff
        }
        if let f = trimmed.first, f == "{" || f == "[" {
            // JSON if it parses, or (for a truncated sniff) if it looks like keys.
            if let data = trimmed.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil {
                return .json
            }
            if f == "{", trimmed.dropFirst().drop(while: { $0 == " " || $0 == "\n" || $0 == "\t" }).first == "\"" { return .json }
        }
        let lines = head.split(separator: "\n", maxSplits: 80, omittingEmptySubsequences: true)
        var score: [Language: Int] = [:]
        var md = MarkdownSignals()
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // PowerShell first: its `$variables` would otherwise count as shell.
            let ps = PowerShellSignals.score(line)
            if ps > 0 { score[.powershell, default: 0] += ps; continue }
            if line.hasPrefix("#include") || line.hasPrefix("#define") || line.hasPrefix("#pragma") { score[.c, default: 0] += 3 }
            if line.hasPrefix("import Foundation") || line.hasPrefix("import SwiftUI") || line.hasPrefix("import AppKit") || line.hasPrefix("import UIKit") { score[.swift, default: 0] += 5 }
            if line.hasPrefix("func ") || line.hasPrefix("guard ") || (line.hasPrefix("let ") && line.contains(":") == false && line.contains(" = ")) { score[.swift, default: 0] += 1 }
            if line.hasPrefix("def ") && line.hasSuffix(":") { score[.python, default: 0] += 3 }
            if line.hasPrefix("def ") && !line.hasSuffix(":") { score[.ruby, default: 0] += 2 }
            if line == "end" { score[.ruby, default: 0] += 1 }
            if line.hasPrefix("from ") && line.contains(" import ") { score[.python, default: 0] += 3 }
            if line.hasPrefix("import ") && !line.contains(" from ") && !line.hasSuffix(";") && !line.contains("{") { score[.python, default: 0] += 1 }
            if line.hasPrefix("const ") || line.hasPrefix("function ") || line.contains("=> {") || line.hasPrefix("export ") { score[.javascript, default: 0] += 2 }
            if line.hasPrefix("interface ") || line.contains(": string") || line.contains(": number") { score[.typescript, default: 0] += 3 }
            md.note(line, indented: raw.first == " " || raw.first == "\t")
            if line.hasPrefix("<div") || line.hasPrefix("<p>") || line.hasPrefix("<body") || line.hasPrefix("<head") { score[.html, default: 0] += 3 }
            if line.hasSuffix("{"), line.contains(":") == false, (line.hasPrefix(".") || line.hasPrefix("#") || line.hasPrefix("body")) { score[.css, default: 0] += 2 }
            if line.range(of: #"^[a-z-]+\s*:\s*[^;]+;$"#, options: .regularExpression) != nil { score[.css, default: 0] += 1 }
            if line.range(of: #"^[A-Za-z_][A-Za-z0-9_-]*:(\s|$)"#, options: .regularExpression) != nil { score[.yaml, default: 0] += 1 }
            if line == "---" { score[.yaml, default: 0] += 1 }
            if line.hasPrefix("echo ") || line.hasPrefix("export ") || line == "fi" || line.contains("$(") { score[.shell, default: 0] += 1 }
            if line.hasPrefix("set -") || line.hasPrefix("if [") || line.hasSuffix("; then") || line.hasSuffix("; do") || line == "done"
                || line.range(of: #"\$\{?[A-Za-z_]"#, options: .regularExpression) != nil { score[.shell, default: 0] += 1 }
        }
        if md.score > 0 { score[.markdown] = md.score }
        guard let best = score.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key.rawValue > $1.key.rawValue) }), best.value >= 2 else {
            return .plain
        }
        // "Date: …", "Status: …" lines in meeting notes score as YAML;
        // when the rest reads as sentences it is prose, not data.
        if best.key == .yaml, ProseDetector.signals(ProseMask.masked(head as NSString, language: .plain)).readsAsProse {
            return .plain
        }
        return best.key
    }
}

/// PowerShell evidence in one line of typed or pasted text: `param(`,
/// `function Verb-Noun`, `[CmdletBinding()]`, `$PSVersionTable`,
/// `Write-Host`, any approved-verb cmdlet, `$x = …` assignments and
/// `-eq`-style operators. 0 for a line with none.
enum PowerShellSignals {
    static let strong = try! NSRegularExpression(pattern:
        #"(?i)^(param\s*\(|function\s+[a-z]+-[a-z]+|\[cmdletbinding\(|\[parameter\(|#requires\s+-)|\$PSVersionTable|\$PSScriptRoot|\$PSCmdlet"#)
    static let cmdlet = try! NSRegularExpression(pattern:
        #"(?i)\b(Write-(Host|Output|Verbose|Error|Warning)|Get-(ChildItem|Content|Item|Process|Service|Date)|Set-(Content|Item|Location)|New-(Object|Item)|Import-Module|Out-(File|Null)|Select-Object|Where-Object|ForEach-Object|Invoke-(WebRequest|RestMethod|Command)|Test-Path|Remove-Item|Start-Process)\b"#)
    static let assignment = try! NSRegularExpression(pattern: #"^\$[A-Za-z_][\w:]*(\.\w+)*\s*[+-]?=\s"#)
    static let comparison = try! NSRegularExpression(pattern: #"(?i)\s-(eq|ne|gt|lt|ge|le|like|match|notmatch|contains)\s"#)

    static func score(_ line: String) -> Int {
        let r = NSRange(location: 0, length: (line as NSString).length)
        if strong.firstMatch(in: line, range: r) != nil { return 3 }
        var s = 0
        if cmdlet.firstMatch(in: line, range: r) != nil { s += 2 }
        if assignment.firstMatch(in: line, range: r) != nil { s += 1 }
        if comparison.firstMatch(in: line, range: r) != nil { s += 1 }
        return s
    }
}

/// Markdown evidence in typed or pasted text. One kind of signal alone
/// (a `# comment`, a `- item`) is not enough: a shell script or a YAML
/// list has those too. Two kinds (a heading and bold, a list and a link)
/// are, and so is a fenced code block.
struct MarkdownSignals {
    private(set) var kinds: Set<String> = []
    private var points: [String: Int] = [:]

    /// `indented`: list items nested under a key are YAML's, not Markdown's.
    mutating func note(_ line: String, indented: Bool) {
        // Each kind adds at most 4, so a long list or many comments can't
        // outvote the other languages on their own.
        func hit(_ kind: String, _ p: Int) { kinds.insert(kind); points[kind] = min(4, points[kind, default: 0] + p) }
        if line.range(of: #"^#{2,6} \S"#, options: .regularExpression) != nil { hit("h2", 2) }
        else if line.range(of: #"^# \S"#, options: .regularExpression) != nil { hit("h1", 1) }
        if line.hasPrefix("```") || line.hasPrefix("~~~") { hit("fence", 2) }
        if line.range(of: #"\*\*[^*\s][^*]*\*\*|__[^_\s][^_]*__"#, options: .regularExpression) != nil { hit("bold", 2) }
        if line.range(of: #"\[[^\]]+\]\([^)\s]+\)"#, options: .regularExpression) != nil { hit("link", 2) }
        if !indented, line.range(of: #"^([-*+]|\d{1,3}\.) \S"#, options: .regularExpression) != nil { hit("list", 1) }
        if line.hasPrefix("> ") { hit("quote", 1) }
    }

    /// 0 unless there are two kinds of signal (or a fence).
    var score: Int {
        let total = points.values.reduce(0, +)
        if kinds.contains("fence") && total >= 4 { return total }
        return kinds.count >= 2 ? total : 0
    }
}

/// The tokenizer for each language.
public enum Languages {
    public static func tokenizer(for language: Language) -> Tokenizer {
        switch language {
        case .plain, .csv: return PlainTokenizer()
        case .json: return JSONTokenizer()
        case .yaml: return YAMLTokenizer()
        case .markdown: return MarkdownTokenizer()
        case .html: return HTMLTokenizer()
        case .css: return CSSTokenizer()
        case .swift: return swift
        case .python: return python
        case .javascript: return javascript
        case .typescript: return typescript
        case .shell: return shell
        case .c: return c
        case .ruby: return ruby
        case .xml: return HTMLTokenizer(xml: true)
        case .sql: return sql
        case .diff: return DiffTokenizer()
        case .ini: return INITokenizer()
        case .powershell: return PowerShellTokenizer()
        case .batch: return BatchTokenizer()
        case .registry: return RegistryTokenizer()
        }
    }

    static let sql: CodeTokenizer = {
        var s = CodeSpec()
        s.lineComments = [Array("--".utf16)]
        s.blockComment = (Array("/*".utf16), Array("*/".utf16))
        s.strings = [StringRule("'", multiline: true), StringRule("\"")]
        s.keywords = WordSet(["select", "from", "where", "and", "or", "not", "in", "is", "like", "ilike", "between", "exists",
            "insert", "into", "values", "update", "set", "delete", "create", "alter", "drop", "table", "view", "index",
            "unique", "primary", "foreign", "key", "references", "constraint", "default", "check", "join", "inner", "left",
            "right", "full", "outer", "cross", "on", "using", "as", "group", "by", "order", "having", "limit", "offset",
            "union", "all", "distinct", "case", "when", "then", "else", "end", "begin", "commit", "rollback", "transaction",
            "with", "recursive", "returning", "if", "asc", "desc", "database", "schema", "grant", "revoke", "trigger",
            "function", "procedure", "return", "returns", "declare", "replace", "temporary", "temp", "cascade", "pragma",
            "explain", "analyze", "vacuum", "upsert", "conflict", "do", "nothing", "over", "partition", "window", "fetch",
            "next", "rows", "only", "top", "auto_increment", "autoincrement", "add", "column", "rename", "to", "truncate"],
            caseInsensitive: true)
        s.types = WordSet(["int", "integer", "smallint", "bigint", "tinyint", "serial", "bigserial", "real", "float", "double",
            "precision", "decimal", "numeric", "char", "varchar", "nvarchar", "text", "blob", "bytea", "boolean", "bool",
            "date", "time", "timestamp", "timestamptz", "interval", "json", "jsonb", "uuid", "money", "datetime"],
            caseInsensitive: true)
        s.constants = WordSet(["null", "true", "false", "current_date", "current_time", "current_timestamp"], caseInsensitive: true)
        s.atVariables = true
        return CodeTokenizer(s)
    }()

    static let swift: CodeTokenizer = {
        var s = CodeSpec()
        s.lineComments = [Array("//".utf16)]
        s.blockComment = (Array("/*".utf16), Array("*/".utf16))
        s.nestedBlockComments = true
        s.strings = [StringRule("\"\"\"", multiline: true), StringRule("\"")]
        s.keywords = WordSet(["associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init",
            "inout", "internal", "let", "open", "operator", "private", "precedencegroup", "protocol", "public", "rethrows",
            "static", "struct", "subscript", "typealias", "var", "break", "case", "catch", "continue", "default", "defer",
            "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "throw", "switch", "where", "while",
            "as", "is", "super", "self", "Self", "throws", "try", "await", "async", "some", "any", "mutating", "nonmutating",
            "override", "final", "lazy", "weak", "unowned", "convenience", "required", "dynamic", "optional", "indirect",
            "nonisolated", "isolated", "actor", "consuming", "borrowing", "sending", "package", "get", "set", "willSet", "didSet"])
        s.constants = WordSet(["true", "false", "nil"])
        s.capitalizedAreTypes = true
        s.atAttributes = true
        s.hashKeywords = true
        return CodeTokenizer(s)
    }()

    static let python: CodeTokenizer = {
        var s = CodeSpec()
        s.lineComments = [Array("#".utf16)]
        s.strings = [StringRule("\"\"\"", multiline: true), StringRule("'''", multiline: true), StringRule("\""), StringRule("'")]
        s.keywords = WordSet(["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif",
            "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not",
            "or", "pass", "raise", "return", "try", "while", "with", "yield", "match", "case", "self", "cls"])
        s.constants = WordSet(["True", "False", "None"])
        s.types = WordSet(["int", "float", "str", "bytes", "bool", "list", "dict", "set", "tuple", "object", "type"])
        s.capitalizedAreTypes = true
        s.atAttributes = true
        return CodeTokenizer(s)
    }()

    static let jsKeywords = ["break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do",
        "else", "export", "extends", "finally", "for", "function", "if", "import", "in", "instanceof", "let", "new",
        "return", "super", "switch", "this", "throw", "try", "typeof", "var", "void", "while", "with", "yield", "async",
        "await", "of", "static", "get", "set", "from", "as"]

    static func jsSpec() -> CodeSpec {
        var s = CodeSpec()
        s.lineComments = [Array("//".utf16)]
        s.blockComment = (Array("/*".utf16), Array("*/".utf16))
        s.strings = [StringRule("`", multiline: true), StringRule("\""), StringRule("'")]
        s.keywords = WordSet(jsKeywords)
        s.constants = WordSet(["true", "false", "null", "undefined", "NaN", "Infinity"])
        s.dollarInIdentifiers = true
        s.atAttributes = true
        return s
    }

    static let javascript = CodeTokenizer(jsSpec())

    static let typescript: CodeTokenizer = {
        var s = jsSpec()
        s.keywords = WordSet(jsKeywords + ["interface", "type", "enum", "implements", "namespace", "declare", "readonly",
            "private", "public", "protected", "abstract", "keyof", "infer", "is", "satisfies", "module"])
        s.types = WordSet(["string", "number", "boolean", "any", "unknown", "never", "void", "object", "bigint", "symbol"])
        s.capitalizedAreTypes = true
        return CodeTokenizer(s)
    }()

    static let shell: CodeTokenizer = {
        var s = CodeSpec()
        s.lineComments = [Array("#".utf16)]
        s.lineCommentNeedsWordBoundary = true
        s.strings = [StringRule("\"", multiline: true), StringRule("'", multiline: true, escapes: false)]
        s.keywords = WordSet(["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac",
            "in", "function", "return", "local", "export", "readonly", "declare", "typeset", "set", "unset", "shift",
            "source", "exit", "break", "continue", "select", "time", "trap", "eval", "exec"])
        s.types = WordSet(["echo", "printf", "cd", "test", "read", "pwd", "alias", "builtin", "command", "type", "wait"])
        s.dollarVariables = true
        return CodeTokenizer(s)
    }()

    static let c: CodeTokenizer = {
        var s = CodeSpec()
        s.lineComments = [Array("//".utf16)]
        s.blockComment = (Array("/*".utf16), Array("*/".utf16))
        s.strings = [StringRule("\""), StringRule("'")]
        s.keywords = WordSet(["auto", "break", "case", "const", "continue", "default", "do", "else", "enum", "extern",
            "for", "goto", "if", "inline", "register", "restrict", "return", "sizeof", "static", "struct", "switch",
            "typedef", "union", "volatile", "while", "_Bool", "_Atomic", "_Static_assert", "class", "namespace",
            "template", "typename", "public", "private", "protected", "virtual", "override", "new", "delete", "this",
            "using", "constexpr", "nullptr", "try", "catch", "throw", "operator", "friend", "explicit", "noexcept",
            "@interface", "@implementation", "@end", "@property", "self", "super"])
        s.types = WordSet(["void", "char", "short", "int", "long", "float", "double", "signed", "unsigned", "bool",
            "size_t", "ssize_t", "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t",
            "uintptr_t", "intptr_t", "ptrdiff_t", "FILE", "id", "BOOL", "auto"])
        s.constants = WordSet(["true", "false", "NULL", "nil", "YES", "NO"])
        s.preprocessor = true
        return CodeTokenizer(s)
    }()

    static let ruby: CodeTokenizer = {
        var s = CodeSpec()
        s.lineComments = [Array("#".utf16)]
        s.strings = [StringRule("\"", multiline: true), StringRule("'", multiline: true)]
        s.keywords = WordSet(["alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif",
            "end", "ensure", "for", "if", "in", "module", "next", "not", "or", "redo", "rescue", "retry", "return",
            "self", "super", "then", "undef", "unless", "until", "when", "while", "yield", "require", "require_relative",
            "include", "extend", "attr_reader", "attr_writer", "attr_accessor", "private", "protected", "public", "lambda", "proc"])
        s.constants = WordSet(["true", "false", "nil"])
        s.capitalizedAreTypes = true
        s.atVariables = true
        s.colonSymbols = true
        s.predicateSuffix = true
        return CodeTokenizer(s)
    }()
}
