import Foundation

/// Smart paste in Markdown: a URL pasted over a selection becomes a link,
/// and pasted or dropped images become `![](images/name.png)` (the app
/// copies the file next to the document; these are the pure parts).
public enum MarkdownPaste {
    /// Image files that a Markdown preview shows.
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "heif", "tif", "tiff", "bmp", "avif", "ico"]

    public static func isImageFile(_ url: URL) -> Bool { imageExtensions.contains(url.pathExtension.lowercased()) }

    /// A URL pasted over a one-line selection of text that isn't a URL
    /// itself: `[selection](url)`, caret after it. Nil otherwise, and in
    /// a code span (the caller skips fenced code).
    public static func linkPaste(in text: NSString, selection sel: NSRange, pasted: String) -> TextEdit? {
        guard sel.length > 0, sel.length <= 4096, NSMaxRange(sel) <= text.length, MarkdownFormat.isURL(pasted) else { return nil }
        let selected = text.substring(with: sel)
        guard selected.rangeOfCharacter(from: .newlines) == nil, !MarkdownFormat.isURL(selected),
              !inCodeSpan(text, at: sel.location) else { return nil }
        let s = "[\(selected)](\(pasted.trimmingCharacters(in: .whitespacesAndNewlines)))"
        return TextEdit(range: sel, replacement: s, selection: NSRange(location: sel.location + (s as NSString).length, length: 0))
    }

    /// Whether `offset` is inside a `code span` on its line (an odd number
    /// of backtick runs before it; at most 4096 characters back).
    public static func inCodeSpan(_ text: NSString, at offset: Int) -> Bool {
        let line = text.lineRange(for: NSRange(location: min(offset, text.length), length: 0))
        var i = max(line.location, offset - 4096)
        var open = 0
        while i < offset {
            if text.character(at: i) == 96 {
                var n = 0
                while i + n < offset, text.character(at: i + n) == 96 { n += 1 }
                if open == 0 { open = n } else if open == n { open = 0 }
                i += n
            } else {
                i += 1
            }
        }
        return open != 0
    }

    /// `file`'s path relative to `dir` when it's inside it (any depth),
    /// percent-encoded for a Markdown link (spaces as %20); nil otherwise.
    public static func relativePath(of file: URL, from dir: URL) -> String? {
        let f = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let d = dir.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard f.count > d.count, Array(f.prefix(d.count)) == d else { return nil }
        return encode(f.dropFirst(d.count).joined(separator: "/"))
    }

    static func encode(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "()[]<> ")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    /// `name`, or "name-2.ext", "name-3.ext"… : the first that `exists`
    /// says is free.
    public static func uniqueName(_ name: String, exists: (String) -> Bool) -> String {
        guard exists(name) else { return name }
        let ns = name as NSString
        let base = ns.deletingPathExtension, ext = ns.pathExtension
        var k = 2
        while true {
            let candidate = ext.isEmpty ? "\(base)-\(k)" : "\(base)-\(k).\(ext)"
            if !exists(candidate) { return candidate }
            k += 1
        }
    }

    /// The image links for `paths` (already relative and encoded), one
    /// per line.
    public static func imageLinks(_ paths: [String]) -> String { paths.map { "![](\($0))" }.joined(separator: "\n") }
}
