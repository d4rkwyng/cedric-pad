import AppKit
import CedricCore
import WebKit

/// The side-by-side preview for Markdown and HTML. JavaScript and network
/// access are off unless the user turns them on (View menu), per tab:
/// scripts are disabled with WKWebpagePreferences, and remote loads are
/// blocked twice, by a WebKit content rule list and by a
/// Content-Security-Policy in the page. Links open in the default
/// browser only when clicked.
@MainActor
final class PreviewController: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    var allowJavaScript = false
    var allowNetwork = false
    private var lastHTML = ""
    private var pending: (() -> Void)?
    private static var blockRules: WKContentRuleList?
    private static var compiling = false
    private static var waiting: [() -> Void] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
    }

    /// Compiles the "block all remote loads" rule list once per app run.
    private static func withRules(_ then: @escaping () -> Void) {
        if blockRules != nil { then(); return }
        waiting.append(then)
        guard !compiling else { return }
        compiling = true
        // WebKit's rule regexes have no alternation: one rule per scheme.
        let json = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},"#
            + #"{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},"#
            + #"{"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "cedric-block-network-v2", encodedContentRuleList: json) { list, error in
            if let error { FileHandle.standardError.write(Data("preview: rule list: \(error)\n".utf8)) }
            MainActor.assumeIsolated {
                blockRules = list
                compiling = false
                let w = waiting
                waiting = []
                w.forEach { $0() }
            }
        }
    }

    /// Renders the document. `baseURL` is the file's folder, for relative images.
    func show(text: String, language: Language, palette: EditorPalette, baseURL: URL?) {
        let html: String
        if language == .markdown {
            html = Self.page(body: Markdown.render(text), palette: palette, csp: csp)
        } else {
            html = Self.injectCSP(csp, into: text)
        }
        let load = { [weak self] in
            guard let self else { return }
            let ucc = self.webView.configuration.userContentController
            ucc.removeAllContentRuleLists()
            if !self.allowNetwork, let rules = Self.blockRules { ucc.add(rules) }
            self.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = self.allowJavaScript
            self.lastHTML = html
            self.webView.loadHTMLString(html, baseURL: baseURL)
        }
        if allowNetwork { load() } else { Self.withRules(load) }
    }

    var csp: String {
        let net = allowNetwork ? " https: http:" : ""
        let script = allowJavaScript ? "'unsafe-inline' file:\(net)" : "'none'"
        return "default-src 'none'; img-src file: data:\(net); media-src file: data:\(net); style-src 'unsafe-inline' file:\(net); font-src file: data:\(net); script-src \(script); connect-src \(allowNetwork ? "*" : "'none'")"
    }

    static func injectCSP(_ csp: String, into html: String) -> String {
        "<meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\">\n" + html
    }

    static func hex(_ c: UInt32) -> String { String(format: "#%06x", c) }

    static func page(body: String, palette p: EditorPalette, csp: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <style>
        :root { color-scheme: \(p.isDark ? "dark" : "light"); }
        body { font: 15px/1.55 -apple-system, system-ui, sans-serif; color: \(hex(p.foreground)); background: \(hex(p.background));
               max-width: 820px; margin: 0 auto; padding: 18px 24px 60px; }
        h1, h2 { border-bottom: 1px solid \(hex(p.currentLine)); padding-bottom: .25em; }
        h1, h2, h3, h4, h5, h6 { color: \(hex(p.color(for: .heading))); line-height: 1.25; margin: 1.2em 0 .5em; }
        a { color: \(hex(p.color(for: .link))); }
        code, pre { font: 13px ui-monospace, "SF Mono", Menlo, monospace; background: \(hex(p.currentLine)); border-radius: 4px; }
        code { padding: .1em .35em; }
        pre { padding: 10px 12px; overflow-x: auto; }
        pre code { padding: 0; background: none; }
        blockquote { margin: 0; padding: 0 1em; color: \(hex(p.color(for: .comment))); border-left: 4px solid \(hex(p.currentLine)); }
        table { border-collapse: collapse; }
        th, td { border: 1px solid \(hex(p.currentLine)); padding: 4px 10px; }
        img { max-width: 100%; }
        hr { border: 0; border-top: 1px solid \(hex(p.currentLine)); }
        </style></head><body>
        \(body)
        </body></html>
        """
    }

    /// Scrolls so the block nearest source line `line` is at the top
    /// (Markdown, by its data-line attributes), or to `fraction` of the
    /// page (HTML). Works with page JavaScript off: this runs in the app's
    /// own content world.
    func sync(line: Int, fraction: Double, markdown: Bool) {
        let js: String
        if markdown {
            js = """
            (function(){var best=null;for(const e of document.querySelectorAll('[data-line]')){if(+e.dataset.line<=\(line))best=e;else break;}
            if(best)window.scrollTo(0,best.getBoundingClientRect().top+window.scrollY-8);else window.scrollTo(0,0);})()
            """
        } else {
            js = "window.scrollTo(0,(document.documentElement.scrollHeight-window.innerHeight)*\(fraction))"
        }
        webView.evaluateJavaScript(js, in: nil, in: .defaultClient) { _ in }
    }

    var onLoaded: (() -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onLoaded?()
    }

    // Links: the first load is ours; anything the user clicks opens in the browser.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let url = action.request.url {
            if url.fragment != nil, url.scheme == "about" || url.isFileURL { decisionHandler(.allow); return }
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(action.navigationType == .other || action.navigationType == .reload ? .allow : .cancel)
    }
}
