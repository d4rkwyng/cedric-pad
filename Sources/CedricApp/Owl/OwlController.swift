import AppKit
import CedricCore

/// Holds the owl and its bubble over the editor's bottom-right corner.
/// Clicks pass through everywhere else.
final class OwlOverlay: NSView {
    weak var controller: OwlController?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v === self ? nil : v
    }

    override func layout() {
        super.layout()
        controller?.layoutViews()
    }
}

/// One tab's owl: its poses, idle behaviour, the bubble and the popover.
///
/// Cost when idle: one one-shot `Timer` for the next blink or polish (4–9 s
/// away), and none at all while the owl is asleep, the window is hidden or
/// occluded, or the app is inactive. Blinks and flaps run a short frame
/// timer only while they play.
@MainActor
final class OwlController: NSObject, NSPopoverDelegate {
    static let size: CGFloat = 72

    private weak var tab: EditorWindowController?
    let overlay = OwlOverlay()
    let owl = OwlView(frame: NSRect(x: 0, y: 0, width: OwlController.size, height: OwlController.size))
    private(set) var bubble: OwlBubble?
    private var presented: (hint: OwlHint, range: NSRange?, expected: String?)?
    /// The hint in the bubble and its range in the document (checks).
    var presentedHint: (hint: OwlHint, documentRange: NSRange?)? { presented.map { ($0.hint, $0.range) } }
    private var observers: [NSObjectProtocol] = []
    private var idleTimer: Timer?
    private(set) var lastTyping = Date()
    private var popover: NSPopover?
    let sleepAfter: TimeInterval = ProcessInfo.processInfo.environment["CEDRIC_OWL_SLEEP_AFTER"].flatMap(Double.init) ?? 300
    /// Owl and bubble faded because the caret is near them.
    private(set) var owlFaded = false
    private(set) var bubbleFaded = false
    /// Counts for the idle-cost check.
    private(set) var idleTicks = 0

    init(tab: EditorWindowController) {
        self.tab = tab
        super.init()
        overlay.controller = self
        overlay.addSubview(owl)
        owl.onClick = { [weak self] in self?.showPopover() }
        let nc = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateTimer() }
            })
        }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            observers.append(nc.addObserver(forName: name, object: tab.window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateTimer() }
            })
        }
        updateTimer()
    }

    func detach() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        idleTimer?.invalidate()
        idleTimer = nil
        owl.stopSequence()
        popover?.close()
        overlay.removeFromSuperview()
    }

    // MARK: Layout

    func layoutViews() {
        let b = overlay.bounds
        let s = Self.size
        owl.frame = NSRect(x: b.maxX - s - 6, y: 2, width: s, height: s)
        if let bubble {
            let size = bubble.fit()
            // Right-aligned over the owl's head, covering the little "…"
            // bubble in the talking art; the tail points down at the owl.
            let x = max(4, b.maxX - size.width - 4)
            bubble.frame = NSRect(x: x, y: owl.frame.maxY - s * 0.3, width: size.width, height: size.height)
        }
    }

    // MARK: Idle behaviour

    /// The in-process check runs with the screen locked, where the window
    /// server reports every window occluded and the app inactive.
    static var assumeVisible = false

    /// The window can be seen and the app is in front.
    var canAnimate: Bool {
        if Self.assumeVisible { return tab?.window?.isVisible == true }
        guard let w = tab?.window, NSApp.isActive, !NSApp.isHidden, w.isVisible, !w.isMiniaturized else { return false }
        return w.occlusionState.contains(.visible)
    }

    var timerScheduled: Bool { idleTimer?.isValid == true }

    func updateTimer() {
        guard canAnimate else {
            idleTimer?.invalidate()
            idleTimer = nil
            owl.stopSequence()
            return
        }
        if owl.pose == .sleepy { return }
        if Date().timeIntervalSince(lastTyping) >= sleepAfter { owl.setPose(.sleepy); return }
        if idleTimer?.isValid != true { scheduleIdle() }
    }

    private func scheduleIdle() {
        let untilSleep = sleepAfter - Date().timeIntervalSince(lastTyping)
        let next = max(0.5, min(Double.random(in: 4...9), untilSleep))
        let t = Timer(timeInterval: next, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.idleTick() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        idleTimer = t
    }

    private func idleTick() {
        idleTimer = nil
        idleTicks += 1
        guard canAnimate else { return }
        if Date().timeIntervalSince(lastTyping) >= sleepAfter {
            if bubble == nil { owl.setPose(.sleepy) }
            return // asleep: no timer until typing wakes it
        }
        if owl.pose == .idle {
            if Int.random(in: 0..<8) == 0 { owl.polish() } else { owl.blink() }
        }
        scheduleIdle()
    }

    func noteTyping() {
        lastTyping = Date()
        if owl.pose == .sleepy { owl.setPose(.idle) }
        updateTimer()
        caretMoved()
    }

    func noteSave() { owl.flap() }

    func setThinking(_ on: Bool) {
        guard bubble == nil else { return }
        owl.setPose(on ? .thinking : .idle)
    }

    // MARK: Keeping out of the way

    /// Fades the owl (and the bubble) while the caret is close to them.
    func caretMoved() {
        guard let tv = tab?.textView, let window = tv.window else { return }
        let sel = tv.selectedRange()
        let screen = tv.firstRect(forCharacterRange: NSRange(location: sel.location + sel.length, length: 0), actualRange: nil)
        guard screen != .zero else { return }
        let caret = overlay.convert(window.convertFromScreen(screen), from: nil)
        let nearOwl = caret.insetBy(dx: -28, dy: -18).intersects(owl.frame)
        let nearBubble = bubble.map { caret.insetBy(dx: -12, dy: -12).intersects($0.frame) } ?? false
        if nearOwl != owlFaded {
            owlFaded = nearOwl
            fade(owl, to: nearOwl ? 0.12 : 1)
        }
        if let bubble, nearBubble != bubbleFaded {
            bubbleFaded = nearBubble
            fade(bubble, to: nearBubble ? 0.15 : 1)
        }
    }

    private func fade(_ v: NSView, to alpha: CGFloat) {
        if canAnimate {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                v.animator().alphaValue = alpha
            }
        } else {
            v.alphaValue = alpha
        }
    }

    // MARK: Hints

    /// Shows a hint the coordinator picked (from the rules or the AI).
    /// `context.textStart` maps the hint's range (context-window
    /// coordinates) back into the document.
    func present(_ hint: OwlHint, context: OwlContext) {
        guard let tab else { return }
        var docRange: NSRange?, expected: String?
        if let r = hint.range {
            let ctx = context.text as NSString
            guard NSMaxRange(r) <= ctx.length else { return }
            docRange = OwlCoordinator.documentRange(hint, context: context) ?? r
            expected = ctx.substring(with: r)
        }
        presented = (hint, docRange, expected)
        showBubble(hint, buttons: buttons(for: hint, tab: tab))
    }

    private func buttons(for hint: OwlHint, tab: EditorWindowController) -> [OwlBubble.Button] {
        let hub = OwlHub.shared
        if hint.id == RulesHintProvider.letterID {
            return [.init(title: String(localized: "No thanks, I’m an owl"), isDefault: false) { [weak self] in self?.hideBubble() }]
        }
        var out: [OwlBubble.Button] = []
        if hint.replacement != nil {
            out.append(.init(title: String(localized: "Apply"), isDefault: true) { [weak self] in self?.applyPresented() })
        } else if hint.id == RulesHintProvider.reloadID {
            out.append(.init(title: String(localized: "Reload"), isDefault: true) { [weak self, weak tab] in tab?.reloadFromDisk(); self?.hideBubble() })
        } else if hint.id == RulesHintProvider.saveCopyID {
            out.append(.init(title: String(localized: "Save a Copy…"), isDefault: true) { [weak self, weak tab] in self?.hideBubble(); tab?.saveCopy() })
        }
        out.append(.init(title: String(localized: "Not now"), isDefault: false) { [weak self] in
            hub.coordinator.snooze(hint.id); self?.hideBubble()
        })
        out.append(.init(title: String(localized: "Don’t show again"), isDefault: false) { [weak self] in
            hub.coordinator.neverShowAgain(hint.id); self?.hideBubble()
        })
        return out
    }

    private func showBubble(_ hint: OwlHint, buttons: [OwlBubble.Button]) {
        bubble?.removeFromSuperview()
        let onlyButton = hint.id == RulesHintProvider.letterID
        let b = OwlBubble(hint: hint, buttons: buttons, onClose: onlyButton ? nil : { [weak self] in self?.hideBubble() })
        overlay.addSubview(b, positioned: .above, relativeTo: owl)
        bubble = b
        bubbleFaded = false
        owl.setPose(.talking)
        layoutViews()
        caretMoved()
    }

    func hideBubble() {
        bubble?.removeFromSuperview()
        bubble = nil
        presented = nil
        bubbleFaded = false
        owl.setPose(.idle)
        updateTimer()
    }

    /// Apply: the replacement as one undo step, only if the text it was
    /// computed from is still there.
    @discardableResult
    func applyPresented() -> Bool {
        defer { hideBubble() }
        guard let p = presented, let range = p.range, let expected = p.expected, let rep = p.hint.replacement,
              let tv = tab?.textView, let storage = tv.textStorage else { return false }
        let ns = tv.string as NSString
        guard NSMaxRange(range) <= ns.length, ns.substring(with: range) == expected else {
            NSSound.beep()
            return false
        }
        let edit = OwlEdit.minimal(in: ns, range: range, replacement: rep)
        tv.breakUndoCoalescing()
        guard tv.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return false }
        // In the theme's base attributes, like typed text: never the colour
        // of the text it replaces (the highlighter recolours it shortly).
        storage.replaceCharacters(in: edit.range, with: NSAttributedString(string: edit.replacement, attributes: tab?.baseAttributes() ?? [:]))
        tv.didChangeText()
        tv.breakUndoCoalescing()
        tv.undoManager?.setActionName(p.hint.title)
        return true
    }

    // MARK: Popover

    private func showPopover() {
        if let popover, popover.isShown { popover.close(); return }
        let hub = OwlHub.shared
        let vc = NSViewController()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        let head = NSTextField(labelWithString: String(localized: "Recent hints"))
        head.font = .systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(head)
        let recent = hub.coordinator.recent
        if recent.isEmpty {
            let none = NSTextField(labelWithString: String(localized: "None yet. Cedric is watching quietly."))
            none.textColor = .secondaryLabelColor
            none.font = .systemFont(ofSize: 11)
            stack.addArrangedSubview(none)
        }
        let f = DateFormatter()
        f.timeStyle = .short
        for r in recent {
            let l = NSTextField(wrappingLabelWithString: "\(f.string(from: r.date))  \(r.hint.title)")
            l.font = .systemFont(ofSize: 11)
            l.preferredMaxLayoutWidth = 260
            stack.addArrangedSubview(l)
        }
        let quiet: NSButton
        if hub.coordinator.isQuiet {
            quiet = NSButton(title: String(localized: "Resume Hints"), target: self, action: #selector(resume))
        } else {
            quiet = NSButton(title: String(localized: "Quiet for 1 Hour"), target: self, action: #selector(quietHour))
        }
        quiet.controlSize = .small
        let hide = NSButton(title: String(localized: "Hide Cedric"), target: self, action: #selector(hideOwl))
        hide.controlSize = .small
        let row = NSStackView(views: [quiet, hide])
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(row)
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        vc.view = stack
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = vc
        p.delegate = self
        p.show(relativeTo: owl.bounds, of: owl, preferredEdge: .maxY)
        popover = p
    }

    var popoverShown: Bool { popover?.isShown == true }

    @objc private func quietHour() {
        OwlHub.shared.coordinator.quiet(for: 3600)
        popover?.close()
        hideBubble()
    }

    @objc private func resume() {
        OwlHub.shared.endQuiet()
        popover?.close()
    }

    @objc private func hideOwl() {
        popover?.close()
        Settings.shared.showOwl = false
    }
}
