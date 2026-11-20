import AppKit
import WebKit
import CedricCore
import CedricAI

/// describe_image's picture of an SVG document: the text as it is in the
/// editor (unsaved edits included), rendered by the preview's own renderer
/// (a `PreviewController`: WebKit with page JavaScript and network off,
/// files from the document's folder only), snapshotted off screen and
/// flattened onto white. If WebKit can't snapshot it, AppKit's own SVG
/// support (NSImage) draws it instead. Made only when the tool runs.
struct SVGPictureSource: OwlImageSource {
    let text: String
    let folder: URL?
    /// Larger SVG text isn't rendered.
    static let maxBytes = 8 << 20
    /// Margin around the drawing, as a fraction of its long side: an icon
    /// drawn to its edges is easier for Vision to recognise with one.
    static let padding = 0.12

    func render(maxPixels: Int) async throws -> OwlRenderedImage {
        guard text.utf8.count <= Self.maxBytes else { throw OwlImageError.tooLarge }
        // The long side of the drawing, leaving room for the margin.
        let side = Double(min(maxPixels, 512)) / (1 + 2 * Self.padding)
        if let shot = try? await SVGSnapshotter.snapshot(text: text, folder: folder, side: side),
           let picture = OwlRenderedImage.padded(shot.image, padding: Self.padding, width: shot.width, height: shot.height) {
            return picture
        }
        return try OwlSVGImageSource(text: text, padding: Self.padding).draw(side: side)
    }
}

/// Renders SVG text with an off-screen `PreviewController` and snapshots
/// the `<svg>` element.
@MainActor
enum SVGSnapshotter {
    /// The page's size: an SVG larger than this is scaled down to fit.
    static let page = NSSize(width: 1200, height: 1200)
    /// How long the page may take to load.
    static let loadLimit: TimeInterval = 8
    /// Snapshots taken (checks).
    private(set) static var count = 0

    static func snapshot(text: String, folder: URL?, side: Double) async throws -> (image: CGImage, width: Int, height: Int) {
        let preview = PreviewController()
        let web = preview.webView
        web.frame = NSRect(origin: .zero, size: page)
        defer { preview.onLoaded = nil; web.stopLoading() }
        try await load(preview, text: text, folder: folder)
        // In the app's own content world: works with page JavaScript off.
        // The SVG's own size, then scaled to fit the page if larger.
        let js = """
        (() => { const s = document.querySelector('svg'); if (!s) return null;
          document.body.style.margin = '0';
          let r = s.getBoundingClientRect(); const w = r.width, h = r.height;
          if (w > innerWidth || h > innerHeight) { const k = Math.min(innerWidth / w, innerHeight / h);
            s.style.width = (w * k) + 'px'; s.style.height = (h * k) + 'px'; r = s.getBoundingClientRect(); }
          return [r.x, r.y, r.width, r.height, w, h]; })()
        """
        let box: [Double] = try await withCheckedThrowingContinuation { c in
            web.evaluateJavaScript(js, in: nil, in: .defaultClient) { result in
                switch result {
                case .success(let v):
                    if let a = v as? [NSNumber], a.count == 6 { c.resume(returning: a.map(\.doubleValue)) } else { c.resume(throwing: OwlImageError.unreadable) }
                case .failure(let e): c.resume(throwing: e)
                }
            }
        }
        guard box[2] >= 1, box[3] >= 1 else { throw OwlImageError.unreadable }
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
        config.afterScreenUpdates = true
        // Points; the snapshot is drawn at this width (vector, so sharp).
        config.snapshotWidth = NSNumber(value: max(1, side * box[2] / max(box[2], box[3])))
        let image: NSImage = try await withCheckedThrowingContinuation { c in
            web.takeSnapshot(with: config) { img, err in
                if let img { c.resume(returning: img) } else { c.resume(throwing: err ?? OwlImageError.unreadable) }
            }
        }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw OwlImageError.unreadable }
        count += 1
        return (cg, Int(box[4].rounded()), Int(box[5].rounded()))
    }

    private static func load(_ preview: PreviewController, text: String, folder: URL?) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            // The body runs right away, on the main actor (the caller's).
            MainActor.assumeIsolated {
                let waiter = LoadWaiter(c, preview)
                preview.onLoaded = { waiter.finish(nil) }
                preview.show(text: text, language: .html, palette: EditorPalettes.light, baseURL: folder)
                DispatchQueue.main.asyncAfter(deadline: .now() + loadLimit) { MainActor.assumeIsolated { waiter.finish(OwlImageError.timedOut) } }
            }
        }
    }
}

/// Resumes the load's continuation once: loaded, or out of time.
@MainActor
private final class LoadWaiter {
    private var continuation: CheckedContinuation<Void, Error>?
    private weak var preview: PreviewController?
    init(_ c: CheckedContinuation<Void, Error>, _ preview: PreviewController) { continuation = c; self.preview = preview }
    func finish(_ error: Error?) {
        guard let c = continuation else { return }
        continuation = nil
        preview?.onLoaded = nil
        if let error { c.resume(throwing: error) } else { c.resume() }
    }
}
