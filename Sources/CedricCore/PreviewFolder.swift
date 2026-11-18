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
