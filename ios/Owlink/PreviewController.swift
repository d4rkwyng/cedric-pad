import UIKit
import WebKit
import UniformTypeIdentifiers
import CedricCore

/// The Markdown preview: the core's renderer and page (`Markdown.render`,
/// `PreviewHTML`, the same as the Mac's) in a WKWebView with JavaScript off,
/// scripts stripped and nothing loaded from the network.
///
/// The text size is the person's zoom (pinch, or ⌘+ and ⌘− in Focus
/// Preview), kept for the app, times the Dynamic Type scale, as the web
/// view's page zoom so the text reflows. The scroll position survives the
/// reloads that follow typing, and can be set as a share of the page
/// (Focus Preview keeps text and preview at the same place).
///
/// Images and wikilinks resolve on disk only: the page's base URL is
/// `cedric-doc://doc/<folder>/` and `PreviewFiles` serves files from the
/// document's folder, the site root `PreviewRoot` finds for `/images/…`,
/// and the Obsidian vault, read in this process (which holds the
/// security-scoped access), so the web view itself needs no file access.
/// A file opened on its own from Files grants only itself: its images
/// then show a quiet "Open the folder" hint, which asks for the folder.
final class PreviewController: UIViewController, WKNavigationDelegate, UIGestureRecognizerDelegate, UIDocumentPickerDelegate {
    private(set) var web: WKWebView!
    private let queue = DispatchQueue(label: "owlink.preview", qos: .userInitiated)
    private var generation = 0
    static let csp = "default-src 'none'; img-src data: \(PreviewFolder.scheme):; media-src data: \(PreviewFolder.scheme):; style-src 'unsafe-inline'; font-src data:; script-src 'none'; connect-src 'none'"
    /// The hint's link: asks for the document's folder.
    static let grantURL = "owlink-preview:open-folder"
    /// The open document (its folder is the page's base).
    var documentURL: URL?
    /// A text file a preview link names, to open in Owlink.
    var onOpenFile: ((URL) -> Void)?
    private let files = PreviewFiles()
    private var vault: WikiVault?
    private var vaultKey: String?
    private var last: (markdown: String, palette: EditorPalette)?
    /// A scroll share to apply once the page has loaded (and laid out).
    private var pendingFraction: Double?
    private var loaded = false
    private(set) var userZoom = PreviewZoom.load(AppSettings.defaults)
    private var pinchStart = 1.0
    /// Called with the new zoom (for a short "Text 120%" note).
    var onZoom: ((Double) -> Void)?

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(files, forURLScheme: PreviewFolder.scheme)
        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.isOpaque = false
        web.accessibilityIdentifier = "editor.previewWeb"
        // Our pinch sets the text size (it reflows); WebKit's own would
        // magnify the page sideways.
        web.scrollView.pinchGestureRecognizer?.isEnabled = false
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        web.addGestureRecognizer(pinch)
        let container = UIView()
        web.frame = container.bounds
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(web)
        setUpHeader(in: container)
        view = container
    }

    // MARK: Header (Focus Preview, Open in New Window)

    /// Small controls in the preview's own top corner: Focus Preview (or
    /// back out of it) and, where there can be more windows (iPad), Open
    /// Preview in New Window, which can also be dragged out to make one.
    private let header = UIStackView()
    private let focusButton = UIButton(configuration: .gray())
    private let detachButton = UIButton(configuration: .gray())
    private var onFocus: (() -> Void)?
    private var onDetach: (() -> Void)?
    private var detachActivity: (() -> NSUserActivity?)?

    private func setUpHeader(in container: UIView) {
        header.axis = .horizontal
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false
        for (b, id) in [(focusButton, "preview.header.focus"), (detachButton, "preview.header.detach")] {
            var c = b.configuration ?? .gray()
            c.cornerStyle = .capsule
            c.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .medium)
            c.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 9, bottom: 7, trailing: 9)
            b.configuration = c
            b.alpha = 0.85
            b.accessibilityIdentifier = id
            b.pointerStyleProvider = { button, _, _ in UIPointerStyle(effect: .highlight(UITargetedPreview(view: button))) }
            header.addArrangedSubview(b)
        }
        focusButton.addAction(UIAction { [weak self] _ in self?.onFocus?() }, for: .primaryActionTriggered)
        detachButton.addAction(UIAction { [weak self] _ in self?.onDetach?() }, for: .primaryActionTriggered)
        detachButton.configuration?.image = UIImage(systemName: "macwindow.badge.plus")
        detachButton.accessibilityLabel = String(localized: "Open Preview in New Window")
        detachButton.accessibilityHint = String(localized: "Or drag it out to make a window.")
        detachButton.addInteraction(UIDragInteraction(delegate: self))
        container.addSubview(header)
        let g = container.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: g.topAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -10),
        ])
        header.isHidden = true
    }

    /// Shows the header with what it can do here (nothing: hidden, as in a
    /// detached preview window). `focusOn`: the button leaves Focus Preview.
    func configureHeader(focusOn: Bool, onFocus: (() -> Void)?, onDetach: (() -> Void)?,
                         detachActivity: (() -> NSUserActivity?)?) {
        loadViewIfNeeded()
        self.onFocus = onFocus
        self.onDetach = onDetach
        self.detachActivity = detachActivity
        focusButton.isHidden = onFocus == nil
        detachButton.isHidden = onDetach == nil
        focusButton.configuration?.image = UIImage(systemName: focusOn ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        focusButton.accessibilityLabel = focusOn ? String(localized: "Exit Focus Preview") : String(localized: "Focus Preview")
        header.isHidden = onFocus == nil && onDetach == nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyZoom(keepingPlace: false)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _: UITraitCollection) in
            self.applyZoom(keepingPlace: true)
        }
    }

    func show(markdown: String, palette: EditorPalette) {
        generation += 1
        let gen = generation
        web.backgroundColor = UIColor(hex: palette.background)
        last = (markdown, palette)
        let folder = documentURL?.deletingLastPathComponent().standardizedFileURL
        let opened = folder.flatMap(PreviewFolderGrants.shared.root(for:))
        let key = "\(folder?.path ?? "-")|\(opened?.path ?? "-")"
        if key != vaultKey {
            vaultKey = key
            vault = folder.map { WikiVault(documentFolder: $0, openedRoot: opened) }
        }
        let vault = self.vault
        files.folder = folder
        files.openedRoot = opened
        files.vaultRoot = vault?.root
        let baseURL = folder.flatMap(PreviewFolder.pageURL(for:))
        let hint = "<p class=\"preview-hint\"><a href=\"\(Self.grantURL)\">" + Markdown.escape(String(localized: "Open the folder to see its images")) + "</a></p>\n"
        queue.async { [weak self] in
            var body = HTMLScrub.noScriptNoRemote(Markdown.render(markdown, options: .preview(vault: vault)))
            if let folder {
                // No access to the folder (a file opened on its own): its
                // images can't load, so a hint instead of empty boxes.
                let readable = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil
                body = PreviewImageAccess.hideUnreadable(body, folder: folder, openedRoot: opened, folderReadable: readable, hint: hint).html
            }
            let page = PreviewHTML.page(body: body, palette: palette, csp: Self.csp, viewport: true)
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                // A reload goes back to the top: keep the reader's place.
                if self.loaded, self.pendingFraction == nil { self.pendingFraction = self.scrollFraction }
                self.loaded = false
                self.web.loadHTMLString(page, baseURL: baseURL)
            }
        }
    }

    // MARK: Scroll

    /// Where the page is scrolled, 0 (top) to 1 (bottom); setting it before
    /// the page has loaded applies it once it has.
    var scrollFraction: Double {
        get {
            if let p = pendingFraction { return p }
            let s = web.scrollView
            return ScrollSync.fraction(offset: s.contentOffset.y, contentHeight: s.contentSize.height, visibleHeight: s.bounds.height,
                                       insetTop: s.adjustedContentInset.top, insetBottom: s.adjustedContentInset.bottom)
        }
        set {
            pendingFraction = newValue
            if loaded { applyPendingFraction() }
        }
    }

    private func applyPendingFraction() {
        guard let f = pendingFraction else { return }
        let s = web.scrollView
        let y = ScrollSync.offset(fraction: f, contentHeight: s.contentSize.height, visibleHeight: s.bounds.height,
                                  insetTop: s.adjustedContentInset.top, insetBottom: s.adjustedContentInset.bottom)
        s.setContentOffset(CGPoint(x: -s.adjustedContentInset.left, y: y), animated: false)
        pendingFraction = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        // The content size settles a moment after the load finishes.
        let f = pendingFraction
        applyPendingFraction()
        guard let f else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.loaded, self.pendingFraction == nil else { return }
            self.pendingFraction = f
            self.applyPendingFraction()
        }
    }

    // MARK: Text size

    /// Dynamic Type's scale for body text (1 at the default size).
    private var dynamicTypeScale: Double {
        Double(UIFontMetrics(forTextStyle: .body).scaledValue(for: 17, compatibleWith: traitCollection) / 17)
    }

    var pageZoom: Double { PreviewZoom.pageZoom(user: userZoom, dynamicTypeScale: dynamicTypeScale) }

    private func applyZoom(keepingPlace: Bool) {
        let z = CGFloat(pageZoom)
        guard web.pageZoom != z else { return }
        let f = keepingPlace && loaded ? scrollFraction : nil
        web.pageZoom = z
        if let f {
            DispatchQueue.main.async { [weak self] in self?.scrollFraction = f }
        }
    }

    func setZoom(_ z: Double, save: Bool = true) {
        let c = PreviewZoom.clamped(z)
        guard c != userZoom else { return }
        userZoom = c
        applyZoom(keepingPlace: true)
        if save { PreviewZoom.save(c, AppSettings.defaults) }
        onZoom?(c)
    }

    func bigger() { setZoom(PreviewZoom.step(userZoom, in: true)) }
    func smaller() { setZoom(PreviewZoom.step(userZoom, in: false)) }
    func actualSize() { setZoom(1) }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began: pinchStart = userZoom
        case .changed: setZoom(PreviewZoom.pinched(pinchStart, scale: Double(g.scale)), save: false)
        case .ended, .cancelled: PreviewZoom.save(userZoom, AppSettings.defaults)
        default: break
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { false }

    static func withoutFragment(_ u: URL) -> String {
        var c = URLComponents(url: u, resolvingAgainstBaseURL: false)
        c?.fragment = nil
        return c?.string ?? u.absoluteString
    }

    // MARK: Folder access

    /// Asks for the document's folder (or one above it, a site's root).
    private func askForFolder() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.directoryURL = documentURL?.deletingLastPathComponent()
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        PreviewFolderGrants.shared.add(url)
        if let last { show(markdown: last.markdown, palette: last.palette) }
    }

    /// Links open in Safari (asked for), never inside the preview; a
    /// wikilink or a link to a text file in the folder opens it in Owlink.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let url = action.request.url, ["http", "https"].contains(url.scheme ?? "") {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        if action.navigationType == .linkActivated, let url = action.request.url {
            if url.absoluteString == Self.grantURL {
                decisionHandler(.cancel)
                askForFolder()
                return
            }
            if url.fragment != nil, let page = webView.url, Self.withoutFragment(url) == Self.withoutFragment(page) {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            if let file = files.linkTarget(url), PreviewFiles.notes.contains(file.pathExtension.lowercased()) { onOpenFile?(file) }
            return
        }
        decisionHandler(action.navigationType == .other ? .allow : .cancel)
    }
}

/// Dragging Open Preview in New Window out of the preview makes the window
/// where it is dropped (iPad, Stage Manager, an external display).
extension PreviewController: UIDragInteractionDelegate {
    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: any UIDragSession) -> [UIDragItem] {
        guard let activity = detachActivity?() else { return [] }
        let provider = NSItemProvider()
        provider.registerObject(activity, visibility: .all)
        let item = UIDragItem(itemProvider: provider)
        item.localObject = activity
        return [item]
    }
}
