import AppKit
import CedricCore
import QuartzCore

extension Notification.Name {
    /// The owl was moved: every tab's owl follows.
    static let cedricOwlPlacementChanged = Notification.Name("CedricOwlPlacementChanged")
}

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
        owl.onClick = { [weak self] in
            // Large documents: the owl only looks when clicked; with
            // nothing to say he shows his popover as usual.
            if let tab = self?.tab, tab.owlIdleForSpeed {
                OwlHub.shared.userAsked(in: tab) { [weak self] in self?.showPopover() }
            } else {
                self?.showPopover()
            }
        }
        owl.onDoubleClick = { [weak self] in self?.closePopover(); self?.resetPosition() }
        owl.onDragBegan = { [weak self] in self?.dragBegan() }
        owl.onDragMoved = { [weak self] d in self?.dragMoved(d) }
        owl.onDragEnded = { [weak self] in self?.dragEnded() }
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
        observers.append(nc.addObserver(forName: .cedricOwlPlacementChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.owl.isDragging else { return }
                self.overlay.needsLayout = true
            }
        })
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
        let size = NSSize(width: Self.size, height: Self.size)
        if let drag = dragStart {
            let o = OwlPlacement.clamp(NSPoint(x: drag.x + dragDelta.width, y: drag.y + dragDelta.height), size: size, in: b)
            owl.frame = NSRect(origin: o, size: size)
        } else if !settling {
            owl.frame = NSRect(origin: Settings.shared.owlPlacement.origin(in: b, size: size), size: size)
        }
        if let bg = tab?.palette.background {
            let c = NSColor(hex: bg)
            owl.onDarkBackground = (0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent) < 0.4
        }
        layoutBubble()
    }

    private func layoutBubble() {
        guard let bubble else { return }
        let size = bubble.fit()
        let place = OwlPlacement.bubble(owl: owl.frame, size: size, in: overlay.bounds)
        bubble.tailOnTop = place.tailOnTop
        bubble.tailAtLeft = place.tailAtLeft
        bubble.frame = place.frame
    }

    // MARK: Dragging

    /// The owl's frame origin when the drag began, and the pointer's movement since.
    private var dragStart: NSPoint?
    private var dragDelta = NSSize.zero
    /// The snap animation is running: layout leaves his frame alone.
    private var settling = false
    var isDragging: Bool { dragStart != nil }

    private func dragBegan() {
        closePopover()
        dragStart = owl.frame.origin
        dragDelta = .zero
        // Full strength while you hold him.
        owlFaded = false
        owl.alphaValue = 1
    }

    private func dragMoved(_ d: NSSize) {
        dragDelta = d
        layoutViews()
    }

    private func dragEnded() {
        let size = owl.frame.size
        let place = OwlPlacement.snapped(origin: owl.frame.origin, size: size, in: overlay.bounds)
        dragStart = nil
        dragDelta = .zero
        moveTo(place)
    }

    /// Double-click, or "Reset Position" in his popover: back bottom right.
    func resetPosition() {
        moveTo(.default)
    }

    /// Saves the placement and slides him there.
    func moveTo(_ place: OwlPlacement) {
        Settings.shared.owlPlacement = place
        let target = NSRect(origin: place.origin(in: overlay.bounds, size: owl.frame.size), size: owl.frame.size)
        if canAnimate {
            settling = true
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                owl.animator().frame = target
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    self?.settling = false
                    self?.layoutViews()
                }
            })
        } else {
            owl.frame = target
        }
        layoutBubble()
        NotificationCenter.default.post(name: .cedricOwlPlacementChanged, object: self)
        // Never left sitting on the caret: fade if he landed near it.
        caretMoved(byUser: true)
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
        caretMoved(byUser: true)
    }

    func noteSave() { owl.flap() }

    func setThinking(_ on: Bool) {
        guard bubble == nil else { return }
        owl.setPose(on ? .thinking : .idle)
    }

    // MARK: Keeping out of the way

    /// Just turned on: shown at full strength, whatever the window's
    /// occlusion state or where the caret is, until the user next types
    /// or moves the caret.
    private(set) var holdVisible = true

    /// Called when the owl is turned on (View › Show Cedric the Owl, or a
    /// new tab with the owl on): lay it out and show it now.
    func appeared() {
        holdVisible = true
        owlFaded = false
        owl.isHidden = false
        owl.alphaValue = 1
        overlay.isHidden = false
        overlay.alphaValue = 1
        if owl.pose == .sleepy { owl.setPose(.idle) }
        overlay.superview?.needsLayout = true
        overlay.superview?.layoutSubtreeIfNeeded()
        layoutViews()
        owl.needsDisplay = true
    }

    /// Fades the owl (and the bubble) while the caret is close to them.
    /// `byUser`: a selection change or typing (ends the just-turned-on hold).
    func caretMoved(byUser: Bool = false) {
        if byUser { holdVisible = false }
        guard !holdVisible || bubble != nil, !isDragging else { return }
        guard let tv = tab?.textView, let window = tv.window else { return }
        let sel = tv.selectedRange()
        let caretAt = sel.location + sel.length
        // In a chunked long line (large mode), a caret scrolled out of
        // view can't be near the owl. (Asking TextKit for its rect lays
        // out up to it, which re-anchored the viewport there: scrolling
        // stalled near the caret.)
        let caret: NSRect
        if tv.contentStorage?.chunkLimit != nil, let vis = tv.visibleCharacterRange, !NSLocationInRange(caretAt, NSRange(location: vis.location, length: vis.length + 1)) {
            caret = NSRect(x: -10_000, y: -10_000, width: 0, height: 0)
        } else {
            let screen = tv.firstRect(forCharacterRange: NSRange(location: caretAt, length: 0), actualRange: nil)
            guard screen != .zero else { return }
            caret = overlay.convert(window.convertFromScreen(screen), from: nil)
        }
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

    // MARK: Typos

    static let typoFixID = "spelling.fixTypos"
    static let wholeJSONInvalidID = "rules.json-whole-invalid"

    /// Prose with three or more fixable misspellings in view: "Fix 3
    /// typos?", applying the first suggestion for each as one undo step
    /// (through `applyPresented`, like any hint with a replacement). Once
    /// per document unless snoozed; never over another bubble, while
    /// quiet, or when turned off with "Don't show again".
    @discardableResult
    func offerTypoFix(_ spelling: EditorSpelling, tab: EditorWindowController) -> Bool {
        let hub = OwlHub.shared
        guard bubble == nil, !popoverShown, !hub.coordinator.isQuiet else { return false }
        let window = tab.owlContextWindow()
        let ctx = window.context
        let probe = OwlHint(id: Self.typoFixID, kind: .fix, title: "", source: "rules")
        guard hub.coordinator.isEligible(probe, documentID: tab.doc.id) else { return false }
        // Only in prose: in a log or a list of settings, Fix All would
        // rewrite data (`dur=0ms` → `due=0ms`).
        guard SpellScope.offersTypoFix(ctx.text as NSString, language: tab.doc.language,
                                       fileName: tab.doc.fileURL?.lastPathComponent) else { return false }
        // Only what the owl can see in his context window.
        let ctxRange = NSRange(location: ctx.textStart, length: (ctx.text as NSString).length)
        let found = spelling.misspellings(in: ctxRange)
        guard let fix = spelling.typoFix(found) else { return false }
        let local = NSRange(location: fix.range.location - ctx.textStart, length: fix.range.length)
        guard local.location >= 0, NSMaxRange(local) <= (ctx.text as NSString).length else { return false }
        let hint = OwlHint(id: Self.typoFixID, kind: .fix, title: String(localized: "Fix \(fix.count) typos?"),
                           detail: String(localized: "Fix Typos… goes through them one by one; Fix All uses the first suggestion for each, as one undo step."),
                           range: local, replacement: fix.replacement, source: "rules")
        hub.coordinator.markShown(hint, documentID: tab.doc.id)
        present(hint, context: ctx)
        return true
    }

    private func buttons(for hint: OwlHint, tab: EditorWindowController) -> [OwlBubble.Button] {
        let hub = OwlHub.shared
        if hint.id == RulesHintProvider.letterID {
            return [.init(title: String(localized: "No thanks, I’m an owl"), isDefault: false) { [weak self] in self?.hideBubble() }]
        }
        if GrammarMap.isGrammarHint(hint.id) {
            // Grammar (Grammar.swift): Fix it (one undo step), the
            // step-through, and off for this file or everywhere. The close
            // box is "Not now".
            var out: [OwlBubble.Button] = []
            if hint.replacement != nil {
                out.append(.init(title: String(localized: "Fix it"), isDefault: true) { [weak self] in _ = self?.applyPresented() })
            }
            out.append(.init(title: String(localized: "Fix Grammar…"), isDefault: hint.replacement == nil) { [weak self, weak tab] in
                self?.hideBubble(); tab?.startGrammarStep()
            })
            out.append(.init(title: String(localized: "Not in This File"), isDefault: false) { [weak self, weak tab] in
                tab?.grammar.hintsOffHere = true; self?.hideBubble()
            })
            out.append(.init(title: String(localized: "Don’t show again"), isDefault: false) { [weak self] in
                hub.coordinator.neverShowAgain(GrammarMap.globalID); self?.hideBubble()
            })
            return out
        }
        var out: [OwlBubble.Button] = []
        if hint.id == RulesHintProvider.jsonID, hint.replacement == nil {
            // A long one-line JSON file, only its start in view: Fix it
            // checks and formats the whole file.
            out.append(.init(title: String(localized: "Fix it"), isDefault: true) { [weak self, weak tab] in
                self?.hideBubble()
                tab?.formatWholeJSON { [weak self, weak tab] problem in
                    guard let self, let tab else { return }
                    let h = OwlHint(id: Self.wholeJSONInvalidID, kind: .warning,
                                    title: String(localized: "The whole file isn’t valid JSON, so it wasn’t formatted."),
                                    detail: problem, source: "rules")
                    self.present(h, context: tab.owlContextWindow().context)
                }
            })
        } else if hint.id == Self.typoFixID {
            // One at a time (the step-through), or all at once as before.
            out.append(.init(title: String(localized: "Fix Typos…"), isDefault: true) { [weak self, weak tab] in
                self?.hideBubble(); tab?.startSpellStep()
            })
            out.append(.init(title: String(localized: "Fix All"), isDefault: false) { [weak self] in _ = self?.applyPresented() })
        } else if hint.replacement != nil {
            out.append(.init(title: String(localized: "Fix it"), isDefault: true) { [weak self, weak tab] in
                guard let self, self.applyPresented() else { return }
                // A to-do list in checkboxes reads best coloured as Markdown.
                if hint.id == RulesHintProvider.todoListID, let tab, tab.doc.language == .plain { tab.setLanguage(.markdown) }
            })
            if hint.id == RulesHintProvider.duplicateWordID {
                // Where it is, before fixing blind: selects the doubled words.
                out.append(.init(title: String(localized: "Show Me"), isDefault: false) { [weak self] in self?.showPresented() })
            }
        } else if let language = RulesHintProvider.guessedLanguage(hint) {
            out.append(.init(title: String(localized: "Use \(language.displayName)"), isDefault: true) { [weak self, weak tab] in
                tab?.setLanguage(language); self?.hideBubble()
            })
        } else if hint.range != nil, hint.id != RulesHintProvider.reloadID, hint.id != RulesHintProvider.saveCopyID {
            out.append(.init(title: String(localized: "Show Me"), isDefault: true) { [weak self] in self?.showPresented() })
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
        let grammar = GrammarMap.isGrammarHint(hint.id)
        let b = OwlBubble(hint: hint, buttons: buttons, onClose: onlyButton ? nil : { [weak self] in
            if grammar { OwlHub.shared.coordinator.snooze(hint.id) }
            self?.hideBubble()
        })
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

    /// Show Me: selects the text the hint is about and scrolls to it, if
    /// it is still what the provider saw.
    @discardableResult
    func showPresented() -> Bool {
        defer { hideBubble() }
        guard let p = presented, let range = p.range, let expected = p.expected, let tv = tab?.textView else { return false }
        let ns = tv.string as NSString
        guard NSMaxRange(range) <= ns.length, ns.substring(with: range) == expected else { NSSound.beep(); return false }
        // A doubled word: the words themselves ("the the"), not the span
        // the fix rewrites (which starts after the first one).
        let target = p.hint.id == RulesHintProvider.duplicateWordID
            ? RulesHintProvider.doubledWordFocus(ns, hintRange: range) ?? range : range
        tv.setSelectedRange(target)
        tv.scrollRangeToVisible(target)
        tv.window?.makeFirstResponder(tv)
        return true
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
        if let status = hub.ai.statusLine() {
            let l = NSTextField(wrappingLabelWithString: status)
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            l.preferredMaxLayoutWidth = 260
            stack.addArrangedSubview(l)
        }
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
        if hub.canAskAI, let tab, !tab.owlIdleForSpeed {
            let ask = NSButton(title: String(localized: "Ask AI Now"), target: self, action: #selector(askAINow))
            ask.controlSize = .small
            ask.toolTip = String(localized: "Checks the text in view with the AI once, now.")
            stack.addArrangedSubview(ask)
        }
        // Grammar found in view: the owl clicked shows it now, whatever the rate limit.
        if let tab, tab.grammar.issuesInView > 0 {
            let g = NSButton(title: String(localized: "Grammar Hint"), target: self, action: #selector(grammarHintNow))
            g.controlSize = .small
            g.toolTip = String(localized: "Shows a grammar suggestion for the text in view.")
            stack.addArrangedSubview(g)
        }
        let hide = NSButton(title: String(localized: "Hide Cedric"), target: self, action: #selector(hideOwl))
        hide.controlSize = .small
        let reset = NSButton(title: String(localized: "Reset Position"), target: self, action: #selector(resetFromPopover))
        reset.controlSize = .small
        reset.isEnabled = Settings.shared.owlPlacement != .default
        let row = NSStackView(views: [quiet, reset, hide])
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
    /// A button in the open popover (the checks).
    func popoverButton(_ title: String) -> NSButton? {
        func find(_ v: NSView?) -> NSButton? {
            guard let v else { return nil }
            if let b = v as? NSButton, b.title == title { return b }
            for s in v.subviews { if let b = find(s) { return b } }
            return nil
        }
        return find(popover?.contentViewController?.view)
    }
    /// At once, no fade: he's being picked up, or reset.
    func closePopover() {
        popover?.animates = false
        popover?.close()
        popover = nil
    }

    @objc private func quietHour() {
        OwlHub.shared.coordinator.quiet(for: 3600)
        popover?.close()
        hideBubble()
    }

    @objc private func resume() {
        OwlHub.shared.endQuiet()
        popover?.close()
    }

    @objc func askAINow() {
        closePopover()   // at once: a fast answer must not find it still up
        guard let tab else { return }
        OwlHub.shared.askAI(in: tab)
    }

    @objc func grammarHintNow() {
        closePopover()
        hideBubble()
        tab?.grammar.offerHint(userAsked: true)
    }

    @objc private func resetFromPopover() {
        popover?.close()
        resetPosition()
    }

    @objc private func hideOwl() {
        popover?.close()
        Settings.shared.showOwl = false
    }
}

extension EditorWindowController {
    /// The owl's Fix it for a long one-line JSON file: validates and
    /// pretty-prints the whole text off the main thread, then replaces it
    /// as one undo step, if the text hasn't changed meanwhile. `invalid`
    /// gets the parser's message when the whole file isn't valid JSON.
    func formatWholeJSON(invalid: @escaping @MainActor (String) -> Void) {
        let text = textView.string
        guard (text as NSString).length <= LargeDocument.sizeThreshold, textView.isEditable else { NSSound.beep(); return }
        let count = doc.changeCount
        DispatchQueue.global(qos: .userInitiated).async {
            let result = RulesHintProvider.formatWholeJSON(text)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, self.window != nil, self.doc.changeCount == count else { return }
                    switch result {
                    case .success(let pretty):
                        let all = NSRange(location: 0, length: (self.textView.string as NSString).length)
                        self.replaceAsOneStep(all, with: pretty, actionName: String(localized: "Format JSON"))
                        self.textView.setSelectedRange(NSRange(location: 0, length: 0))
                        self.textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
                    case .failure(let e):
                        invalid(e.errorDescription ?? String(describing: e))
                    }
                }
            }
        }
    }
}
