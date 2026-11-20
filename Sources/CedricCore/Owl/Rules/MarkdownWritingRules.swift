import Foundation

/// 0.4.0's writing checks for Markdown (offline, no AI): a skipped heading
/// level, a duplicate heading whose anchor is ambiguous, footnotes without
/// a note or a reference, and an empty link. Like the rest of the pack they
/// read the text outside code (fenced blocks, code spans, HTML comments,
/// front matter) through `MarkdownRules.structure`, once per query.
extension MarkdownRules {
    static let headingSkipID = "rules.md.heading-skip"
    static let duplicateHeadingID = "rules.md.duplicate-heading"
    static let footnoteID = "rules.md.footnote"
    static let emptyLinkID = "rules.md.empty-link"

    // MARK: A skipped heading level (markdownlint MD001)

    /// `##` then `####`: Fix it takes the heading (and the ones under it)
    /// up to the next level, keeping the outline's shape. A window of a
    /// longer file is checked too (consecutive headings in it are
    /// consecutive in the file), unless it may start or end inside a fence.
    static let headingSkip = LintRule(headingSkipID, applies: markdown) { input in
        guard input.text.range(of: "###").location != NSNotFound else { return nil }
        if !input.whole, input.markdownStructure.unclosed != nil { return nil }
        let hs = headings(input)
        guard hs.count >= 2 else { return nil }
        // Each heading's new level: one below its parent's new level, at most.
        var stack: [(level: Int, new: Int)] = []
        var edits: [(NSRange, String)] = []
        var first: (heading: Heading, parent: Int, new: Int)?
        for h in hs {
            while let top = stack.last, top.level >= h.level { stack.removeLast() }
            let parent = stack.last
            let new = parent.map { min(h.level, $0.new + 1) } ?? h.level
            if new != h.level, let marks = h.marks, let parent {
                edits.append((marks, String(repeating: "#", count: new)))
                if first == nil { first = (h, parent.level, new) }
            }
            stack.append((h.level, new))
        }
        guard let first, let fix = RulesHintProvider.spanEdit(input.text, edits) else { return nil }
        let from = first.parent, to = first.heading.level, new = first.new
        let at = input.lines[first.heading.line].location
        return LintFinding(kind: .fix, title: String(localized: "This heading jumps from H\(from) to H\(to). Make it H\(new)?"),
                           detail: String(localized: "Outlines and screen readers expect one level at a time; H\(from + 1) is skipped \(input.at(at)). The headings under it move up with it.\(RulesHintProvider.andMore(edits.count))"),
                           range: fix.range, replacement: fix.replacement)
    }

    // MARK: A duplicate heading (an ambiguous anchor)

    /// Two headings with the same anchor under the same parent, or any two
    /// with an anchor a link in the file uses: `#setup` only ever reaches
    /// the first. A hint with Show Me; renaming is the writer's call.
    static let duplicateHeading = LintRule(duplicateHeadingID, wholeDocument: true, applies: markdown) { input in
        let hs = headings(input)
        guard hs.count >= 2 else { return nil }
        let s = input.text
        var linked: Set<String> = []
        if s.range(of: "](#").location != NSNotFound || s.range(of: "]: #").location != NSNotFound {
            for l in links(input) where l.target.length > 1 && s.character(at: l.target.location) == 35 {
                let frag = s.substring(with: NSRange(location: l.target.location + 1, length: l.target.length - 1))
                linked.insert((frag.removingPercentEncoding ?? frag).lowercased())
            }
        }
        var stack: [Int] = []
        var siblings: [String: Int] = [:], firstWith: [String: Int] = [:]
        var hits: [(first: Int, second: Int)] = []
        for (i, h) in hs.enumerated() {
            while let top = stack.last, hs[top].level >= h.level { stack.removeLast() }
            defer { stack.append(i) }
            guard !h.base.isEmpty else { continue }
            let key = "\(stack.last ?? -1) \(h.level) \(h.base)"
            if let f = siblings[key] { hits.append((f, i)) } else { siblings[key] = i }
            if let f = firstWith[h.base] {
                if linked.contains(h.base), hits.last?.second != i { hits.append((f, i)) }
            } else { firstWith[h.base] = i }
        }
        guard let hit = hits.first else { return nil }
        let a = hs[hit.first], b = hs[hit.second]
        let name = String(b.text.trimmingCharacters(in: .whitespaces).prefix(24))
        let anchor = String(b.base.prefix(24))
        let repeatNumber = hs[..<hit.second].filter { $0.base == b.base }.count
        return LintFinding(kind: .tip, title: String(localized: "Two headings “\(name)” share one anchor."),
                           detail: String(localized: "A link to #\(anchor) always goes to the first one (line \(a.line + 1)); this one is #\(anchor)-\(repeatNumber). Rename one to tell them apart?\(RulesHintProvider.andMore(hits.count))"),
                           range: input.lines[b.line])
    }

    // MARK: Footnotes without a note, or never used

    static let footnoteReference = try! NSRegularExpression(pattern: #"\[\^([^\]\s\[]+)\]"#)
    static let footnoteDefinition = try! NSRegularExpression(pattern: #"(?m)^ {0,3}\[\^([^\]\s\[]+)\]:"#)

    /// `[^2]` with no `[^2]: …` (it shows as plain text), or a `[^3]: …`
    /// nothing refers to (the preview and export leave it out). Labels
    /// match without case. With no notes in the file at all, only numbered
    /// references count: `[^a-z]` in prose about regular expressions isn't one.
    static let footnote = LintRule(footnoteID, wholeDocument: true, applies: markdown) { input in
        let s = input.text, str = input.string
        guard s.range(of: "[^").location != NSNotFound else { return nil }
        let st = input.markdownStructure
        var defs: [String: NSRange] = [:], defAt: Set<Int> = []
        for m in RulesHintProvider.matches(footnoteDefinition, str) {
            let open = m.range.location + (s.substring(with: m.range) as NSString).range(of: "[").location
            guard !st.isSkipped(open) else { continue }
            defAt.insert(open)
            let key = Markdown.normalizeLabel(s.substring(with: m.range(at: 1)))
            if defs[key] == nil { defs[key] = NSRange(location: open, length: m.range(at: 1).length + 3) }
        }
        var used: Set<String> = []
        var missing: [(NSRange, String)] = []
        for m in RulesHintProvider.matches(footnoteReference, str) where !defAt.contains(m.range.location) && !st.isSkipped(m.range.location) {
            let label = s.substring(with: m.range(at: 1))
            // An inline link whose text starts with ^ is a link.
            if NSMaxRange(m.range) < s.length, s.character(at: NSMaxRange(m.range)) == 40 { continue }
            let key = Markdown.normalizeLabel(label)
            used.insert(key)
            if defs[key] == nil, !defs.isEmpty || label.allSatisfy(\.isNumber) { missing.append((m.range, label)) }
        }
        let unused = defs.filter { !used.contains($0.key) }.map { ($0.value, s.substring(with: NSRange(location: $0.value.location + 2, length: $0.value.length - 3))) }
        let all = (missing.map { ($0.0, $0.1, true) } + unused.map { ($0.0, $0.1, false) }).sorted { $0.0.location < $1.0.location }
        guard let first = all.first else { return nil }
        let label = String(first.1.prefix(20))
        let more = RulesHintProvider.andMore(all.count)
        if first.2 {
            return LintFinding(kind: .warning, title: String(localized: "Footnote [^\(label)] has no note."),
                               detail: String(localized: "Nothing in the file starts with “[^\(label)]:”, so it shows as plain text \(input.at(first.0.location)). Add the note, or check the label’s spelling.\(more)"),
                               range: first.0)
        }
        return LintFinding(kind: .warning, title: String(localized: "The note [^\(label)] is never used."),
                           detail: String(localized: "No [^\(label)] in the text refers to it, so the preview and export leave it out \(input.at(first.0.location)).\(more)"),
                           range: first.0)
    }

    // MARK: An empty link

    /// `[text]()` (clicking it goes nowhere) or `[](url)` (nothing to click).
    /// An image with no alt text is the style tip's (`rules.md.image-alt`).
    static let emptyLink = LintRule(emptyLinkID, applies: markdown) { input in
        let s = input.text
        guard s.range(of: "]()").location != NSNotFound || s.range(of: "](<>)").location != NSNotFound
                || s.range(of: "[](").location != NSNotFound || s.range(of: "[ ](").location != NSNotFound else { return nil }
        guard !templated(input.string) else { return nil }
        let hits = links(input).filter { l in
            guard l.kind == .inline else { return false }
            if l.target.length == 0 { return true }
            // [](url); not ![](img).
            return !l.image && l.altEmpty
        }
        guard let first = hits.first else { return nil }
        let at = input.at(first.whole.location), more = RulesHintProvider.andMore(hits.count)
        if first.target.length == 0 {
            return LintFinding(kind: .warning,
                               title: first.image ? String(localized: "This image has no address.") : String(localized: "This link has no address."),
                               detail: String(localized: "There is nothing between its ( ), so it leads nowhere \(at). Put the address or the file’s path there.\(more)"),
                               range: first.whole)
        }
        let url = String(s.substring(with: first.target).prefix(40))
        return LintFinding(kind: .warning, title: String(localized: "This link has no text to click."),
                           detail: String(localized: "It goes to \(url), but its [ ] is empty, so nothing shows on the page \(at). Write its words between the [ ].\(more)"),
                           range: first.whole)
    }
}
