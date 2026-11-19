import AppKit
import CedricCore
import PDFKit
import WebKit

/// File › Export as HTML… / Export as PDF…, and Edit › Copy as HTML /
/// Copy as Rich Text, for Markdown: the rendered document (as the preview
/// renders it, fenced code coloured) in a theme-neutral light style,
/// whatever theme the editor uses.
extension EditorWindowController {
    /// The document's name without its extension.
    var exportBaseName: String {
        let n = doc.displayName
        let base = (n as NSString).deletingPathExtension
        return base.isEmpty ? n : base
    }

    /// A standalone page, light style, with no script: raw HTML blocks'
    /// `<script>`, frames and `on…=` handlers are removed (it is opened
    /// in a browser later), and a CSP forbids script as a second layer.
    nonisolated static func exportPage(markdown: String, title: String) -> String {
        PreviewController.page(body: HTMLScrub.noScript(Markdown.render(markdown, options: .preview)), palette: EditorPalettes.light,
                               csp: "script-src 'none'; object-src 'none'; frame-src 'none'", title: title)
    }

    /// The selection's Markdown, or the whole document's.
    var exportSelectionMarkdown: String {
        let r = textView.selectedRange()
        let ns = textView.string as NSString
        return r.length > 0 ? ns.substring(with: r) : ns as String
    }

    func exportHTML() {
        guard doc.language == .markdown else { NSSound.beep(); return }
        let text = textView.string, title = exportBaseName
        // Rendered off the main thread (a crafted document must not hang
        // the app), then the save panel.
        MarkdownWork.run({ Self.exportPage(markdown: text, title: title) }) { [weak self] html in
            guard let self else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.html]
            panel.nameFieldStringValue = title + ".html"
            if let dir = self.doc.fileURL?.deletingLastPathComponent() { panel.directoryURL = dir }
            let done: (NSApplication.ModalResponse) -> Void = { [weak self] r in
                guard r == .OK, let url = panel.url else { return }
                self?.writeExport(Data(html.utf8), to: url)
            }
            if let w = self.window { panel.beginSheetModal(for: w, completionHandler: done) } else { done(panel.runModal()) }
        }
    }

    func exportPDF() {
        guard doc.language == .markdown else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = exportBaseName + ".pdf"
        if let dir = doc.fileURL?.deletingLastPathComponent() { panel.directoryURL = dir }
        let text = textView.string
        let folder = doc.fileURL?.deletingLastPathComponent()
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            MarkdownPDFExport.run(markdown: text, folder: folder, title: self?.exportBaseName ?? "", to: url) { error in
                if let error { self?.showError(error) }
            }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: done) } else { done(panel.runModal()) }
    }

    private func writeExport(_ data: Data, to url: URL) {
        do { try data.write(to: SafePaths.writeTarget(for: url), options: .atomic) } catch { showError(error) }
    }

    /// Edit › Copy as HTML: the rendered HTML of the selection (or the
    /// whole document), as text. Rendered off the main thread; `done`
    /// runs once the pasteboard has it.
    func copyAsHTML(done: (@MainActor () -> Void)? = nil) {
        guard doc.language == .markdown else { NSSound.beep(); return }
        let md = exportSelectionMarkdown
        MarkdownWork.run({ HTMLScrub.noScript(Markdown.render(md, options: .preview)) }) { html in
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(html, forType: .string)
            done?()
        }
    }

    /// Edit › Copy as Rich Text: the rendered selection (or document) as
    /// RTF and HTML for mail, notes and word processors, and its plain text.
    /// On the main thread: AppKit's HTML importer runs there anyway (and
    /// run from a background render's completion it sometimes returned
    /// nothing); the renderer is linear now, so a crafted document can't
    /// hang it. `done` runs after, synchronously.
    func copyAsRichText(done: (@MainActor () -> Void)? = nil) {
        defer { done?() }
        guard doc.language == .markdown else { NSSound.beep(); return }
        // Nothing remote: the HTML importer must not fetch a tracking image.
        let page = HTMLScrub.noScriptNoRemote(Self.exportPage(markdown: exportSelectionMarkdown, title: exportBaseName))
        guard let attributed = NSAttributedString(html: Data(page.utf8), options: [.characterEncoding: String.Encoding.utf8.rawValue],
                                                  documentAttributes: nil) else { NSSound.beep(); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        if let rtf = try? attributed.data(from: NSRange(location: 0, length: attributed.length),
                                          documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            item.setData(rtf, forType: .rtf)
        }
        item.setString(page, forType: .html)
        item.setString(attributed.string, forType: .string)
        pb.writeObjects([item])
    }
}

/// Markdown work kept off the main thread (Copy as HTML, export): a
/// crafted document can take a while and must not beachball the app. A
/// thread of its own with a main-thread-sized stack, as rendering recurses
/// into nested lists and quotes.
enum MarkdownWork {
    static func run(_ work: @escaping @Sendable () -> String, then: @escaping @MainActor @Sendable (String) -> Void) {
        let t = Thread {
            let result = work()
            DispatchQueue.main.async { MainActor.assumeIsolated { then(result) } }
        }
        t.stackSize = 8 << 20
        t.qualityOfService = .userInitiated
        t.start()
    }
}

/// Renders the Markdown in an offscreen preview (light style, same rules:
/// no page script, no network, files from the document's folder only) and
/// writes it, paginated between blocks, to a PDF file.
@MainActor
final class MarkdownPDFExport: NSObject {
    private static var running: [MarkdownPDFExport] = []
    private let preview = PreviewController()
    private let window: NSWindow
    private let url: URL
    private let done: (Error?) -> Void
    private var finished = false

    private init(url: URL, done: @escaping (Error?) -> Void) {
        self.url = url
        self.done = done
        window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: Self.pageWidth, height: Self.pageHeight), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init()
        // The window keeps its own content view for its whole life; the web
        // view is a subview, taken out (never swapped out) at the end.
        // (Replacing the content view under a WKWebView traps in WebKit's
        // window-visibility observer.)
        preview.webView.frame = window.contentView?.bounds ?? .zero
        preview.webView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(preview.webView)
    }

    static func run(markdown: String, folder: URL?, title: String, to url: URL, done: @escaping (Error?) -> Void) {
        let job = MarkdownPDFExport(url: url, done: done)
        running.append(job)
        job.preview.onLoaded = { [weak job] in
            // Let images settle a moment before printing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { job?.print() }
        }
        job.preview.show(text: markdown, language: .markdown, palette: EditorPalettes.light, baseURL: folder)
        // Never hang: give up after 30 s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak job] in
            job?.finish(NSError(domain: "Cedric", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "The PDF could not be made in time.")]))
        }
    }

    /// A page: US Letter's proportions at the page's 760-point width.
    static let pageWidth: CGFloat = 760
    static var pageHeight: CGFloat { (pageWidth * 11 / 8.5).rounded() }

    /// Pages cut between blocks (never through a line where a block
    /// boundary fits), each made with createPDF and joined. (WebKit's
    /// print operation needs a print session on screen; createPDF doesn't.)
    private func print() {
        let h = Self.pageHeight
        let js = """
        (() => { const out = [], y = window.scrollY;
          for (const e of document.querySelectorAll('body > *, li, tr, pre')) { const r = e.getBoundingClientRect(); out.push(r.bottom + y); }
          return [document.documentElement.scrollHeight, out]; })()
        """
        guard !finished else { return }
        preview.webView.evaluateJavaScript(js, in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, !self.finished else { return }
                var total = h
                var bottoms: [CGFloat] = []
                if case .success(let v) = result, let a = v as? [Any] {
                    total = CGFloat((a.first as? NSNumber)?.doubleValue ?? Double(h))
                    bottoms = ((a.last as? [Any]) ?? []).compactMap { ($0 as? NSNumber).map { CGFloat($0.doubleValue) } }
                }
                self.makePages(PageBreaks.cuts(total: total, pageHeight: h, boundaries: bottoms))
            }
        }
    }

    private func makePages(_ cuts: [CGFloat]) {
        let doc = PDFDocument()
        var k = 0
        @MainActor func next() {
            guard k + 1 < cuts.count else {
                if doc.write(to: url) { finish(nil) } else { finish(CocoaError(.fileWriteUnknown)) }
                return
            }
            let y0 = cuts[k], y1 = cuts[k + 1]
            k += 1
            let config = WKPDFConfiguration()
            config.rect = CGRect(x: 0, y: y0, width: Self.pageWidth, height: y1 - y0)
            preview.webView.createPDF(configuration: config) { [weak self] result in
                MainActor.assumeIsolated {
                    guard let self, !self.finished else { return }
                    guard case .success(let data) = result, let part = PDFDocument(data: data), let page = part.page(at: 0) else {
                        if case .failure(let e) = result { self.finish(e) } else { self.finish(CocoaError(.fileWriteUnknown)) }
                        return
                    }
                    // Every page the same size, content at the top.
                    let box = page.bounds(for: .mediaBox)
                    let full = Self.pageHeight
                    if box.height < full {
                        page.setBounds(NSRect(x: box.minX, y: box.maxY - full, width: box.width, height: full), for: .mediaBox)
                    }
                    doc.insert(page, at: doc.pageCount)
                    next()
                }
            }
        }
        next()
    }

    /// Ends the job (once): stops the page, takes the web view out of the
    /// window, and lets the window go on the next turn of the run loop,
    /// after WebKit is done with this one. Always on the main thread.
    private func finish(_ error: Error?) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !finished else { return }
        finished = true
        preview.onLoaded = nil
        preview.webView.stopLoading()
        preview.webView.removeFromSuperview()
        done(error)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.window.orderOut(nil)
                Self.running.removeAll { $0 === self }
            }
        }
    }

    /// Exports still running (for the checks).
    static var runningCount: Int { running.count }
}
