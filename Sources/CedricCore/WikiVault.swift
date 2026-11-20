import Foundation

/// Resolves Obsidian `[[wikilinks]]` and `![[embeds]]` for the preview, as
/// Obsidian does: by file name anywhere under the vault, the shortest path
/// winning, `.md` implied for notes. The vault is the opened folder, else
/// the nearest folder above the document holding `.obsidian/`, else the
/// document's own folder. Files only; the name index is built once per
/// `refreshSeconds` (bounded: `maxEntries` entries, `maxDepth` levels,
/// dot folders and `node_modules` skipped).
public final class WikiVault: @unchecked Sendable {
    public let documentFolder: URL
    public let root: URL
    public static let maxEntries = 20_000
    public static let maxDepth = 10
    public static let refreshSeconds: TimeInterval = 15
    /// The most a transcluded note may be (bytes); larger ones stay a link.
    public static let maxEmbedBytes = 256 * 1024

    private let fm: FileManager
    private let lock = NSLock()
    private var index: [String: [URL]] = [:]
    private var built: Date?

    public init(documentFolder: URL, openedRoot: URL? = nil, fileManager: FileManager = .default) {
        self.fm = fileManager
        self.documentFolder = documentFolder.standardizedFileURL
        self.root = (openedRoot ?? Self.obsidianRoot(above: documentFolder, fileManager: fileManager) ?? documentFolder).standardizedFileURL
    }

    /// The nearest folder at or above `folder` that holds `.obsidian/`.
    public static func obsidianRoot(above folder: URL, fileManager fm: FileManager = .default) -> URL? {
        var dir = folder.standardizedFileURL
        for _ in 0..<PreviewRoot.maxLevels {
            guard dir.pathComponents.count >= 3 else { return nil }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir.appendingPathComponent(".obsidian").path, isDirectory: &isDir), isDir.boolValue { return dir }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// A `[[target]]`'s parts: the file part and the `#Heading` or `#^block` part.
    public static func split(_ target: String) -> (name: String, fragment: String?) {
        guard let hash = target.firstIndex(of: "#") else { return (target.trimmingCharacters(in: .whitespaces), nil) }
        let frag = String(target[target.index(after: hash)...]).trimmingCharacters(in: .whitespaces)
        return (String(target[..<hash]).trimmingCharacters(in: .whitespaces), frag.isEmpty ? nil : frag)
    }

    /// The file a link names (`name` without its `#…`), or nil.
    public func resolve(_ name: String) -> URL? {
        var n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !n.contains("\0") else { return nil }
        if n.hasPrefix("/") { n.removeFirst() }
        let parts = n.split(separator: "/").map(String.init)
        guard !parts.contains(".."), !parts.isEmpty else { return nil }
        let hasExt = !(n as NSString).pathExtension.isEmpty
        let names = hasExt ? [n, n + ".md"] : [n + ".md", n]
        // A path: relative to the document, then to the vault.
        if parts.count > 1 {
            for base in [documentFolder, root] {
                for t in names {
                    let f = base.appendingPathComponent(t).standardizedFileURL
                    if isFile(f) { return f }
                }
            }
        }
        // A name: the document's own folder first, then anywhere in the vault.
        for t in names where parts.count == 1 {
            let f = documentFolder.appendingPathComponent(t)
            if isFile(f) { return f }
        }
        let idx = currentIndex()
        for t in names {
            let key = (t as NSString).lastPathComponent.lowercased()
            guard var hits = idx[key] else { continue }
            if parts.count > 1 {
                let suffix = "/" + t.lowercased()
                hits = hits.filter { $0.path.lowercased().hasSuffix(suffix) }
            }
            if let best = hits.min(by: { ($0.pathComponents.count, $0.path) < ($1.pathComponents.count, $1.path) }) { return best }
        }
        return nil
    }

    private func isFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
    }

    private func currentIndex() -> [String: [URL]] {
        lock.lock(); defer { lock.unlock() }
        if let built, Date().timeIntervalSince(built) < Self.refreshSeconds { return index }
        index = Self.buildIndex(root, fm)
        built = Date()
        return index
    }

    static func buildIndex(_ root: URL, _ fm: FileManager) -> [String: [URL]] {
        var idx: [String: [URL]] = [:]
        var count = 0
        var queue: [(URL, Int)] = [(root, 0)]
        let keys: [URLResourceKey] = [.isDirectoryKey]
        while !queue.isEmpty, count < maxEntries {
            let (dir, depth) = queue.removeFirst()
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { continue }
            for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                count += 1
                if count >= maxEntries { break }
                let name = item.lastPathComponent
                if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    if depth + 1 < maxDepth, name != "node_modules" { queue.append((item, depth + 1)) }
                } else {
                    idx[name.lowercased(), default: []].append(item.standardizedFileURL)
                }
            }
        }
        return idx
    }

    /// The text of a note to transclude, or the part a `#Heading` or
    /// `#^block` names (the whole note when that part isn't found).
    public func embedText(_ file: URL, fragment: String?) -> String? {
        guard let attrs = try? fm.attributesOfItem(atPath: file.path), let size = attrs[.size] as? Int, size <= Self.maxEmbedBytes,
              let data = fm.contents(atPath: file.path), let text = String(data: data, encoding: .utf8) else { return nil }
        return Self.section(of: text, fragment: fragment)
    }

    /// The lines under heading `fragment` (to the next heading of its level
    /// or higher), or the paragraph ending in `^block`; else the whole text
    /// without its frontmatter.
    public static func section(of text: String, fragment: String?) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") { lines.removeSubrange(0...end) }
        guard let fragment else { return lines.joined(separator: "\n") }
        if fragment.hasPrefix("^") {
            let id = fragment
            guard let k = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasSuffix(" " + id) || $0.trimmingCharacters(in: .whitespaces) == id }) else {
                return lines.joined(separator: "\n")
            }
            var start = k
            while start > 0, !lines[start - 1].trimmingCharacters(in: .whitespaces).isEmpty { start -= 1 }
            let block = lines[start...k].map { l -> String in
                let t = l.trimmingCharacters(in: .whitespaces)
                return t.hasSuffix(id) ? String(t.dropLast(id.count)).trimmingCharacters(in: .whitespaces) : l
            }
            return block.joined(separator: "\n")
        }
        func heading(_ l: String) -> (Int, String)? {
            let t = l.trimmingCharacters(in: .whitespaces)
            let level = t.prefix(while: { $0 == "#" }).count
            guard (1...6).contains(level), t.dropFirst(level).first == " " else { return nil }
            return (level, t.dropFirst(level).trimmingCharacters(in: .whitespaces))
        }
        let want = fragment.lowercased()
        guard let k = lines.firstIndex(where: { heading($0).map { $0.1.lowercased() == want } ?? false }), let (level, _) = heading(lines[k]) else {
            return lines.joined(separator: "\n")
        }
        var end = k + 1
        while end < lines.count {
            if let (l, _) = heading(lines[end]), l <= level { break }
            end += 1
        }
        return lines[k..<end].joined(separator: "\n")
    }

    /// The `cedric-doc:` link for a resolved file.
    public static func href(_ file: URL) -> String? { PreviewFolder.pageURL(forFile: file)?.absoluteString }

    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "avif", "heic", "heif", "bmp", "svg", "tif", "tiff", "ico"]
}
