import AppKit
import CedricCore

/// What draws a preview: the web view for Markdown and HTML
/// (PreviewController), the grid for CSV and TSV (CSVPreview).
@MainActor
protocol PreviewRenderer: AnyObject {
    var view: NSView { get }
    /// Shows `text`. `fileName` tells .tsv from .csv.
    func render(text: String, language: Language, palette: EditorPalette, baseURL: URL?, fileName: String?)
    /// Scrolls to roughly source line `line` (or `fraction` of the way down).
    func sync(line: Int, fraction: Double, language: Language)
    /// Whether this renderer draws `language`.
    func handles(_ language: Language) -> Bool
}

extension PreviewController: PreviewRenderer {
    var view: NSView { webView }

    func render(text: String, language: Language, palette: EditorPalette, baseURL: URL?, fileName: String?) {
        show(text: text, language: language, palette: palette, baseURL: baseURL)
    }

    func sync(line: Int, fraction: Double, language: Language) {
        sync(line: line, fraction: fraction, markdown: language == .markdown)
    }

    func handles(_ language: Language) -> Bool { language == .markdown || language == .html }
}

/// The preview with its header (title and Detach / Attach), docked
/// beside the editor or alone in its own window.
@MainActor
final class PreviewPane: NSView {
    private(set) var renderer: PreviewRenderer
    let header = NSView()
    let titleLabel = NSTextField(labelWithString: String(localized: "Preview"))
    let detachButton = NSButton(title: String(localized: "Detach"), target: nil, action: nil)
    static let headerHeight: CGFloat = 24
    private var headerColor = NSColor.windowBackgroundColor

    init(renderer: PreviewRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        header.wantsLayer = true
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        detachButton.bezelStyle = .recessed
        detachButton.controlSize = .small
        detachButton.font = .systemFont(ofSize: 11)
        header.addSubview(titleLabel)
        header.addSubview(detachButton)
        addSubview(header)
        addSubview(renderer.view)
        setDetached(false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// Swaps in another renderer (the language changed to one it doesn't draw).
    func replaceRenderer(_ r: PreviewRenderer) {
        renderer.view.removeFromSuperview()
        renderer = r
        addSubview(r.view)
        needsLayout = true
    }

    func setDetached(_ detached: Bool) {
        detachButton.title = detached ? String(localized: "Attach") : String(localized: "Detach")
        detachButton.toolTip = detached ? String(localized: "Dock the preview beside the text again (⇧⌥⌘P)")
                                        : String(localized: "Move the preview into its own window (⇧⌥⌘P)")
        needsLayout = true
    }

    func applyPalette(_ p: EditorPalette) {
        headerColor = NSColor(hex: p.statusBar)
        header.layer?.backgroundColor = headerColor.cgColor
    }

    override func layout() {
        super.layout()
        let h = Self.headerHeight
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
        detachButton.sizeToFit()
        let bw = detachButton.frame.width
        detachButton.frame = NSRect(x: bounds.width - bw - 6, y: (h - detachButton.frame.height) / 2,
                                    width: bw, height: detachButton.frame.height)
        titleLabel.sizeToFit()
        titleLabel.frame.origin = NSPoint(x: 8, y: (h - titleLabel.frame.height) / 2)
        renderer.view.frame = NSRect(x: 0, y: h, width: bounds.width, height: max(0, bounds.height - h))
    }
}

/// The detached preview: its own resizable window, "<name> — Preview",
/// bound to its tab's document (it keeps showing that document whichever
/// tab is in front, and closes with it). Closing the window hides the
/// preview; View › Attach Preview docks it again.
@MainActor
final class PreviewWindowController: NSWindowController, NSWindowDelegate {
    private weak var tab: EditorWindowController?
    let pane: PreviewPane
    /// Closed by the app (attach, tab closing), not by the user.
    private var closingQuietly = false

    init(tab: EditorWindowController, pane: PreviewPane, frame: String?) {
        self.tab = tab
        self.pane = pane
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        w.tabbingMode = .disallowed
        w.isRestorable = false
        w.minSize = NSSize(width: 240, height: 160)
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        w.contentView = pane
        pane.setDetached(true)
        if let frame { w.setFrame(from: frame) } else if let tw = tab.window {
            // Beside the editor window, on the same screen.
            var f = w.frame
            f.size.height = tw.frame.height
            f.origin = NSPoint(x: tw.frame.maxX + 8, y: tw.frame.minY)
            if let s = (tw.screen ?? NSScreen.main)?.visibleFrame, f.maxX > s.maxX { f.origin.x = max(s.minX, s.maxX - f.width) }
            w.setFrame(f, display: false)
        }
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func updateTitle() {
        guard let tab else { return }
        window?.title = String(localized: "\(tab.doc.displayName) — Preview")
        window?.appearance = tab.window?.appearance
    }

    /// Closes the window, keeping the pane (attach) or not (tab closed).
    func closeQuietly() {
        closingQuietly = true
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        if !closingQuietly { tab?.previewWindowClosedByUser() }
    }

    func windowDidMove(_ notification: Notification) { tab.map { $0.onChange?($0) } }
    func windowDidResize(_ notification: Notification) { tab.map { $0.onChange?($0) } }
}
