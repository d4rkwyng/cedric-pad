import AppKit
import CedricCore

/// View › Writing Mode (0.4.0), per tab, off by default (kept in the
/// session with the tab, as a split or folds are):
///
/// - **Typewriter Scrolling** keeps the caret's line at the middle of the
///   view: one scroll on each selection change (and in place of
///   NSTextView's own scroll-to-caret), plus a bottom content inset so the
///   last line can reach the middle. No relayout: the scroll is a clip-view
///   origin. Animated only for a mouse move with Reduce Motion off.
/// - **Focus** dims everything but the caret's paragraph or sentence
///   (Focus on Paragraph / Sentence, an app setting). The dimming is a
///   TextKit 2 rendering attribute (`NSTextLayoutManager`'s temporary
///   foreground colour) on the visible text only, as the colouring is:
///   the text storage, undo and layout are untouched.
///
/// Off, nothing runs: the text view's scroll hook is nil and no rendering
/// attribute is set.
@MainActor
enum WritingMode {
    /// How strongly Focus dims (the theme's text colour at this alpha).
    static let dimAlpha: CGFloat = 0.32
    /// The checks force Reduce Motion on or off.
    static var reduceMotionOverride: Bool?
    static var reduceMotion: Bool { reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

extension EditorWindowController {
    /// Turns typewriter scrolling and Focus on or off for this tab.
    func setWriting(_ w: WritingModeState) {
        let old = editing.writing
        editing.writing = w
        for pane in panes { wireWriting(pane) }
        if let reason = largeReason, writingPaused { largeBar.show(reason, writingMode: !w.isOff) }
        if typewriterActive && !old.typewriter { typewriterScroll(animated: false) }
        if w.focus { applyFocusNow(force: true) } else if old.focus { clearFocus() }
        (NSApp.delegate as? AppDelegate)?.scheduleSessionSave()
    }

    /// For the session: nil when both are off.
    var sessionWriting: WritingModeState? { editing.writing.isOff ? nil : editing.writing }

    /// One pane's hooks and inset for the current switches (at a switch, and
    /// for the second pane of a split when it is made).
    func wireWriting(_ pane: EditorPane) {
        let on = typewriterActive
        editing.typewriterLast[ObjectIdentifier(pane.textView)] = nil
        pane.textView.onScrollRangeToVisible = on ? { [weak self, weak pane] _ in
            guard let self, let pane else { return false }
            self.typewriterScroll(in: pane, animated: false)
            return true
        } : nil
        updateTypewriterInset(pane)
    }

    /// Writing Mode pauses in large-document mode, as the colouring does
    /// (`extrasPaused`: "Turn On Anyway" resumes it). The switches stay as
    /// they are and act again once the document isn't large.
    var writingPaused: Bool { extrasPaused }
    var typewriterActive: Bool { editing.writing.typewriter && !writingPaused }

    /// Large mode came or went (LargeDocumentMode.swift), or a switch changed.
    func writingLargeModeChanged() {
        guard !editing.writing.isOff || !editing.focusDimmed.isEmpty || panes.contains(where: { $0.textView.onScrollRangeToVisible != nil }) else { return }
        for pane in panes { wireWriting(pane) }
        if writingPaused { if !editing.focusDimmed.isEmpty { clearFocus() } } else { applyFocusNow(force: true) }
    }

    /// The bottom inset that lets the last line reach the middle (0 when off).
    func updateTypewriterInset(_ pane: EditorPane) {
        let sv = pane.scrollView
        let font = pane.textView.font ?? Settings.shared.font
        let line = ceil(font.ascender - font.descender + font.leading)
        let inset = typewriterActive
            ? CGFloat(Typewriter.bottomInset(visibleHeight: Double(sv.contentView.bounds.height), lineHeight: Double(line))) : 0
        guard sv.contentInsets.bottom != inset else { return }
        sv.automaticallyAdjustsContentInsets = false
        var i = sv.contentInsets
        i.bottom = inset
        sv.contentInsets = i
    }

    /// The middle of the caret's line, in the text view's coordinates.
    func caretLineMidY(_ tv: EditorTextView, layout: Bool = false) -> CGFloat? {
        guard let tlm = tv.textLayoutManager, let tcm = tlm.textContentManager else { return nil }
        let sel = tv.selectedRange()
        let caret = sel.length == 0 ? sel.location : NSMaxRange(sel)
        var loc: NSTextLocation?
        // From the viewport's start when the caret is near it (as forEachSegment).
        if let vp = tlm.textViewportLayoutController.viewportRange {
            let vpStart = tv.offset(of: vp.location)
            if caret >= vpStart { loc = tcm.location(vp.location, offsetBy: caret - vpStart) }
        }
        if loc == nil { loc = tv.textRange(for: NSRange(location: caret, length: 0))?.location }
        guard let loc else { return nil }
        if layout {
            // Mid-keystroke the new text isn't laid out yet (that waits for
            // the display pass): lay out the caret's paragraph now.
            tlm.ensureLayout(for: NSTextRange(location: loc))
        }
        var rect: CGRect?
        tlm.enumerateTextSegments(in: NSTextRange(location: loc), type: .standard, options: [.rangeNotRequired]) { _, f, _, _ in
            rect = f
            return false
        }
        guard let r = rect else { return nil }
        return r.midY + tv.textContainerOrigin.y
    }

    /// Scrolls `pane` (the active one) so the caret's line is at the middle.
    func typewriterScroll(in pane: EditorPane? = nil, animated: Bool) {
        let pane = pane ?? activePane
        let tv = pane.textView
        guard typewriterActive else { return }
        // Called twice per key (the selection change, then NSTextView's
        // scroll to the caret): the second finds the same caret, text
        // length and scroll position, and returns at once.
        func state() -> [Int] {
            let b = pane.scrollView.contentView.bounds, sel = tv.selectedRange()
            return [sel.location, sel.length, tv.textStorage?.length ?? 0, Int(b.minY.rounded()), Int(b.height.rounded()), Int(b.width.rounded())]
        }
        if editing.typewriterLast[ObjectIdentifier(tv)] == state() { return }
        defer { editing.typewriterLast[ObjectIdentifier(tv)] = state() }
        editing.typewriterPasses += 1
        guard var mid = caretLineMidY(tv, layout: true) else { return }
        let sv = pane.scrollView, clip = sv.contentView
        updateTypewriterInset(pane)
        let visible = clip.bounds
        // The view's height lags new lines until the viewport is laid out:
        // only when the middle is past what it lets us scroll to is that
        // done here (a Return at the end, say), not on every key.
        let inset = sv.contentInsets.bottom
        let font = tv.font ?? Settings.shared.font
        let halfLine = ceil(font.ascender - font.descender + font.leading) / 2
        if mid - visible.height / 2 > tv.frame.height + inset - visible.height + halfLine, let tlm = tv.textLayoutManager {
            tlm.textViewportLayoutController.layoutViewport()
            editing.typewriterLayouts += 1
            mid = caretLineMidY(tv) ?? mid
        }
        guard let target = Typewriter.scrollTarget(caretMidY: Double(mid), visibleHeight: Double(visible.height), currentY: Double(visible.minY),
                                                   documentHeight: Double(tv.frame.height), bottomInset: Double(inset))
        else { return }
        let p = NSPoint(x: visible.minX, y: CGFloat(target))
        editing.typewriterScrolls += 1
        if animated && !WritingMode.reduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(p)
            } completionHandler: { [weak sv] in
                MainActor.assumeIsolated { if let sv { sv.reflectScrolledClipView(sv.contentView) } }
            }
        } else {
            clip.setBoundsOrigin(p)
            sv.reflectScrolledClipView(clip)
        }
    }

    /// After a selection change in the active pane (EditorWindowController).
    func writingSelectionChanged() {
        if editing.writing.typewriter {
            // A click moves the line to the middle smoothly; keys and typing jump.
            let t = NSApp.currentEvent?.type
            typewriterScroll(animated: t == .leftMouseUp || t == .leftMouseDown || t == .leftMouseDragged)
        }
        if editing.writing.focus { scheduleFocus() }
    }

    // MARK: Focus

    /// Coalesced to once per run-loop turn, after the colouring's pass.
    func scheduleFocus() {
        guard editing.writing.focus, !editing.focusPending else { return }
        editing.focusPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.editing.focusPending = false
            self.applyFocusNow()
        }
    }

    /// The range Focus keeps bright, from the active pane's caret.
    var focusRange: NSRange {
        let sel = textView.selectedRange()
        return FocusRange.range(Settings.shared.focusUnit, in: textView.string as NSString, caret: sel.location)
    }

    func applyFocusNow(force: Bool = false) {
        guard editing.writing.focus, !textView.hasMarkedText() else { return }
        // Large-document mode (a 636 K-character line…): paused, like the colouring.
        if writingPaused {
            if !editing.focusDimmed.isEmpty { clearFocus() }
            return
        }
        if force { editing.focusDimmed = [:]; editing.focusPrecheck = [:] }
        let focus = focusRange
        for pane in panes { applyFocus(focus, to: pane.textView) }
    }

    /// Dims the visible text outside `focus` in one view: the focus range
    /// loses the attribute, the rest of the visible text gets it. Text out
    /// of view is left as it is (it is set again when scrolled into view).
    private func applyFocus(_ focus: NSRange, to tv: EditorTextView) {
        let len = tv.textStorage?.length ?? 0
        let id = ObjectIdentifier(tv)
        // First the cheap test: the same focus (its end counted from the
        // text's end) and the view neither scrolled nor resized since the
        // last pass. Then even the visible range isn't looked up (near the
        // end of a 6 MB file that lookup was most of a key's cost).
        let b = tv.enclosingScrollView?.contentView.bounds ?? .zero
        let pre = [focus.location, len - NSMaxRange(focus), Int(b.minY.rounded()), Int(b.height.rounded()), Int(b.width.rounded())]
        if editing.focusPrecheck[id] == pre, editing.focusDimmed[id] != nil { return }
        editing.focusPrecheck[id] = pre
        editing.focusPasses += 1
        guard let tlm = tv.textLayoutManager, let vis = tv.visibleCharacterRange else { return }
        // Typing inside the focus moves nothing that is dimmed: the text
        // before the focus is the same, and so is the text after it counted
        // from the end (TextKit moves the attribute with its text). Then
        // there is nothing to do, and nothing is redrawn.
        let key = [focus.location, len - NSMaxRange(focus), vis.location, len - NSMaxRange(vis)]
        if editing.focusDimmed[id] == key { return }
        let color = NSColor(hex: tv.palette.foreground).withAlphaComponent(WritingMode.dimAlpha)
        let dims = FocusRange.dimmed(visible: vis, focus: focus)
        // Only what is in view; locations from the viewport's start, not the
        // document's (that walk grows with the offset: 6 MB in, it cost ms).
        let bright = NSIntersectionRange(NSIntersectionRange(focus, vis), NSRange(location: 0, length: len))
        guard let tcm = tlm.textContentManager, let vp = tlm.textViewportLayoutController.viewportRange else { return }
        let vpStart = tv.offset(of: vp.location)
        func textRange(_ r: NSRange) -> NSTextRange? {
            guard let a = tcm.location(vp.location, offsetBy: r.location - vpStart), let b = tcm.location(a, offsetBy: r.length) else { return nil }
            return NSTextRange(location: a, end: b)
        }
        if bright.length > 0, let tr = textRange(bright) { tlm.removeRenderingAttribute(.foregroundColor, for: tr) }
        for r in dims where NSMaxRange(r) <= len {
            if let tr = textRange(r) { tlm.addRenderingAttribute(.foregroundColor, value: color, for: tr) }
        }
        editing.focusDimmed[id] = key
    }

    func clearFocus() {
        for pane in panes {
            guard let tlm = pane.textView.textLayoutManager else { continue }
            tlm.removeRenderingAttribute(.foregroundColor, for: tlm.documentRange)
        }
        editing.focusDimmed = [:]
    }

    /// The ranges Focus dims now in `tv`'s visible text (the checks).
    func focusDimmedRanges(in tv: EditorTextView) -> [NSRange] {
        guard let tlm = tv.textLayoutManager else { return [] }
        var out: [NSRange] = []
        tlm.enumerateRenderingAttributes(from: tlm.documentRange.location, reverse: false) { _, attrs, range in
            if attrs[.foregroundColor] != nil {
                let s = tv.offset(of: range.location)
                out.append(NSRange(location: s, length: tv.offset(of: range.endLocation) - s))
            }
            return true
        }
        return out
    }
}

// MARK: - Menu

extension AppDelegate {
    @objc func toggleTypewriterMenu(_ sender: Any?) {
        guard let t = currentTab else { return }
        var w = t.editing.writing
        w.typewriter.toggle()
        t.setWriting(w)
    }

    @objc func toggleFocusMenu(_ sender: Any?) {
        guard let t = currentTab else { return }
        var w = t.editing.writing
        w.focus.toggle()
        t.setWriting(w)
    }

    @objc func pickFocusUnitMenu(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let u = FocusUnit(rawValue: raw) { Settings.shared.focusUnit = u }
    }

    func validateWritingItem(_ item: NSMenuItem) -> Bool? {
        if let r = validateReadableWidthItem(item) { return r }
        let tab = currentTab
        switch item.action {
        case #selector(toggleTypewriterMenu(_:)):
            item.state = tab?.editing.writing.typewriter == true ? .on : .off
            return tab != nil
        case #selector(toggleFocusMenu(_:)):
            item.state = tab?.editing.writing.focus == true ? .on : .off
            return tab != nil
        case #selector(pickFocusUnitMenu(_:)):
            item.state = (item.representedObject as? String) == Settings.shared.focusUnit.rawValue ? .on : .off
            return tab != nil
        default: return nil
        }
    }
}

@MainActor
func writingModeMenu() -> NSMenuItem {
    submenu(String(localized: "Writing Mode"), [
        item(String(localized: "Typewriter Scrolling"), #selector(AppDelegate.toggleTypewriterMenu(_:))),
        item(String(localized: "Focus"), #selector(AppDelegate.toggleFocusMenu(_:))),
        .separator(),
        item(String(localized: "Focus on Paragraph"), #selector(AppDelegate.pickFocusUnitMenu(_:)), represented: FocusUnit.paragraph.rawValue),
        item(String(localized: "Focus on Sentence"), #selector(AppDelegate.pickFocusUnitMenu(_:)), represented: FocusUnit.sentence.rawValue),
    ])
}
