import Foundation

/// `.editorconfig` (https://editorconfig.org), the four properties the owl
/// follows: indent_style, indent_size (and tab_width), insert_final_newline
/// and trim_trailing_whitespace. Pure: the app reads the files (from the
/// document's folder up to the one with `root = true`) and hands their
/// text here, nearest last.
public enum EditorConfig {
    public struct Values: Sendable, Equatable {
        public enum IndentStyle: String, Sendable { case tab, space }
        public var indentStyle: IndentStyle?
        public var indentSize: Int?
        public var tabWidth: Int?
        public var insertFinalNewline: Bool?
        public var trimTrailingWhitespace: Bool?

        public init(indentStyle: IndentStyle? = nil, indentSize: Int? = nil, tabWidth: Int? = nil,
                    insertFinalNewline: Bool? = nil, trimTrailingWhitespace: Bool? = nil) {
            self.indentStyle = indentStyle
            self.indentSize = indentSize
            self.tabWidth = tabWidth
            self.insertFinalNewline = insertFinalNewline
            self.trimTrailingWhitespace = trimTrailingWhitespace
        }

        public var isEmpty: Bool { self == Values() }

        /// Spaces per indent level (indent_size, else tab_width).
        public var width: Int? { indentSize ?? tabWidth }
    }

    public struct File: Sendable {
        public var root = false
        /// Sections in file order: the glob and its properties (lower-cased keys and values).
        public var sections: [(glob: String, props: [String: String])] = []
    }

    public static func parse(_ text: String) -> File {
        var f = File()
        var current: Int?
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                f.sections.append((String(line.dropFirst().dropLast()), [:]))
                current = f.sections.count - 1
                continue
            }
            guard let eq = line.firstIndex(where: { $0 == "=" || $0 == ":" }) else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces).lowercased()
            if let k = current { f.sections[k].props[key] = value } else if key == "root" { f.root = value == "true" }
        }
        return f
    }

    /// The values for `path` (relative to the folder of the file that
    /// holds `configs[i]`: `relative[i]`), from the outermost config to
    /// the nearest (later sections and nearer files win).
    public static func values(for relativePaths: [String], configs: [File]) -> Values {
        var props: [String: String] = [:]
        for (file, rel) in zip(configs, relativePaths) {
            for s in file.sections where matches(glob: s.glob, path: rel) {
                for (k, v) in s.props { props[k] = v }
            }
        }
        var v = Values()
        func flag(_ k: String) -> Bool? { props[k] == "true" ? true : props[k] == "false" ? false : nil }
        if let s = props["indent_style"] { v.indentStyle = Values.IndentStyle(rawValue: s) }
        if let s = props["indent_size"] { v.indentSize = s == "tab" ? nil : Int(s) }
        if let s = props["tab_width"] { v.tabWidth = Int(s) }
        if props["indent_size"] == "tab" { v.indentSize = v.tabWidth }
        v.insertFinalNewline = flag("insert_final_newline")
        v.trimTrailingWhitespace = flag("trim_trailing_whitespace")
        return v
    }

    /// EditorConfig's glob: `*` (not /), `**`, `?`, `[abc]`, `[!abc]`,
    /// `{a,b}`, `{1..3}`. A glob without `/` matches the file name in any
    /// folder; one with `/` is relative to the config's folder.
    public static func matches(glob: String, path: String) -> Bool {
        var g = glob
        if g.hasPrefix("/") { g.removeFirst() } else if !g.contains("/") { g = "**/" + g }
        guard let re = try? NSRegularExpression(pattern: "^" + regex(g) + "$") else { return false }
        return re.firstMatch(in: path, range: NSRange(location: 0, length: (path as NSString).length)) != nil
    }

    static func regex(_ g: String) -> String {
        let c = Array(g)
        var out = "", i = 0, braces = 0
        while i < c.count {
            let ch = c[i]
            switch ch {
            case "*":
                if i + 1 < c.count, c[i + 1] == "*" {
                    // **/ matches any folders, including none.
                    if i + 2 < c.count, c[i + 2] == "/" { out += "(?:.*/)?"; i += 3; continue }
                    out += ".*"; i += 2; continue
                }
                out += "[^/]*"
            case "?": out += "[^/]"
            case "[":
                if let close = c[(i + 1)...].firstIndex(of: "]") {
                    var body = String(c[(i + 1)..<close])
                    if body.hasPrefix("!") { body = "^" + body.dropFirst() }
                    out += "[" + body.replacingOccurrences(of: "\\", with: "\\\\") + "]"
                    i = close + 1
                    continue
                }
                out += "\\["
            case "{":
                if let close = c[(i + 1)...].firstIndex(of: "}") {
                    let body = String(c[(i + 1)..<close])
                    let range = body.components(separatedBy: "..")
                    if range.count == 2, let a = Int(range[0]), let b = Int(range[1]), a <= b, b - a < 1000 {
                        out += "(?:" + (a...b).map(String.init).joined(separator: "|") + ")"
                        i = close + 1
                        continue
                    }
                    if body.contains(",") { out += "(?:"; braces += 1; i += 1; continue }
                }
                out += "\\{"
            case "}" where braces > 0: out += ")"; braces -= 1
            case "," where braces > 0: out += "|"
            case "\\":
                if i + 1 < c.count { out += NSRegularExpression.escapedPattern(for: String(c[i + 1])); i += 2; continue }
                out += "\\\\"
            default: out += NSRegularExpression.escapedPattern(for: String(ch))
            }
            i += 1
        }
        return out
    }
}
