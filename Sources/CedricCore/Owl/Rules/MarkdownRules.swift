import Foundation

/// Pack 5: Markdown. Sources: markdownlint (MD051 link fragments) and
/// CommonMark's fenced code blocks. Links and fences inside code (fenced
/// blocks, inline code spans), HTML comments and front matter are not
/// looked at.
enum MarkdownRules {
    static let fenceID = "rules.md.unclosed-fence"
    static let anchorID = "rules.md.broken-anchor"
    static let relativeLinkID = "rules.md.broken-link"

    static let markdown = LintRule.languages(["markdown"])

    // MARK: Structure (fences, code spans), once per query

    struct Fence {
        var line: Int          // index into the lines
        var char: unichar      // ` or ~
        var length: Int
    }

    struct Structure {
        /// Not prose: fenced blocks (with their fence lines), inline code,
        /// HTML comments and front matter.
        var skip: [NSRange] = []
        /// A fence opened and never closed (the whole text was read).
        var unclosed: Fence?
        /// How many fences opened.
        var fences = 0

        func isSkipped(_ offset: Int) -> Bool {
            var lo = 0, hi = skip.count - 1
            while lo <= hi {
                let mid = (lo + hi) / 2
                let r = skip[mid]
                if offset < r.location { hi = mid - 1 } else if offset >= NSMaxRange(r) { lo = mid + 1 } else { return true }
            }
            return false
        }
    }

    /// A fence line: up to three spaces (after any `>` quote markers and,
    /// in a list item, its indent), then three or more backticks or tildes.
    /// A backtick fence's info string has no backtick (```` ```a``` ```` is
    /// inline code).
    static func fence(_ s: NSString, _ r: NSRange) -> (char: unichar, length: Int, rest: String)? {
        var i = r.location
        var end = NSMaxRange(r)
        if end > i, s.character(at: end - 1) == 13 { end -= 1 }   // CRLF
        while i < end, s.character(at: i) == 62 || s.character(at: i) == 32 || s.character(at: i) == 9 { i += 1 }   // > and indent
        guard i + 2 < end else { return nil }
        let c = s.character(at: i)
        guard c == 96 || c == 126 else { return nil }
        var run = 0
        while i + run < end, s.character(at: i + run) == c { run += 1 }
        guard run >= 3 else { return nil }
        let rest = s.substring(with: NSRange(location: i + run, length: end - i - run))
        if c == 96, rest.contains("`") { return nil }
        return (c, run, rest)
    }

    static func structure(_ s: NSString, lines: [NSRange]) -> Structure {
        var st = Structure()
        var open: (Fence, Int)?   // and where it starts
        var k = 0
        // Front matter: a first line of --- up to the next --- or ...
        if let first = lines.first, s.substring(with: first).trimmingCharacters(in: .whitespaces) == "---" {
            for j in 1..<min(lines.count, 200) {
                let t = s.substring(with: lines[j]).trimmingCharacters(in: .whitespaces)
                if t == "---" || t == "..." {
                    st.skip.append(NSRange(location: 0, length: NSMaxRange(lines[j])))
                    k = j + 1
                    break
                }
            }
        }
        var inComment = false, commentStart = 0
        while k < lines.count {
            let r = lines[k]
            defer { k += 1 }
            if inComment {
                let close = s.range(of: "-->", options: [], range: r)
                if close.location != NSNotFound {
                    st.skip.append(NSRange(location: commentStart, length: NSMaxRange(close) - commentStart))
                    inComment = false
                }
                continue
            }
            if let (f, start) = open {
                if let g = fence(s, r), g.char == f.char, g.length >= f.length, g.rest.trimmingCharacters(in: .whitespaces).isEmpty {
                    st.skip.append(NSRange(location: start, length: NSMaxRange(r) - start))
                    open = nil
                }
                continue
            }
            if let g = fence(s, r) {
                open = (Fence(line: k, char: g.char, length: g.length), r.location)
                st.fences += 1
                continue
            }
            // Inline code spans: a run of n backticks up to the next run of n.
            if s.range(of: "`", options: [], range: r).location != NSNotFound {
                var i = r.location
                let end = NSMaxRange(r)
                while i < end {
                    guard s.character(at: i) == 96 else { i += 1; continue }
                    var n = 0
                    while i + n < end, s.character(at: i + n) == 96 { n += 1 }
                    var j = i + n, closed = false
                    while j < end {
                        if s.character(at: j) == 96 {
                            var m = 0
                            while j + m < end, s.character(at: j + m) == 96 { m += 1 }
                            if m == n { st.skip.append(NSRange(location: i, length: j + m - i)); i = j + m; closed = true; break }
                            j += m
                        } else { j += 1 }
                    }
                    if !closed { i += n }
                }
            }
            // HTML comments.
            var from = r.location
            while from < NSMaxRange(r) {
                let o = s.range(of: "<!--", options: [], range: NSRange(location: from, length: NSMaxRange(r) - from))
                guard o.location != NSNotFound else { break }
                let c = s.range(of: "-->", options: [], range: NSRange(location: NSMaxRange(o), length: NSMaxRange(r) - NSMaxRange(o)))
                if c.location != NSNotFound {
                    st.skip.append(NSRange(location: o.location, length: NSMaxRange(c) - o.location))
                    from = NSMaxRange(c)
                } else {
                    inComment = true
                    commentStart = o.location
                    break
                }
            }
        }
        if let (f, start) = open {
            st.unclosed = f
            st.skip.append(NSRange(location: start, length: s.length - start))
        }
        if inComment { st.skip.append(NSRange(location: commentStart, length: s.length - commentStart)) }
        st.skip.sort { $0.location < $1.location }
        return st
    }

    // MARK: MD1 An unclosed code fence

    static let unclosedFence = LintRule(fenceID, wholeDocument: true, applies: markdown) { input in
        let s = input.text
        guard s.range(of: "```").location != NSNotFound || s.range(of: "~~~").location != NSNotFound else { return nil }
        guard let f = input.markdownStructure.unclosed else { return nil }
        let r = input.lines[f.line]
        let run = String(repeating: Character(UnicodeScalar(f.char)!), count: f.length)
        return LintFinding(kind: .warning, title: String(localized: "This code block is never closed (line \(f.line + 1))."),
                           detail: String(localized: "Everything after the \(run) on line \(f.line + 1) shows as code. Close it with a line of \(run) where the code ends."),
                           range: r)
    }

    // MARK: Links

    struct Link {
        var target: NSRange     // the destination, without <> or a title
        var image: Bool
        var whole: NSRange      // the whole link, for Show Me
        var altEmpty: Bool = false
    }

    /// `[text](dest)` / `![alt](dest "title")`, `[label]: dest` and
    /// `<img src="dest">` / `<a href="dest">`, outside code.
    static let inlineLink = try! NSRegularExpression(pattern: #"(!?)\[((?:[^\[\]\n]|\[[^\[\]\n]*\])*)\]\(\s*(<[^<>\n]*>|[^\s()<>]*(?:\([^\s()]*\)[^\s()<>]*)*)(?:\s+(?:"[^"\n]*"|'[^'\n]*'|\([^()\n]*\)))?\s*\)"#)
    static let refDefinition = try! NSRegularExpression(pattern: #"(?m)^ {0,3}\[[^\]\n]+\]:[ \t]*(<[^<>\n]*>|\S+)"#)
    static let htmlLink = try! NSRegularExpression(pattern: #"(?i)<(img|a|source)\b[^>\n]*?\s(src|href)\s*=\s*(?:"([^"\n]*)"|'([^'\n]*)')"#)

    static func links(_ input: LintInput) -> [Link] {
        input.shared("md.links") {
            let s = input.text, str = input.string
            let st = input.markdownStructure
            var out: [Link] = []
            func add(_ target: NSRange, image: Bool, whole: NSRange, altEmpty: Bool = false) {
                guard !st.isSkipped(whole.location) else { return }
                var t = target
                // <dest>: without the brackets.
                if t.length >= 2, s.character(at: t.location) == 60, s.character(at: NSMaxRange(t) - 1) == 62 {
                    t = NSRange(location: t.location + 1, length: t.length - 2)
                }
                out.append(Link(target: t, image: image, whole: whole, altEmpty: altEmpty))
            }
            if s.range(of: "](").location != NSNotFound {
                for m in RulesHintProvider.matches(inlineLink, str) {
                    let alt = s.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
                    add(m.range(at: 3), image: m.range(at: 1).length > 0, whole: m.range, altEmpty: alt.isEmpty)
                }
            }
            if s.range(of: "]:").location != NSNotFound {
                for m in RulesHintProvider.matches(refDefinition, str) { add(m.range(at: 1), image: false, whole: m.range) }
            }
            if s.range(of: "<").location != NSNotFound {
                for m in RulesHintProvider.matches(htmlLink, str) {
                    let r = m.range(at: 3).location != NSNotFound ? m.range(at: 3) : m.range(at: 4)
                    add(r, image: s.substring(with: m.range(at: 1)).lowercased() != "a", whole: m.range)
                }
            }
            return out.sorted { $0.whole.location < $1.whole.location }
        }
    }

    /// Templating that may write the link or the heading at build time.
    static func templated(_ s: String) -> Bool {
        s.contains("{{") || s.contains("{%") || s.contains("<%") || s.contains("${")
    }

    // MARK: MD2 A link to a #heading that doesn't exist

    static let atxHeading = try! NSRegularExpression(pattern: #"^ {0,3}(?:>\s*)*#{1,6}(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$"#)
    static let explicitID = try! NSRegularExpression(pattern: #"(?i)(?:\b(?:id|name)\s*=\s*["']?([^"'\s>]+)|\{\s*#([\w:.-]+)[^}]*\}|\{\s*:\s*#([\w-]+))"#)
    static let inlineMarkup = try! NSRegularExpression(pattern: #"!?\[([^\]]*)\]\([^)]*\)|<[^>]+>|[*_`~]"#)

    /// A heading's text as the anchor is made from it: links become their
    /// text, tags and emphasis markers go.
    static func plainHeading(_ t: String) -> String {
        inlineMarkup.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: "$1")
    }

    /// Only letters and digits, lower case: anchors as GitHub, GitLab,
    /// VS Code, kramdown and Hugo make them all reduce to this.
    static func loose(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// The anchors the document defines: its headings' slugs (GitHub's,
    /// with -1, -2 for repeats) and explicit ids (`id=`, `name=`, `{#id}`).
    static func anchors(_ input: LintInput) -> (exact: Set<String>, loose: Set<String>, slugs: [String]) {
        let s = input.text, st = input.markdownStructure
        var exact: Set<String> = [], looseSet: Set<String> = [], slugs: [String] = [], seen: [String: Int] = [:]
        func addHeading(_ text: String) {
            let plain = plainHeading(text)
            let base = Markdown.slug(plain).replacingOccurrences(of: "&amp;", with: "").replacingOccurrences(of: "&lt;", with: "")
                .replacingOccurrences(of: "&gt;", with: "").replacingOccurrences(of: "&quot;", with: "")
            let n = seen[base, default: 0]
            seen[base] = n + 1
            let slug = n == 0 ? base : "\(base)-\(n)"
            exact.insert(slug)
            slugs.append(slug)
            looseSet.insert(loose(plain))
            if n > 0 { looseSet.insert(loose(plain) + "\(n)") }
        }
        for (k, r) in input.lines.enumerated() where !st.isSkipped(r.location) {
            let line = s.substring(with: r)
            if line.contains("#"), let m = atxHeading.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                addHeading(m.range(at: 1).location == NSNotFound ? "" : (line as NSString).substring(with: m.range(at: 1)))
            } else if k + 1 < input.lines.count, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                // Setext: a line underlined with === or ---.
                let next = s.substring(with: input.lines[k + 1]).trimmingCharacters(in: .whitespaces)
                if next.count >= 1, next.allSatisfy({ $0 == "=" }) || (next.count >= 2 && next.allSatisfy({ $0 == "-" })) {
                    addHeading(line.trimmingCharacters(in: .whitespaces))
                }
            }
            if line.contains("id") || line.contains("name") || line.contains("{") {
                for m in RulesHintProvider.matches(explicitID, line) {
                    for g in 1...3 where m.range(at: g).location != NSNotFound {
                        let id = (line as NSString).substring(with: m.range(at: g))
                        exact.insert(id)
                        looseSet.insert(loose(id))
                    }
                }
            }
        }
        return (exact, looseSet, slugs)
    }

    static let allContributorsKeys: Set<String> = ["a11y", "audio", "blog", "bug", "business", "code", "content", "data", "design", "doc",
                                                   "eventorganizing", "example", "financial", "fundingfinding", "ideas", "infra", "maintenance",
                                                   "mentoring", "platform", "plugin", "projectmanagement", "promotion", "question", "research",
                                                   "review", "security", "talk", "test", "tool", "translation", "tutorial", "usertesting", "video"]

    static let brokenAnchor = LintRule(anchorID, wholeDocument: true, applies: markdown) { input in
        let s = input.text
        guard s.range(of: "#").location != NSNotFound, !templated(input.string) else { return nil }
        let links = links(input).filter { $0.target.length > 1 && s.character(at: $0.target.location) == 35 }
        guard !links.isEmpty else { return nil }
        let a = anchors(input)
        // No headings and no ids: the anchors come from somewhere else (a
        // generated table of contents, a site theme).
        guard !a.slugs.isEmpty else { return nil }
        var hits: [(NSRange, String?, String)] = []
        for l in links {
            let frag = s.substring(with: NSRange(location: l.target.location + 1, length: l.target.length - 1))
            let decoded = frag.removingPercentEncoding ?? frag
            let low = decoded.lowercased()
            // The top of the page, footnotes, line links: not headings.
            if ["top", "_top"].contains(low) || low.hasPrefix("fn") || low.hasPrefix("user-content-") || low.hasPrefix("l") && low.dropFirst().allSatisfy(\.isNumber) { continue }
            // all-contributors' emoji keys (#code-alice, #doc-bob): anchors nobody defines, by design.
            if let dash = low.firstIndex(of: "-"), allContributorsKeys.contains(String(low[..<dash])) { continue }
            if a.exact.contains(decoded) || a.exact.contains(low) || a.loose.contains(loose(decoded)) { continue }
            // The nearest heading's anchor, when it is close and only one is
            // (a few hits at most: beyond that it's a warning anyway).
            var fix: String?
            if hits.count < 8 {
                let n = low.count
                let near = a.slugs.filter { abs($0.count - n) <= 2 }.map { ($0, JSRules.distance(low, $0)) }.sorted { $0.1 < $1.1 }
                if let best = near.first, best.1 <= 2, near.dropFirst().first.map({ $0.1 > best.1 }) ?? true { fix = best.0 }
            }
            hits.append((NSRange(location: l.target.location + 1, length: l.target.length - 1), fix, frag))
        }
        guard let first = hits.first else { return nil }
        let fixable = hits.allSatisfy { $0.1 != nil }
        let fix = fixable ? RulesHintProvider.spanEdit(s, hits.map { ($0.0, $0.1!) }) : nil
        let name = String(first.2.prefix(24))
        return LintFinding(kind: fixable ? .fix : .warning,
                           title: first.1.map { String(localized: "No heading “#\(name)”. Link to “#\(String($0.prefix(24)))”?") }
                               ?? String(localized: "No heading here makes the link “#\(name)”."),
                           detail: String(localized: "The link jumps to a heading’s anchor, and no heading in this file makes that one (\(input.at(first.0.location))). A renamed heading?\(RulesHintProvider.andMore(hits.count))"),
                           range: fix?.range ?? first.0, replacement: fix?.replacement)
    }

    // MARK: MD3 A relative link or image to a file that doesn't exist

    static let scheme = try! NSRegularExpression(pattern: #"^[A-Za-z][A-Za-z0-9+.-]*:"#)

    /// The path part of a relative link (no #fragment or ?query, decoded),
    /// or nil for anything that isn't a relative file link.
    static func relativePath(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.hasPrefix("#"), !t.hasPrefix("/"), !t.hasPrefix("~"), !t.hasPrefix("\\"),
              scheme.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) == nil,
              !t.contains("{"), !t.contains("$"), !t.contains("%2F"), !t.contains("*") else { return nil }
        if let h = t.firstIndex(where: { $0 == "#" || $0 == "?" }) { t = String(t[..<h]) }
        guard !t.isEmpty else { return nil }
        // GitHub's web pages relative to a file's page (../../issues/new), and
        // generated HTML (rustdoc, Sphinx, Javadoc output): not files here.
        let web = ["issues", "pulls", "pull", "wiki", "blob", "tree", "releases", "actions", "compare", "discussions", "security", "commits", "raw"]
        let comps = t.split(separator: "/")
        if comps.first == "..", let w = comps.first(where: { $0 != ".." && $0 != "." }), web.contains(String(w)) { return nil }
        let ext = (t as NSString).pathExtension.lowercased()
        if ext == "html" || ext == "htm" || ext == "php" || ext == "aspx" { return nil }
        return t.removingPercentEncoding ?? t
    }

    /// Obsidian vaults and Quartz sites find a bare file name anywhere in
    /// the vault: a link without a folder isn't relative to the page there.
    static func resolvesByName(_ probe: OwlFileProbe) -> Bool? {
        var unknown = false
        for up in ["", "../", "../../", "../../../", "../../../../"] {
            for marker in [".obsidian", "quartz.config.ts", "quartz.config.yaml", "quartz.ts"] {
                switch probe.exists(up + marker) {
                case true?: return true
                case nil: unknown = true
                default: break
                }
            }
        }
        return unknown ? nil : false
    }

    static let brokenRelativeLink = LintRule(relativeLinkID, applies: markdown) { input in
        guard let probe = input.facts.fileExists, input.fileName != nil, !templated(input.string) else { return nil }
        let s = input.text
        guard s.range(of: "](").location != NSNotFound || s.range(of: "]:").location != NSNotFound
                || s.range(of: "src").location != NSNotFound || s.range(of: "href").location != NSNotFound else { return nil }
        var hits: [(Link, String)] = []
        for l in links(input) {
            guard let path = relativePath(s.substring(with: l.target)) else { continue }
            // Site generators link page (or page/) to page.md.
            var candidates = [path]
            let ext = (path as NSString).pathExtension.lowercased()
            let stem = path.hasSuffix("/") ? String(path.dropLast()) : (path as NSString).deletingPathExtension
            if ext.isEmpty || path.hasSuffix("/") {
                candidates += [stem + ".md", stem + ".markdown", stem + ".mdx", stem + "/index.md", stem + "/README.md", stem + "/_index.md"]
            }
            var known = true, found = false
            for c in candidates {
                switch probe.exists(c) {
                case true?: found = true
                case nil: known = false
                default: break
                }
                if found { break }
            }
            if !found, known {
                if !path.contains("/") {
                    // A bare name in a vault: found by name anywhere (asked once).
                    let vault = input.shared("md.vault") { resolvesByName(probe) }
                    if vault != false { continue }
                }
                hits.append((l, path))
            }
        }
        guard let first = hits.first else { return nil }
        let name = String(first.1.prefix(32))
        return LintFinding(kind: .warning,
                           title: first.0.image ? String(localized: "No image at “\(name)”.") : String(localized: "No file at “\(name)”."),
                           detail: String(localized: "The link \(input.at(first.0.target.location)) points to a file that isn’t there, relative to this document. Renamed or moved?\(RulesHintProvider.andMore(hits.count))"),
                           range: first.0.target)
    }
}

extension LintInput {
    /// Markdown's fences, code spans and comments, read once per query.
    var markdownStructure: MarkdownRules.Structure { shared("md.structure") { MarkdownRules.structure(text, lines: lines) } }
}
