import Foundation

/// The headings of a Markdown document, for the outline sidebar and Go to
/// Heading: ATX (`# Title`) and setext (`Title` over `===` / `---`)
/// headings, skipping fenced and indented code, HTML comments and YAML
/// frontmatter, so a `# comment` in a shell block isn't a heading.
public enum MarkdownOutline {
    public struct Heading: Equatable, Sendable {
        public var level: Int
        public var title: String
        /// 0-based source line (the text line, for a setext heading).
        public var line: Int

        public init(level: Int, title: String, line: Int) {
            self.level = level
            self.title = title
            self.line = line
        }
    }

    /// Up to `limit` headings, in order.
    public static func headings(in text: String, limit: Int = .max) -> [Heading] {
        var out: [Heading] = []
        var fence: (char: Character, count: Int)?
        var inComment = false
        var prev: (text: String, line: Int, paragraph: Bool)?
        var lineNo = -1
        var frontmatter = false
        text.enumerateLines { raw, stop in
            lineNo += 1
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if lineNo == 0, line.trimmingCharacters(in: .whitespaces) == "---" { frontmatter = true; prev = nil; return }
            if frontmatter {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t == "---" || t == "..." { frontmatter = false }
                return
            }
            var indent = 0
            for ch in line { if ch == " " { indent += 1 } else if ch == "\t" { indent += 4 - indent % 4 } else { break } }
            let t = line.trimmingCharacters(in: .whitespaces)
            if let f = fence {
                if indent <= 3, t.first == f.char, t.prefix(while: { $0 == f.char }).count >= f.count, t.allSatisfy({ $0 == f.char }) { fence = nil }
                prev = nil
                return
            }
            if inComment {
                if t.contains("-->") { inComment = false }
                prev = nil
                return
            }
            if indent <= 3, let c = t.first, c == "`" || c == "~" {
                let run = t.prefix { $0 == c }.count
                if run >= 3, !(c == "`" && t.dropFirst(run).contains("`")) { fence = (c, run); prev = nil; return }
            }
            if indent <= 3, t.hasPrefix("<!--"), !t.contains("-->") { inComment = true; prev = nil; return }
            if t.isEmpty { prev = nil; return }
            if indent >= 4, prev?.paragraph != true { prev = nil; return }
            if indent <= 3, t.first == "#" {
                let level = t.prefix { $0 == "#" }.count
                let rest = t.dropFirst(level)
                if level <= 6, rest.isEmpty || rest.first == " " || rest.first == "\t" {
                    var title = rest.trimmingCharacters(in: .whitespaces)
                    // Optional closing #s (after a space).
                    if let r = title.range(of: #"(^|\s)#+$"#, options: .regularExpression) { title = String(title[..<r.lowerBound]) }
                    out.append(Heading(level: level, title: plain(title.trimmingCharacters(in: .whitespaces)), line: lineNo))
                    if out.count >= limit { stop = true }
                    prev = nil
                    return
                }
            }
            if indent <= 3, let p = prev, p.paragraph, let c = t.first, c == "=" || c == "-", t.allSatisfy({ $0 == c }) {
                out.append(Heading(level: c == "=" ? 1 : 2, title: plain(p.text), line: p.line))
                if out.count >= limit { stop = true }
                prev = nil
                return
            }
            // A paragraph line (setext candidate): not a list item, quote, rule or table row.
            let isList = t.range(of: #"^([-*+]|\d{1,9}[.)])(\s|$)"#, options: .regularExpression) != nil
            let paragraph = !isList && !t.hasPrefix(">") && !t.hasPrefix("|") && !t.hasPrefix("<")
            prev = paragraph ? (prev?.paragraph == true ? prev! : (t, lineNo, true)) : (t, lineNo, false)
        }
        return out
    }

    /// The index of the heading the caret's line `line` is under (the last
    /// one at or above it), or nil above the first.
    public static func current(_ headings: [Heading], line: Int) -> Int? {
        var lo = 0, hi = headings.count - 1, best: Int?
        while lo <= hi {
            let m = (lo + hi) / 2
            if headings[m].line <= line { best = m; lo = m + 1 } else { hi = m - 1 }
        }
        return best
    }

    /// A heading's text without its Markdown: `**a** [b](c) `d`` → `a b d`.
    static func plain(_ s: String) -> String {
        var t = s
        if t.contains("](") { t = t.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression) }
        if t.contains(where: { $0 == "*" || $0 == "_" || $0 == "`" || $0 == "~" }) {
            t = t.replacingOccurrences(of: #"(\*\*|__|~~|\*|`)"#, with: "", options: .regularExpression)
            t = t.replacingOccurrences(of: #"(^|\s)_(\S)"#, with: "$1$2", options: .regularExpression)
            t = t.replacingOccurrences(of: #"(\S)_(\s|$)"#, with: "$1$2", options: .regularExpression)
        }
        return t.trimmingCharacters(in: .whitespaces)
    }
}
