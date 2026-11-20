import Foundation

/// Pack 5: Markdown. Sources: markdownlint (MD051 link fragments) and
/// CommonMark's fenced code blocks. Links and fences inside code (fenced
/// blocks, inline code spans), HTML comments and front matter are not
/// looked at.
enum MarkdownRules {
    static let fenceID = "rules.md.unclosed-fence"
    static let anchorID = "rules.md.broken-anchor"
    static let relativeLinkID = "rules.md.broken-link"
    static let imageAltID = "rules.md.image-alt"

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
        enum Kind { case inline, reference, html }
        var kind: Kind = .inline
    }

    /// `[text](dest)` / `![alt](dest "title")`, `[label]: dest` and
    /// `<img src="dest">` / `<a href="dest">`, outside code.
    static let inlineLink = try! NSRegularExpression(pattern: #"(!?)\[((?:[^\[\]\n]|\[[^\[\]\n]*\])*)\]\(\s*(<[^<>\n]*>|[^\s()<>]*(?:\([^\s()]*\)[^\s()<>]*)*)(?:\s+(?:"[^"\n]*"|'[^'\n]*'|\([^()\n]*\)))?\s*\)"#)
    /// (Not a footnote's `[^1]: text`: that is a note, not a link.)
    static let refDefinition = try! NSRegularExpression(pattern: #"(?m)^ {0,3}\[(?!\^)[^\]\n]+\]:[ \t]*(<[^<>\n]*>|\S+)"#)
    static let htmlLink = try! NSRegularExpression(pattern: #"(?i)<(img|a|source)\b[^>\n]*?\s(src|href)\s*=\s*(?:"([^"\n]*)"|'([^'\n]*)')"#)

    static func links(_ input: LintInput) -> [Link] {
        input.shared("md.links") {
            let s = input.text, str = input.string
            let st = input.markdownStructure
            var out: [Link] = []
            func add(_ target: NSRange, image: Bool, whole: NSRange, altEmpty: Bool = false, kind: Link.Kind) {
                guard !st.isSkipped(whole.location) else { return }
                var t = target
                // <dest>: without the brackets.
                if t.length >= 2, s.character(at: t.location) == 60, s.character(at: NSMaxRange(t) - 1) == 62 {
                    t = NSRange(location: t.location + 1, length: t.length - 2)
                }
                out.append(Link(target: t, image: image, whole: whole, altEmpty: altEmpty, kind: kind))
            }
            if s.range(of: "](").location != NSNotFound {
                for m in RulesHintProvider.matches(inlineLink, str) {
                    let alt = s.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
                    add(m.range(at: 3), image: m.range(at: 1).length > 0, whole: m.range, altEmpty: alt.isEmpty, kind: .inline)
                }
            }
            if s.range(of: "]:").location != NSNotFound {
                for m in RulesHintProvider.matches(refDefinition, str) { add(m.range(at: 1), image: false, whole: m.range, kind: .reference) }
            }
            if s.range(of: "<").location != NSNotFound {
                for m in RulesHintProvider.matches(htmlLink, str) {
                    let r = m.range(at: 3).location != NSNotFound ? m.range(at: 3) : m.range(at: 4)
                    add(r, image: s.substring(with: m.range(at: 1)).lowercased() != "a", whole: m.range, kind: .html)
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
        guard t.contains(where: { "[<*_`~".contains($0) }) else { return t }
        return inlineMarkup.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: "$1")
    }

    /// Only letters and digits, lower case: anchors as GitHub, GitLab,
    /// VS Code, kramdown and Hugo make them all reduce to this.
    static func loose(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    struct Heading {
        var level: Int
        var line: Int           // index into the lines
        var marks: NSRange?     // the run of #s (nil: an underlined heading)
        var text: String        // as plain text (links as their text, no markup)
        var base: String        // its anchor before -1, -2 for repeats
    }

    /// The headings outside code (`#` lines and underlined ones), with
    /// their GitHub anchors as the preview makes them (`Markdown.slug`).
    static func headings(_ input: LintInput) -> [Heading] {
        input.shared("md.headings") {
            let s = input.text, st = input.markdownStructure
            var out: [Heading] = []
            func add(_ text: String, level: Int, line: Int, marks: NSRange?) {
                let plain = plainHeading(text)
                let base = Markdown.slug(plain).replacingOccurrences(of: "&amp;", with: "").replacingOccurrences(of: "&lt;", with: "")
                    .replacingOccurrences(of: "&gt;", with: "").replacingOccurrences(of: "&quot;", with: "")
                out.append(Heading(level: level, line: line, marks: marks, text: plain, base: base))
            }
            /// The first character after up to three spaces (unichar), or 0.
            func lead(_ r: NSRange) -> unichar {
                var i = r.location
                while i < NSMaxRange(r), i - r.location < 4, s.character(at: i) == 32 { i += 1 }
                return i < NSMaxRange(r) ? s.character(at: i) : 0
            }
            for (k, r) in input.lines.enumerated() where r.length > 0 && !st.isSkipped(r.location) {
                let c = lead(r)
                // Only # (or a quote's >) can start a # heading; only a
                // line followed by === or --- is an underlined one.
                let atx = c == 35 || c == 62 && s.range(of: "#", options: [], range: r).location != NSNotFound
                let under = k + 1 < input.lines.count && { let n = lead(input.lines[k + 1]); return n == 61 || n == 45 }()
                guard atx || under else { continue }
                let line = s.substring(with: r)
                if atx, let m = atxHeading.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                    let l = line as NSString
                    var i = 0
                    while i < l.length, l.character(at: i) != 35 { i += 1 }
                    var n = 0
                    while i + n < l.length, l.character(at: i + n) == 35 { n += 1 }
                    add(m.range(at: 1).location == NSNotFound ? "" : l.substring(with: m.range(at: 1)), level: n, line: k,
                        marks: NSRange(location: r.location + i, length: n))
                } else if under, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    // Setext: a line underlined with === or ---.
                    let next = s.substring(with: input.lines[k + 1]).trimmingCharacters(in: .whitespaces)
                    if next.count >= 1, next.allSatisfy({ $0 == "=" }) || (next.count >= 2 && next.allSatisfy({ $0 == "-" })) {
                        add(line.trimmingCharacters(in: .whitespaces), level: next.first == "=" ? 1 : 2, line: k, marks: nil)
                    }
                }
            }
            return out
        }
    }

    /// The anchors the document defines: its headings' slugs (GitHub's,
    /// with -1, -2 for repeats) and explicit ids (`id=`, `name=`, `{#id}`).
    static func anchors(_ input: LintInput) -> (exact: Set<String>, loose: Set<String>, slugs: [String]) {
        let s = input.text, st = input.markdownStructure
        var exact: Set<String> = [], looseSet: Set<String> = [], slugs: [String] = [], seen: [String: Int] = [:]
        for h in headings(input) {
            let n = seen[h.base, default: 0]
            seen[h.base] = n + 1
            let slug = n == 0 ? h.base : "\(h.base)-\(n)"
            exact.insert(slug)
            slugs.append(slug)
            looseSet.insert(loose(h.text))
            if n > 0 { looseSet.insert(loose(h.text) + "\(n)") }
        }
        for r in input.lines where !st.isSkipped(r.location) {
            let line = s.substring(with: r)
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
        var listed = false
        for l in links(input) {
            guard let path = relativePath(s.substring(with: l.target)) else { continue }
            // Start the folder's listing with the first look-up, so the
            // query that knows a file is missing also knows its neighbours.
            if !listed { listed = true; _ = probe.files?() }
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
        // Fix it: each missing file's one clear nearest match in the
        // document's folder tree (listed off the main thread; nil until then).
        var fix: (range: NSRange, replacement: String)?
        var firstTo: String?
        if let list = probe.files {
            // The listing isn't there yet: wait for the query that has it.
            guard let files = list() else { return nil }
            var nearest: [String: String?] = [:]
            var edits: [(NSRange, String)] = []
            for (l, path) in hits where !files.isEmpty {
                let to: String?
                if let known = nearest[path] { to = known } else if nearest.count < 8 {
                    to = nearestFile(path, in: input)
                    nearest[path] = .some(to)
                } else { to = nil }
                guard let to else { edits = []; break }
                let angle = l.target.location > 0 && s.character(at: l.target.location - 1) == 60
                edits.append((l.target, rewrite(s.substring(with: l.target), to: to, encode: l.kind != .html && !angle)))
            }
            if !edits.isEmpty, let e = RulesHintProvider.spanEdit(s, edits) {
                fix = e
                firstTo = nearest[first.1] ?? nil
            }
        }
        let title: String
        if let to = firstTo {
            let missing = String((first.1 as NSString).lastPathComponent.prefix(16))
            let shown = to.count > 22 ? "…" + to.suffix(21) : to
            title = first.0.image ? String(localized: "No image “\(missing)”. Use “\(shown)”?")
                : String(localized: "No file “\(missing)”. Link to “\(shown)”?")
        } else {
            title = first.0.image ? String(localized: "No image at “\(name)”.") : String(localized: "No file at “\(name)”.")
        }
        return LintFinding(kind: fix == nil ? .warning : .fix, title: title,
                           detail: String(localized: "The link \(input.at(first.0.target.location)) points to a file that isn’t there, relative to this document. Renamed or moved?\(RulesHintProvider.andMore(hits.count))"),
                           range: fix?.range ?? first.0.target, replacement: fix?.replacement)
    }

    /// The file a broken relative link most likely meant: among the
    /// Markdown or image files under the document's folder (the probe's
    /// list), the same name elsewhere, or else the closest name (a few
    /// letters off; another image extension counts one), ties broken by
    /// the closest path. Nil unless exactly one is clearly best.
    static func nearestFile(_ path: String, in input: LintInput) -> String? {
        guard let probe = input.facts.fileExists, let files = probe.files?() else { return nil }
        let index = input.shared("md.file-index") { FileIndexCache.shared.index(probe.id, files) }
        return nearestFile(path, index: index)
    }

    typealias FileIndex = [(path: String, lower: String, stem: String, ext: String)]

    /// The last listing's lower-cased names, kept between queries: the
    /// listing changes at most every 2 min, the queries come every 30 s.
    final class FileIndexCache: @unchecked Sendable {
        static let shared = FileIndexCache()
        private let lock = NSLock()
        private var key: (UUID, Int, String?, String?)?
        private var index: FileIndex = []

        func index(_ probe: UUID, _ files: [String]) -> FileIndex {
            lock.lock()
            defer { lock.unlock() }
            if let k = key, k.0 == probe, k.1 == files.count, k.2 == files.first, k.3 == files.last { return index }
            index = files.map { f in
                let lower = f.lowercased()
                let name = (lower as NSString).lastPathComponent as NSString
                return (f, lower, name.deletingPathExtension, name.pathExtension)
            }
            key = (probe, files.count, files.first, files.last)
            return index
        }
    }

    static func extGroup(_ ext: String) -> Int? {
        if OwlFileProbe.markdownExtensions.contains(ext) { return 0 }
        if ext == "pdf" { return 2 }
        return OwlFileProbe.imageExtensions.contains(ext) ? 1 : nil
    }

    static func nearestFile(_ path: String, index: FileIndex) -> String? {
        // The link's path inside the document's folder (none above it).
        var comps: [Substring] = []
        for c in path.split(separator: "/") {
            if c == "." { continue }
            if c == ".." { guard !comps.isEmpty else { return nil }; comps.removeLast() } else { comps.append(c) }
        }
        guard let last = comps.last else { return nil }
        let target = comps.joined(separator: "/").lowercased()
        let name = last.lowercased() as NSString
        let stem = name.deletingPathExtension, ext = name.pathExtension
        guard let group = extGroup(ext), !stem.isEmpty else { return nil }
        let n = stem.utf16.count
        let limit = n <= 3 ? 1 : n <= 8 ? 2 : 3
        var ranked: [(name: Int, path: Int, file: String)] = []
        for f in index where f.lower != target && abs(f.stem.utf16.count - n) <= limit && extGroup(f.ext) == group {
            let d = (f.stem == stem ? 0 : JSRules.distance(stem, f.stem)) + (f.ext == ext ? 0 : 1)
            guard d <= limit else { continue }
            ranked.append((d, JSRules.distance(target, f.lower), f.path))
        }
        ranked.sort { ($0.name, $0.path) < ($1.name, $1.path) }
        guard let best = ranked.first else { return nil }
        // One clear best: nothing as close by name and nearly as close by path.
        if let second = ranked.dropFirst().first, second.name == best.name, second.path - best.path < 2 { return nil }
        return best.file
    }

    /// The link's destination with its path swapped for `to` (relative to
    /// the document); a #fragment or ?query and a leading ./ are kept, and
    /// the path is percent-encoded when the old one was or a space needs it.
    static func rewrite(_ raw: String, to: String, encode: Bool) -> String {
        let cut = raw.firstIndex { $0 == "#" || $0 == "?" } ?? raw.endIndex
        let old = raw[..<cut], suffix = raw[cut...]
        var path = to
        if old.hasPrefix("./"), !path.hasPrefix("./") { path = "./" + path }
        if old.contains("%") || encode && path.contains(where: { $0 == " " || $0 == "<" || $0 == ">" }) {
            path = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        }
        return path + suffix
    }

    // MARK: Style: an image without alt text (MD045)

    static let imageWithoutAlt = LintRule(imageAltID, tier: .style, applies: markdown) { input in
        guard input.text.range(of: "![](").location != NSNotFound || input.text.range(of: "![ ](").location != NSNotFound else { return nil }
        let hits = links(input).filter { $0.image && $0.altEmpty && input.text.character(at: $0.whole.location) == 33 }
        guard let first = hits.first else { return nil }
        // Fix: the file name as the alt text ("logo" for img/logo.png) is a start.
        let path = input.text.substring(with: first.target)
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            .replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        let open = NSRange(location: first.whole.location, length: 4)   // ![](
        let ok = !base.isEmpty && input.text.substring(with: open) == "![]("
        return LintFinding(kind: ok ? .fix : .tip, title: String(localized: "An image without alt text. Describe it?"),
                           detail: String(localized: "Screen readers read the alt text out, and it shows when the image doesn’t load.\(RulesHintProvider.andMore(hits.count))"),
                           range: ok ? open : first.whole, replacement: ok ? "![\(base)](" : nil)
    }
}

extension LintInput {
    /// Markdown's fences, code spans and comments, read once per query.
    var markdownStructure: MarkdownRules.Structure { shared("md.structure") { MarkdownRules.structure(text, lines: lines) } }
}
