import Foundation

/// A small Markdown → HTML renderer for the preview: CommonMark's common
/// constructs plus GitHub's tables, task lists, strikethrough and
/// autolinks. Not a full CommonMark implementation (no reference-style
/// links, no lazy continuation lines, emphasis by simple pairing rather
/// than the delimiter-run algorithm); good enough to preview READMEs and
/// notes, with no dependencies.
///
/// Blocks carry `data-line="N"` (0-based source line), list items and
/// blocks inside lists and quotes too, so the preview can scroll in step
/// with the editor both ways.
public enum Markdown {
    /// What to render beyond the plain HTML.
    public struct Options: Sendable {
        public init() {}
        /// The live preview's options.
        public static let preview = Options()
    }

    public static func render(_ source: String, options: Options = Options()) -> String {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out = ""
        renderBlocks(lines[...], firstLine: 0, into: &out)
        return out
    }

    // MARK: Blocks

    /// `firstLine`: the source line of `lines.first` (nil: no data-line).
    /// Each slice line is one source line, so nested blocks know theirs.
    private static func renderBlocks(_ lines: ArraySlice<String>, firstLine: Int?, into out: inout String) {
        var i = lines.startIndex
        let end = lines.endIndex
        func srcLine(_ idx: Int) -> Int? { firstLine.map { $0 + idx - lines.startIndex } }
        func attr(_ idx: Int) -> String { srcLine(idx).map { " data-line=\"\($0)\"" } ?? "" }

        while i < end {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = leadingSpaces(line)
            if trimmed.isEmpty { i += 1; continue }

            // Fenced code.
            if indent <= 3, let fence = fenceMarker(trimmed) {
                let info = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                var j = i + 1
                while j < end, !(leadingSpaces(lines[j]) <= 3 && lines[j].trimmingCharacters(in: .whitespaces).hasPrefix(fence)
                                 && lines[j].trimmingCharacters(in: .whitespaces).allSatisfy({ $0 == fence.first })) {
                    body.append(String(lines[j].dropFirst(min(indent, leadingSpaces(lines[j])))))
                    j += 1
                }
                let lang = info.split(separator: " ").first.map { " class=\"language-\(escape(String($0)))\"" } ?? ""
                out += "<pre\(attr(i))><code\(lang)>\(escape(body.joined(separator: "\n")))\(body.isEmpty ? "" : "\n")</code></pre>\n"
                i = min(end, j + 1)
                continue
            }

            // Indented code.
            if indent >= 4 {
                var body: [String] = []
                var j = i
                while j < end, leadingSpaces(lines[j]) >= 4 || lines[j].trimmingCharacters(in: .whitespaces).isEmpty {
                    body.append(String(lines[j].dropFirst(min(4, leadingSpaces(lines[j])))))
                    j += 1
                }
                while body.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { body.removeLast() }
                out += "<pre\(attr(i))><code>\(escape(body.joined(separator: "\n")))\n</code></pre>\n"
                i = j
                continue
            }

            // ATX heading.
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix { $0 == "#" }.count
                let rest = trimmed.dropFirst(level)
                if level <= 6, rest.isEmpty || rest.first == " " {
                    var text = rest.trimmingCharacters(in: .whitespaces)
                    // Optional closing #s.
                    while text.hasSuffix("#") { text.removeLast() }
                    text = text.trimmingCharacters(in: .whitespaces)
                    out += "<h\(level)\(attr(i)) id=\"\(slug(text))\">\(inline(text))</h\(level)>\n"
                    i += 1
                    continue
                }
            }

            // Thematic break.
            if isThematicBreak(trimmed) {
                out += "<hr\(attr(i))>\n"
                i += 1
                continue
            }

            // Block quote.
            if trimmed.hasPrefix(">") {
                var inner: [String] = []
                var j = i
                while j < end {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    var rest = t.dropFirst()
                    if rest.first == " " { rest = rest.dropFirst() }
                    inner.append(String(rest))
                    j += 1
                }
                out += "<blockquote\(attr(i))>\n"
                renderBlocks(inner[...], firstLine: srcLine(i), into: &out)
                out += "</blockquote>\n"
                i = j
                continue
            }

            // Lists.
            if let marker = listMarker(line) {
                i = renderList(lines, from: i, first: marker, firstLine: srcLine(i), into: &out)
                continue
            }

            // HTML block: passed through until a blank line.
            if indent <= 3, isHTMLBlockStart(trimmed) {
                var j = i
                while j < end, !lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                out += lines[i..<j].joined(separator: "\n") + "\n"
                i = j
                continue
            }

            // Table: a header row, then a delimiter row.
            if trimmed.contains("|"), i + 1 < end, isTableDelimiter(lines[i + 1]) {
                i = renderTable(lines, from: i, attr: attr(i), into: &out)
                continue
            }

            // Paragraph (or setext heading).
            var para: [String] = [line.hasSuffix("  ") ? trimmed + "  " : trimmed]
            var j = i + 1
            var setext = 0
            while j < end {
                let t = lines[j].trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if !t.isEmpty, t.allSatisfy({ $0 == "=" }) { setext = 1; j += 1; break }
                if t.count >= 1, t.allSatisfy({ $0 == "-" }), leadingSpaces(lines[j]) <= 3 { setext = 2; j += 1; break }
                if leadingSpaces(lines[j]) <= 3,
                   fenceMarker(t) != nil || t.hasPrefix("#") || t.hasPrefix(">") || isThematicBreak(t) || listMarker(lines[j]) != nil
                    || isHTMLBlockStart(t) {
                    break
                }
                para.append(lines[j].hasSuffix("  ") ? t + "  " : t)
                j += 1
            }
            if setext > 0 {
                let text = para.joined(separator: " ")
                out += "<h\(setext)\(attr(i)) id=\"\(slug(text))\">\(inline(text))</h\(setext)>\n"
            } else {
                out += "<p\(attr(i))>\(inlineLines(para))</p>\n"
            }
            i = j
        }
    }

    private struct ListMarker {
        var ordered: Bool
        var start: Int
        var bullet: Character
        /// Columns from the line start to the item's content.
        var contentIndent: Int
    }

    private static func listMarker(_ line: String) -> ListMarker? {
        let indent = leadingSpaces(line)
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard let f = rest.first else { return nil }
        if f == "-" || f == "*" || f == "+" {
            let after = rest.dropFirst()
            guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
            if isThematicBreak(String(rest).trimmingCharacters(in: .whitespaces)) { return nil }
            let pad = min(4, max(1, after.prefix { $0 == " " }.count))
            return ListMarker(ordered: false, start: 1, bullet: f, contentIndent: indent + 1 + (after.isEmpty ? 1 : pad))
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let after = rest.dropFirst(digits.count)
        guard let delim = after.first, delim == "." || delim == ")" else { return nil }
        let afterDelim = after.dropFirst()
        guard afterDelim.isEmpty || afterDelim.first == " " else { return nil }
        let pad = min(4, max(1, afterDelim.prefix { $0 == " " }.count))
        return ListMarker(ordered: true, start: Int(digits) ?? 1, bullet: delim, contentIndent: indent + digits.count + 1 + pad)
    }

    private static func renderList(_ lines: ArraySlice<String>, from start: Int, first: ListMarker, firstLine: Int?,
                                   into out: inout String) -> Int {
        let attr = firstLine.map { " data-line=\"\($0)\"" } ?? ""
        var items: [[String]] = []
        var itemLines: [Int?] = []
        var loose = false
        var i = start
        let end = lines.endIndex
        var marker = first
        while i < end, let m = listMarker(lines[i]), m.ordered == first.ordered, m.bullet == first.bullet {
            marker = m
            var item: [String] = [String(lines[i].dropFirst(min(m.contentIndent, lines[i].count)))]
            var j = i + 1
            var sawBlank = false
            while j < end {
                let l = lines[j]
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { sawBlank = true; item.append(""); j += 1; continue }
                if leadingSpaces(l) >= marker.contentIndent {
                    if sawBlank { loose = true }
                    item.append(String(l.dropFirst(marker.contentIndent)))
                    sawBlank = false
                    j += 1
                    continue
                }
                if sawBlank { break }
                // Lazy continuation of the item's paragraph.
                if listMarker(l) == nil, !t.hasPrefix("#"), !t.hasPrefix(">"), fenceMarker(t) == nil {
                    item.append(t)
                    j += 1
                    continue
                }
                break
            }
            while item.last == "" { item.removeLast() }
            items.append(item)
            itemLines.append(firstLine.map { $0 + i - start })
            // A blank line before the next item makes the list loose.
            if j > i + 1, j < end, lines[j - 1].trimmingCharacters(in: .whitespaces).isEmpty, listMarker(lines[j]) != nil { loose = true }
            i = j
            while i < end, lines[i].trimmingCharacters(in: .whitespaces).isEmpty,
                  i + 1 < end, let next = listMarker(lines[i + 1]), next.ordered == first.ordered, next.bullet == first.bullet {
                loose = true
                i += 1
            }
        }
        let tag = first.ordered ? "ol" : "ul"
        let startAttr = first.ordered && first.start != 1 ? " start=\"\(first.start)\"" : ""
        out += "<\(tag)\(attr)\(startAttr)>\n"
        for (k, item) in items.enumerated() {
            var body = item
            var checkbox = ""
            if let firstLine = body.first, firstLine.hasPrefix("[ ] ") || firstLine.hasPrefix("[x] ") || firstLine.hasPrefix("[X] ") {
                checkbox = firstLine.hasPrefix("[ ]") ? "<input type=\"checkbox\" disabled> " : "<input type=\"checkbox\" checked disabled> "
                body[0] = String(firstLine.dropFirst(4))
            }
            var inner = ""
            renderBlocks(body[...], firstLine: itemLines[k], into: &inner)
            if !loose {
                // Tight: unwrap the item's paragraphs.
                inner = inner.replacingOccurrences(of: #"<p( data-line="\d+")?>"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: "</p>\n", with: "\n")
            }
            while inner.hasSuffix("\n") { inner.removeLast() }
            let liAttr = itemLines[k].map { " data-line=\"\($0)\"" } ?? ""
            out += "<li\(liAttr)>\(checkbox)\(inner)</li>\n"
        }
        out += "</\(tag)>\n"
        return i
    }

    private static func renderTable(_ lines: ArraySlice<String>, from start: Int, attr: String, into out: inout String) -> Int {
        let header = cells(lines[start])
        let aligns: [String?] = cells(lines[start + 1]).map { c in
            let t = c.trimmingCharacters(in: .whitespaces)
            switch (t.hasPrefix(":"), t.hasSuffix(":")) {
            case (true, true): return "center"
            case (false, true): return "right"
            case (true, false): return "left"
            default: return nil
            }
        }
        func cellTag(_ tag: String, _ k: Int, _ text: String) -> String {
            let a = k < aligns.count ? aligns[k].map { " style=\"text-align:\($0)\"" } ?? "" : ""
            return "<\(tag)\(a)>\(inline(text))</\(tag)>"
        }
        out += "<table\(attr)>\n<thead>\n<tr>" + header.enumerated().map { cellTag("th", $0.offset, $0.element) }.joined() + "</tr>\n</thead>\n"
        var i = start + 2
        var rows = ""
        while i < lines.endIndex {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.isEmpty || !t.contains("|") { break }
            let row = cells(lines[i])
            rows += "<tr>" + (0..<header.count).map { cellTag("td", $0, $0 < row.count ? row[$0] : "") }.joined() + "</tr>\n"
            i += 1
        }
        if !rows.isEmpty { out += "<tbody>\n\(rows)</tbody>\n" }
        out += "</table>\n"
        return i
    }

    private static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|"), !t.hasSuffix("\\|") { t.removeLast() }
        var result: [String] = []
        var current = ""
        var inCode = false
        var escaped = false
        for ch in t {
            if escaped { current.append(ch == "|" ? "|" : "\\\(ch)"); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "`" { inCode.toggle() }
            if ch == "|", !inCode { result.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
            current.append(ch)
        }
        result.append(current.trimmingCharacters(in: .whitespaces))
        return result
    }

    private static func isTableDelimiter(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") || t.hasPrefix(":") else { return false }
        return cells(line).allSatisfy { c in
            let s = c.trimmingCharacters(in: .whitespaces)
            return !s.isEmpty && s.allSatisfy { $0 == "-" || $0 == ":" } && s.contains("-")
        }
    }

    private static func fenceMarker(_ trimmed: String) -> String? {
        for f in ["```", "~~~"] where trimmed.hasPrefix(f) {
            let ch = f.first!
            let run = trimmed.prefix { $0 == ch }
            if f == "```", trimmed.dropFirst(run.count).contains("`") { return nil }
            return String(run)
        }
        return nil
    }

    private static func isThematicBreak(_ trimmed: String) -> Bool {
        guard let f = trimmed.first, f == "-" || f == "*" || f == "_" else { return false }
        let chars = trimmed.filter { $0 != " " && $0 != "\t" }
        return chars.count >= 3 && chars.allSatisfy { $0 == f }
    }

    private static let htmlBlockTags: Set<String> = ["address", "article", "aside", "blockquote", "details", "dialog", "div",
        "dl", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr",
        "main", "nav", "ol", "p", "pre", "section", "summary", "table", "ul", "script", "style", "iframe", "center", "img", "picture", "video"]

    private static func isHTMLBlockStart(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("<") else { return false }
        if trimmed.hasPrefix("<!--") { return true }
        let name = trimmed.dropFirst().drop { $0 == "/" }.prefix { $0.isLetter || $0.isNumber }.lowercased()
        return htmlBlockTags.contains(name)
    }

    private static func leadingSpaces(_ line: String) -> Int {
        var n = 0
        for ch in line {
            if ch == " " { n += 1 } else if ch == "\t" { n += 4 - n % 4 } else { break }
        }
        return n
    }

    // MARK: Inline

    private static func inlineLines(_ lines: [String]) -> String {
        var parts: [String] = []
        for (k, l) in lines.enumerated() {
            let last = k == lines.count - 1
            if !last, l.hasSuffix("  ") {
                parts.append(inline(l.trimmingCharacters(in: .whitespaces)) + "<br>")
            } else if !last, l.hasSuffix("\\") {
                parts.append(inline(String(l.dropLast())) + "<br>")
            } else {
                parts.append(inline(l.trimmingCharacters(in: .whitespaces)))
            }
        }
        return parts.joined(separator: "\n")
    }

    private nonisolated(unsafe) static let linkRegex = try! NSRegularExpression(pattern: #"(!?)\[([^\]]*)\]\(\s*<?([^)\s>]*)>?(?:\s+&quot;([^&]*)&quot;)?\s*\)"#)
    private nonisolated(unsafe) static let strongEmRegex = try! NSRegularExpression(pattern: #"(\*\*\*|___)(?=\S)(.+?)(?<=\S)\1"#)
    private nonisolated(unsafe) static let strongRegex = try! NSRegularExpression(pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private nonisolated(unsafe) static let emRegex = try! NSRegularExpression(pattern: #"(?<![\w*])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![\w*])|(?<![\w_])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![\w_])"#)
    private nonisolated(unsafe) static let strikeRegex = try! NSRegularExpression(pattern: #"~~(?=\S)(.+?)(?<=\S)~~"#)
    private nonisolated(unsafe) static let bareURLRegex = try! NSRegularExpression(pattern: #"(?<![\w"'=/>])https?://[^\s<]+[^\s<.,:;"')\]]"#)

    /// Inline Markdown → HTML. Code spans, autolinks, raw inline tags and
    /// escapes are lifted out into placeholders first so nothing inside
    /// them is reinterpreted, the rest is HTML-escaped, then links,
    /// emphasis and strikethrough are applied, then placeholders restored.
    static func inline(_ text: String) -> String {
        var held: [String] = []
        func hold(_ html: String) -> String {
            held.append(html)
            return "\u{E000}\(held.count - 1)\u{E001}"
        }
        var s = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, "\\`*_{}[]()#+-.!|~<>\"'".contains(chars[i + 1]) {
                s += hold(escape(String(chars[i + 1])))
                i += 2
                continue
            }
            if c == "`" {
                var run = 0
                while i + run < chars.count, chars[i + run] == "`" { run += 1 }
                var j = i + run
                var found: Int?
                while j < chars.count {
                    if chars[j] == "`" {
                        var r = 0
                        while j + r < chars.count, chars[j + r] == "`" { r += 1 }
                        if r == run { found = j; break }
                        j += r
                    } else {
                        j += 1
                    }
                }
                if let close = found {
                    var code = String(chars[(i + run)..<close])
                    if code.hasPrefix(" "), code.hasSuffix(" "), code.count > 2 { code = String(code.dropFirst().dropLast()) }
                    s += hold("<code>\(escape(code))</code>")
                    i = close + run
                } else {
                    s += String(repeating: "`", count: run)
                    i += run
                }
                continue
            }
            if c == "<", let close = chars[(i + 1)...].firstIndex(of: ">") {
                let inner = String(chars[(i + 1)..<close])
                if inner.hasPrefix("http://") || inner.hasPrefix("https://") || inner.hasPrefix("mailto:") {
                    let href = escape(inner)
                    s += hold("<a href=\"\(href)\">\(href)</a>")
                    i = close + 1
                    continue
                }
                if inner.range(of: #"^/?[A-Za-z][A-Za-z0-9-]*(\s[^<>]*)?/?$"#, options: .regularExpression) != nil {
                    s += hold("<\(inner)>")
                    i = close + 1
                    continue
                }
            }
            s.append(c)
            i += 1
        }
        s = escape(s)
        s = replace(linkRegex, in: s) { m, ns in
            let isImage = m.range(at: 1).length > 0
            let label = ns.substring(with: m.range(at: 2))
            let url = safeURL(ns.substring(with: m.range(at: 3)))
            let title = m.range(at: 4).location != NSNotFound ? " title=\"\(ns.substring(with: m.range(at: 4)))\"" : ""
            return isImage ? "<img src=\"\(url)\" alt=\"\(label)\"\(title)>" : "<a href=\"\(url)\"\(title)>\(label)</a>"
        }
        s = replace(bareURLRegex, in: s) { m, ns in
            let u = ns.substring(with: m.range)
            return "<a href=\"\(u)\">\(u)</a>"
        }
        s = replace(strongEmRegex, in: s) { m, ns in "<strong><em>\(ns.substring(with: m.range(at: 2)))</em></strong>" }
        s = replace(strongRegex, in: s) { m, ns in "<strong>\(ns.substring(with: m.range(at: 2)))</strong>" }
        s = replace(emRegex, in: s) { m, ns in
            let r = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
            return "<em>\(ns.substring(with: r))</em>"
        }
        s = replace(strikeRegex, in: s) { m, ns in "<del>\(ns.substring(with: m.range(at: 1)))</del>" }
        // Restore placeholders (they may nest inside link labels).
        if !held.isEmpty {
            var restored = ""
            var it = s.makeIterator()
            while let ch = it.next() {
                if ch == "\u{E000}" {
                    var num = ""
                    while let d = it.next(), d != "\u{E001}" { num.append(d) }
                    if let k = Int(num), k < held.count { restored += held[k] }
                } else {
                    restored.append(ch)
                }
            }
            s = restored
        }
        return s
    }

    private static func replace(_ regex: NSRegularExpression, in s: String, _ make: (NSTextCheckingResult, NSString) -> String) -> String {
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }
        var out = ""
        var last = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += make(m, ns)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// No `javascript:` (or other script-capable) links in the preview.
    private static func safeURL(_ url: String) -> String {
        let lower = url.lowercased().trimmingCharacters(in: .whitespaces)
        if lower.hasPrefix("javascript:") || lower.hasPrefix("vbscript:") || lower.hasPrefix("data:text/html") { return "#" }
        return url
    }

    public static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    static func slug(_ text: String) -> String {
        let lowered = text.lowercased()
        var out = ""
        for ch in lowered {
            if ch.isLetter || ch.isNumber { out.append(ch) } else if ch == " " || ch == "-" { out.append("-") }
        }
        return escape(out)
    }
}
