import UIKit
import WebKit
import CedricCore

/// The Markdown preview: the core's renderer and page (`Markdown.render`,
/// `PreviewHTML`, the same as the Mac's) in a WKWebView with JavaScript off,
/// scripts stripped and nothing loaded from the network.
final class PreviewController: UIViewController, WKNavigationDelegate {
    private var web: WKWebView!
    private let queue = DispatchQueue(label: "owlink.preview", qos: .userInitiated)
    private var generation = 0
    static let csp = "default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; script-src 'none'; connect-src 'none'"

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.isOpaque = false
        web.accessibilityIdentifier = "editor.previewWeb"
        view = web
    }

    func show(markdown: String, palette: EditorPalette) {
        generation += 1
        let gen = generation
        web.backgroundColor = UIColor(hex: palette.background)
        queue.async { [weak self] in
            let body = HTMLScrub.noScriptNoRemote(Markdown.render(markdown, options: .preview))
            let page = PreviewHTML.page(body: body, palette: palette, csp: Self.csp)
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.web.loadHTMLString(page, baseURL: nil)
            }
        }
    }

    /// Links open in Safari (asked for), never inside the preview.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let url = action.request.url, ["http", "https"].contains(url.scheme ?? "") {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(action.navigationType == .other ? .allow : .cancel)
    }
}
