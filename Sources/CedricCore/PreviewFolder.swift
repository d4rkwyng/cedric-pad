import Foundation

/// The preview page's view of the document's folder. The page's base URL
/// is `cedric-doc://doc/<folder>/`, so relative images, styles and links
/// resolve into it, and the app serves files from that folder (and its
/// subfolders) only. (A plain `file:` base gives a WKWebView page no
/// access at all, and loadFileURL would need the page itself on disk.)
public enum PreviewFolder {
    public static let scheme = "cedric-doc"

    /// The page URL for a document in `folder`.
    public static func pageURL(for folder: URL) -> URL? {
        let path = folder.standardizedFileURL.path
        var c = URLComponents()
        c.scheme = scheme
        c.host = "doc"
        c.path = path.hasSuffix("/") ? path : path + "/"
        return c.url
    }

    /// The file a page URL stands for (nil for any other URL).
    public static func fileURL(for url: URL) -> URL? {
        guard url.scheme == scheme, let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    /// `url`'s file, if it lies inside `folder` (after `..` and symbolic links).
    public static func file(for url: URL, in folder: URL) -> URL? {
        guard let file = fileURL(for: url) else { return nil }
        let root = resolved(folder.standardizedFileURL).path
        let target = resolved(file).path
        return target.hasPrefix(root.hasSuffix("/") ? root : root + "/") ? file : nil
    }

    /// `url` with symbolic links resolved, also when its last parts don't
    /// exist (resolvingSymlinksInPath leaves such a path as it is).
    static func resolved(_ url: URL) -> URL {
        var head = url
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: head.path), head.path != "/" {
            tail.insert(head.lastPathComponent, at: 0)
            head.deleteLastPathComponent()
        }
        var r = head.resolvingSymlinksInPath()
        for part in tail { r.appendPathComponent(part) }
        return r
    }
}

/// Where to cut a tall rendered page into PDF pages: at the lowest block
/// bottom that fits on each page (so no line is cut in two), or at the
/// page height when no block ends on it.
public enum PageBreaks {
    public static func cuts(total: CGFloat, pageHeight h: CGFloat, boundaries: [CGFloat]) -> [CGFloat] {
        guard total > 0, h > 0 else { return [0, max(total, 1)] }
        let sorted = Array(Set(boundaries.filter { $0 > 0 && $0 < total })).sorted()
        var cuts: [CGFloat] = [0]
        var y: CGFloat = 0
        while total - y > h {
            // Not less than half a page, so a page is never nearly empty.
            let best = sorted.last { $0 <= y + h && $0 >= y + h / 2 }
            y = best ?? y + h
            cuts.append(y)
        }
        cuts.append(total)
        return cuts
    }
}

/// What a click on a preview link does (security audit H2). Nothing a
/// link names is ever launched: web and mail links open only after the
/// user confirms the full URL, a text file inside the document's folder
/// opens in Cedric, any other local file is only shown in Finder, and
/// every other scheme is ignored.
public enum PreviewLinkAction: Equatable, Sendable {
    /// http, https or mailto: ask first, showing the whole URL.
    case confirmExternal(URL)
    /// A text file inside the document's folder (symbolic links resolved).
    case openInCedric(URL)
    /// Any other local file or folder, or one outside the document's folder.
    case revealInFinder(URL)
    /// A scheme Cedric doesn't follow, or a file that isn't there.
    case ignore(String)

    public static let externalSchemes: Set<String> = ["http", "https", "mailto"]

    /// `folder`: the document's folder (nil for an untitled document).
    /// `isText`: whether Cedric edits a file of that name and kind.
    public static func action(for url: URL, folder: URL?, isText: (URL) -> Bool,
                              fileManager fm: FileManager = .default) -> PreviewLinkAction {
        let scheme = url.scheme?.lowercased() ?? ""
        if externalSchemes.contains(scheme) {
            if scheme != "mailto", url.host?.isEmpty ?? true { return .ignore(scheme) }
            return .confirmExternal(url)
        }
        let file: URL
        if scheme == PreviewFolder.scheme, let f = PreviewFolder.fileURL(for: url) {
            file = f
        } else if url.isFileURL {
            file = url.standardizedFileURL
        } else {
            return .ignore(scheme.isEmpty ? "?" : scheme)
        }
        let target = PreviewFolder.resolved(file)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: target.path, isDirectory: &isDir) else { return .ignore("missing") }
        guard let folder else { return .revealInFinder(file) }
        let root = PreviewFolder.resolved(folder.standardizedFileURL).path
        let inside = target.path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        // A folder (an .app bundle is one) is never opened, only shown.
        if inside, !isDir.boolValue, isText(target) { return .openInCedric(file) }
        return .revealInFinder(file)
    }
}
