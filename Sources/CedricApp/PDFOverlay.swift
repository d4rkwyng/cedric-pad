import AppKit
import CedricCore

/// The PDF tab's floating reader controls: a capsule at the bottom centre
/// of the pages, as in Preview. Previous / next page, "page N of M" (an
/// editable field: Return jumps), zoom out / in, actual size, fit width,
/// fit page, the thumbnails sidebar, find, rotate left / right (the view
/// only: the file is never written) and Open in Preview.
///
/// It fades out `PDFReader.AutoHide.delay` seconds after the last mouse
/// move or scroll and comes back on the next one; it stays while the
/// pointer is on it or its page field is being edited. With Reduce Motion
/// it appears and disappears without the fade. Hidden, it takes no clicks,
/// so it never covers the page for good. Built after the first frame.
@MainActor
final class PDFOverlay: NSView {
    enum Control: String, CaseIterable {
        case previous, next, zoomOut, zoomIn, actualSize, fitWidth, fitPage, thumbnails, find, rotateLeft, rotateRight, openInPreview
    }

    private(set) var buttons: [Control: NSButton] = [:]
    let pageField = NSTextField()
    let ofLabel = NSTextField(labelWithString: "")
    /// A solid, slightly see-through fill in the theme's bar colour (not a
    /// vibrancy material: it reads the same over any page, and in snapshots).
    private let background = NSView()
    /// The groups, left to right, with the priority PDFReader.visibleGroups drops them by.
    private var groups: [(views: [NSView], priority: Int)] = []
    private(set) var groupShown: [Bool] = []
    var onControl: ((Control) -> Void)?
    /// Return in the page field: the text typed.
    var onPageEntered: ((String) -> Void)?

    static let height: CGFloat = 34
    static let buttonSize = NSSize(width: 26, height: 24)
    static let groupGap: CGFloat = 10
    static let fieldWidth: CGFloat = 40

    /// Fading state (for the checks): shown means visible or fading in.
    private(set) var shown = true
    private(set) var hovering = false
    private var lastActivity = Date()
    private var hideTimer: Timer?
    let autoHide = PDFReader.AutoHide()
    /// Reduce Motion: no fade (the checks can force it).
    static var reduceMotionOverride: Bool?
    static var reduceMotion: Bool { reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Self.height / 2
        layer?.masksToBounds = true
        background.wantsLayer = true
        background.layer?.cornerRadius = Self.height / 2
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 1
        addSubview(background)
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel(String(localized: "PDF controls"))

        func b(_ c: Control) -> NSButton {
            let (sym, label, tip) = Self.look(c)
            let button = NSButton(title: "", target: self, action: #selector(pressed(_:)))
            button.bezelStyle = .recessed
            button.showsBorderOnlyWhileMouseInside = true
            button.isBordered = true
            button.imagePosition = .imageOnly
            button.image = NSImage(systemSymbolName: sym, accessibilityDescription: label)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            if button.image == nil { button.title = label; button.imagePosition = .noImage }
            button.toolTip = tip
            button.setAccessibilityLabel(label)
            button.identifier = NSUserInterfaceItemIdentifier("pdfoverlay.\(c.rawValue)")
            buttons[c] = button
            addSubview(button)
            return button
        }
        pageField.alignment = .center
        pageField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        pageField.controlSize = .small
        pageField.bezelStyle = .roundedBezel
        pageField.target = self
        pageField.action = #selector(pageReturn(_:))
        pageField.toolTip = String(localized: "Page number: type one and press Return")
        pageField.setAccessibilityLabel(String(localized: "Page number"))
        ofLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        ofLabel.textColor = .secondaryLabelColor
        addSubview(pageField)
        addSubview(ofLabel)
        groups = [
            ([b(.previous), pageField, ofLabel, b(.next)], 0),
            ([b(.zoomOut), b(.zoomIn)], 1),
            ([b(.actualSize), b(.fitWidth), b(.fitPage)], 3),
            ([b(.thumbnails), b(.find)], 2),
            ([b(.rotateLeft), b(.rotateRight)], 4),
            ([b(.openInPreview)], 5),
        ]
        groupShown = groups.map { _ in true }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    static func look(_ c: Control) -> (String, String, String) {
        switch c {
        case .previous: return ("chevron.left", String(localized: "Previous Page"), String(localized: "Previous page (←)"))
        case .next: return ("chevron.right", String(localized: "Next Page"), String(localized: "Next page (→)"))
        case .zoomOut: return ("minus.magnifyingglass", String(localized: "Zoom Out"), String(localized: "Zoom out (⌘−)"))
        case .zoomIn: return ("plus.magnifyingglass", String(localized: "Zoom In"), String(localized: "Zoom in (⌘+)"))
        case .actualSize: return ("1.magnifyingglass", String(localized: "Actual Size"), String(localized: "Actual size (⌘0)"))
        case .fitWidth: return ("arrow.left.and.right", String(localized: "Fit Width"), String(localized: "Fit the page width to the window (⌘9)"))
        case .fitPage: return ("arrow.up.left.and.arrow.down.right", String(localized: "Fit Page"), String(localized: "Show the whole page"))
        case .thumbnails: return ("sidebar.left", String(localized: "Thumbnails"), String(localized: "Show or hide page thumbnails (⌥⌘B)"))
        case .find: return ("magnifyingglass", String(localized: "Find"), String(localized: "Find in the PDF (⌘F)"))
        case .rotateLeft: return ("rotate.left", String(localized: "Rotate Left"), String(localized: "Rotate the view left (the file isn’t changed)"))
        case .rotateRight: return ("rotate.right", String(localized: "Rotate Right"), String(localized: "Rotate the view right (the file isn’t changed)"))
        case .openInPreview: return ("arrow.up.forward.app", String(localized: "Open in Preview"), String(localized: "Open the PDF in Preview"))
        }
    }

    @objc private func pressed(_ sender: NSButton) {
        guard let c = buttons.first(where: { $0.value === sender })?.key else { return }
        noteActivity()
        onControl?(c)
    }

    @objc private func pageReturn(_ sender: NSTextField) {
        noteActivity()
        onPageEntered?(sender.stringValue)
    }

    /// Page N of M; previous/next off at the ends.
    func update(page index: Int, pageCount: Int) {
        if pageField.currentEditor() == nil { pageField.stringValue = "\(index + 1)" }
        let label = PDFReader.pageLabel(index: index, pageCount: pageCount)
        if ofLabel.stringValue != label {
            ofLabel.stringValue = label
            needsLayout = true
            superview?.needsLayout = true
        }
        pageField.setAccessibilityValueDescription(String(localized: "Page \(index + 1) of \(pageCount)"))
        buttons[.previous]?.isEnabled = index > 0
        buttons[.next]?.isEnabled = index < pageCount - 1
    }

    /// The theme: the status bar's colour, its appearance for the symbols.
    func applyPalette(_ p: EditorPalette) {
        appearance = NSAppearance(named: p.isDark ? .darkAqua : .aqua)
        background.layer?.backgroundColor = NSColor(hex: p.statusBar).withAlphaComponent(0.94).cgColor
        background.layer?.borderColor = (p.isDark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.14)).cgColor
        shadow = nil
    }

    func setThumbnailsOn(_ on: Bool) {
        buttons[.thumbnails]?.contentTintColor = on ? .controlAccentColor : nil
    }

    // MARK: Size and layout

    private func width(_ v: NSView) -> CGFloat {
        if v === pageField { return Self.fieldWidth }
        if v === ofLabel { return ceil(ofLabel.attributedStringValue.size().width) + 6 }
        return Self.buttonSize.width
    }

    private func groupWidth(_ g: [NSView]) -> CGFloat { g.map(width).reduce(0, +) }

    /// The capsule's width for `available` points (some groups dropped if narrow).
    func fit(available: CGFloat) -> CGFloat {
        let pad: CGFloat = 12
        let gs = groups.map { PDFReader.Group(width: Double(groupWidth($0.views)), priority: $0.priority) }
        groupShown = PDFReader.visibleGroups(gs, spacing: Double(Self.groupGap), available: Double(available - 2 * pad))
        for (g, on) in zip(groups, groupShown) { g.views.forEach { $0.isHidden = !on } }
        let shownW = zip(groups, groupShown).filter(\.1).map { groupWidth($0.0.views) }
        return shownW.reduce(0, +) + Self.groupGap * CGFloat(max(0, shownW.count - 1)) + 2 * pad
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        var x: CGFloat = 12
        for (g, on) in zip(groups, groupShown) where on {
            for v in g.views {
                let w = width(v)
                let h: CGFloat = v === pageField ? 22 : (v === ofLabel ? ofLabel.attributedStringValue.size().height + 2 : Self.buttonSize.height)
                v.frame = NSRect(x: x, y: ((bounds.height - h) / 2).rounded(), width: w, height: h)
                x += w
            }
            x += Self.groupGap
        }
    }

    // MARK: Auto-hide

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; show() }
    override func mouseExited(with event: NSEvent) { hovering = false; noteActivity() }

    /// The pointer moved or the pages scrolled: show it, and fade it after the delay.
    func noteActivity() {
        lastActivity = Date()
        show()
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: autoHide.delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideIfIdle() }
        }
    }

    private var editing: Bool { pageField.currentEditor() != nil }

    func hideIfIdle() {
        let idle = Date().timeIntervalSince(lastActivity)
        guard autoHide.shouldHide(idle: idle, hovering: hovering, editing: editing) else {
            // Still in use: look again after another delay.
            hideTimer?.invalidate()
            hideTimer = Timer.scheduledTimer(withTimeInterval: max(0.25, autoHide.delay - (hovering || editing ? 0 : idle)), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.hideIfIdle() }
            }
            return
        }
        hide()
    }

    func show() {
        guard !shown else { return }
        shown = true
        isHidden = false
        if Self.reduceMotion {
            alphaValue = 1
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                animator().alphaValue = 1
            }
        }
    }

    func hide() {
        guard shown else { return }
        shown = false
        if Self.reduceMotion {
            alphaValue = 0
            isHidden = true
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Shown again meanwhile: leave it.
                guard let self, !self.shown else { return }
                self.isHidden = true
            }
        })
    }

    func stop() {
        hideTimer?.invalidate()
        hideTimer = nil
        onControl = nil
        onPageEntered = nil
    }

    /// Hidden or fading: clicks go to the page underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { shown ? super.hitTest(point) : nil }
}
