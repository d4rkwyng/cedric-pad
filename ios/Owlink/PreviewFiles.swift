import Foundation
import WebKit
import UniformTypeIdentifiers
import CedricCore

/// Serves the preview's `cedric-doc:` URLs from disk, in the app's own
/// process (which holds the security-scoped access to the document and any
/// folder the person granted): the document's folder, a site-root path
/// (`/images/x.webp`) found by `PreviewRoot`, and the Obsidian vault for
/// `![[embeds]]`. The page runs no script, so nothing else can ask.
@MainActor
final class PreviewFiles: NSObject, WKURLSchemeHandler {
    var folder: URL?
    var openedRoot: URL?
    var vaultRoot: URL?
    /// The rendered page, served at `pageURL` so the document's origin is
    /// `cedric-doc` (see `PreviewScheme`). Nil until a preview has rendered.
    var pageHTML: String?
    var pageURL: URL?
    private var stopped: Set<ObjectIdentifier> = []
    /// Links to these open in Owlink.
    static let notes: Set<String> = ["md", "markdown", "mdown", "mkd", "txt"]

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        stopped.remove(id)
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        // The page itself, not a file: generated HTML, already in hand.
        if let pageURL, let pageHTML, PreviewScheme.isPageRequest(url, page: pageURL) {
            guard !stopped.contains(id) else { stopped.remove(id); return }
            let data = Data(pageHTML.utf8)
            task.didReceive(Self.response(url: url, data: data, mime: PreviewScheme.htmlMIME))
            task.didReceive(data)
            task.didFinish()
            return
        }
        guard let folder,
              let file = PreviewFolder.file(for: url, in: folder, openedRoot: openedRoot, vaultRoot: vaultRoot, scriptOn: false) else {
            task.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        let box = PreviewTaskBox(task)
        DispatchQueue.global(qos: .userInitiated).async {
            let data = try? Data(contentsOf: file, options: .mappedIfSafe)
            let mime = PreviewScheme.mimeType(forExtension: file.pathExtension)
                ?? UTType(filenameExtension: file.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let task = box.task
                    guard !self.stopped.contains(id) else { self.stopped.remove(id); return }
                    guard let data else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
                    task.didReceive(Self.response(url: url, data: data, mime: mime))
                    task.didReceive(data)
                    task.didFinish()
                }
            }
        }
    }

    /// An HTTP response. A plain `URLResponse` has no status, and iOS
    /// WebKit then does not paint the image.
    private static func response(url: URL, data: Data, mime: String) -> URLResponse {
        let fields = PreviewScheme.responseFields(mimeType: mime, byteCount: data.count)
        let headers = [
            "Content-Type": fields.mimeType,
            "Content-Length": String(fields.contentLength),
            "Cache-Control": fields.cacheControl,
        ]
        return HTTPURLResponse(url: url, statusCode: fields.status, httpVersion: "HTTP/1.1", headerFields: headers)
            ?? URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil)
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) { stopped.insert(ObjectIdentifier(task)) }

    /// A clicked link's file, if it exists: as given, or a site-root
    /// path's page (`/projects/intelbrew` → `content/projects/intelbrew.md`).
    func linkTarget(_ url: URL) -> URL? {
        guard url.scheme == PreviewFolder.scheme, let file = PreviewFolder.fileURL(for: url) else { return nil }
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard let folder, let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath else { return nil }
        return PreviewRoot.resolve(path, from: folder, openedRoot: openedRoot, pages: true)?.file
    }
}

private final class PreviewTaskBox: @unchecked Sendable {
    let task: any WKURLSchemeTask
    init(_ task: any WKURLSchemeTask) { self.task = task }
}

/// Folders the person let the preview read (from the "Open the folder"
/// hint), kept as bookmarks so the grant outlives the launch. A folder
/// covers every document inside it.
@MainActor
final class PreviewFolderGrants {
    static let shared = PreviewFolderGrants()
    private static let key = "previewFolderGrants"
    private var open: [URL] = []
    private var loaded = false

    /// The granted folder holding `folder` (the nearest), access started.
    func root(for folder: URL) -> URL? {
        loadIfNeeded()
        let path = folder.standardizedFileURL.path + "/"
        return open.filter { path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }
            .max { $0.path.count < $1.path.count }
    }

    func add(_ url: URL) {
        loadIfNeeded()
        _ = url.startAccessingSecurityScopedResource()
        let u = url.standardizedFileURL
        if !open.contains(u) { open.append(u) }
        var saved = (AppSettings.defaults.array(forKey: Self.key) as? [Data]) ?? []
        if let b = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            saved.append(b)
            AppSettings.defaults.set(Array(saved.suffix(20)), forKey: Self.key)
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        for data in (AppSettings.defaults.array(forKey: Self.key) as? [Data]) ?? [] {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            if url.startAccessingSecurityScopedResource() || FileManager.default.isReadableFile(atPath: url.path) {
                let u = url.standardizedFileURL
                if !open.contains(u) { open.append(u) }
            }
        }
    }
}
