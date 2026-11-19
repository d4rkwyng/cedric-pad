import Foundation

/// Find TODOs: the TODO, FIXME, HACK and XXX notes of a file, with their
/// lines, for a list to jump from. On demand only (never a passive hint).
/// In code the owl lexes (CodeMask) only comments count, so a "TODO" in a
/// string or an identifier isn't one; elsewhere the tag must follow a
/// comment marker (`#`, `//`, `--`, `;`, `<!--`, `/*`, `*`) or, in prose,
/// start a line or follow a list marker.
public enum Todos {
    public struct Item: Sendable, Equatable {
        public var line: Int          // 1-based
        public var tag: String        // TODO, FIXME, HACK, XXX
        public var text: String       // the note, trimmed (at most 160 characters)
        public var range: NSRange     // the tag in the text
    }

    static let tag = try! NSRegularExpression(pattern: #"\b(TODO|FIXME|HACK|XXX)\b(?:\([^)\n]{0,40}\))?:?"#)
    static let commentLead = try! NSRegularExpression(pattern: #"(#|//|--|;|<!--|/\*|^\s*\*|^\s*[-*+]\s|^\s*\d+[.)]\s|^\s*)\s*$"#)

    public static let limit = 1000

    public static func find(_ text: String, language: String) -> [Item] {
        let ns = text as NSString
        guard ns.range(of: "TODO").location != NSNotFound || ns.range(of: "FIXME").location != NSNotFound
                || ns.range(of: "HACK").location != NSNotFound || ns.range(of: "XXX").location != NSNotFound else { return [] }
        let mask = CodeMask.make(ns, language: language)
        let prose = ["plain", "markdown"].contains(language)
        var out: [Item] = []
        var lineNo = 1, lineStart = 0, scanned = 0
        tag.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, stop in
            guard let m else { return }
            let r = m.range(at: 1)
            // Line number: count newlines since the last match.
            while scanned < r.location {
                if ns.character(at: scanned) == 10 { lineNo += 1; lineStart = scanned + 1 }
                scanned += 1
            }
            if let mask {
                guard let sp = mask.span(at: r.location), sp.kind == .comment else { return }
            } else {
                let before = ns.substring(with: NSRange(location: lineStart, length: r.location - lineStart))
                let lead = commentLead.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length))
                guard lead != nil, prose || !(lead!.range(at: 1).length == 0 && !before.trimmingCharacters(in: .whitespaces).isEmpty) else { return }
                if !prose, before.trimmingCharacters(in: .whitespaces).isEmpty, !["yaml", "ini", "sql", "ruby", "html", "xml", "batch"].contains(language) {
                    // A tag at the start of a line of code isn't a comment.
                    return
                }
            }
            let lineEnd = ns.lineRange(for: NSRange(location: r.location, length: 0))
            var note = ns.substring(with: NSRange(location: NSMaxRange(m.range), length: NSMaxRange(lineEnd) - NSMaxRange(m.range)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            for close in ["-->", "*/"] where note.hasSuffix(close) { note = String(note.dropLast(close.count)).trimmingCharacters(in: .whitespaces) }
            out.append(Item(line: lineNo, tag: ns.substring(with: r), text: String(note.prefix(160)), range: r))
            if out.count >= limit { stop.pointee = true }
        }
        return out
    }
}
