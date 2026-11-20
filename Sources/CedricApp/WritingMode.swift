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
        if w.typewriter && !old.typewriter { typewriterScroll(animated: false) }
        if w.focus { applyFocusNow() } else if old.focus { clearFocus() }
        (NSApp.delegate as? AppDelegate)?.scheduleSessionSave()
    }

    /// For the session: nil when both are off.
    var sessionWriting: WritingModeState? { editing.writing.isOff ? nil : editing.writing }

    /// One pane's hooks and inset for the current switches (at a switch, and
    /// for the second pane of a split when it is made).
    func wireWriting(_ pane: EditorPane) {
        let on = editing.writing.typewriter
        pane.textView.onScrollRangeToVisible = on ? { [weak self, weak pane] _ in
            guard let self, let pane else { return false }
            self.typewriterScroll(in: pane, animated: false)
            return true
        } : nil
        updateTypewriterInset(pane)
    }

    /// The bottom inset that lets the last line reach the middle (0 when off).
    func updateTypewriterInset(_ pane: EditorPane) {
        let sv = pane.scrollView
        let font = pane.textView.font ?? Settings.shared.font
        let line = ceil(font.ascender - font.descender + font.leading)
        let inset = editing.writing.typewriter
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
            // the display pass): lay out the viewport now, which also sizes
            // the view; the display pass then finds it done.
            tlm.ensureLayout(for: NSTextRange(location: loc))
            tlm.textViewportLayoutController.layoutViewport()
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
        guard editing.writing.typewriter else { return }
        guard let mid = caretLineMidY(tv, layout: true) else { return }
        let sv = pane.scrollView, clip = sv.contentView
        updateTypewriterInset(pane)
        let visible = clip.bounds
        guard let target = Typewriter.scrollTarget(caretMidY: Double(mid), visibleHeight: Double(visible.height), currentY: Double(visible.minY),
                                                   documentHeight: Double(tv.frame.height), bottomInset: Double(sv.contentInsets.bottom))
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

    func applyFocusNow() {
        guard editing.writing.focus, !textView.hasMarkedText() else { return }
        let focus = focusRange
        for pane in panes { applyFocus(focus, to: pane.textView) }
    }

    /// Dims the visible text outside `focus` in one view: the focus range
    /// loses the attribute, the rest of the visible text gets it. Text out
    /// of view is left as it is (it is set again when scrolled into view).
    private func applyFocus(_ focus: NSRange, to tv: EditorTextView) {
        guard let tlm = tv.textLayoutManager, let vis = tv.visibleCharacterRange else { return }
        let len = tv.textStorage?.length ?? 0
        let id = ObjectIdentifier(tv)
        let color = NSColor(hex: tv.palette.foreground).withAlphaComponent(WritingMode.dimAlpha)
        let dims = FocusRange.dimmed(visible: vis, focus: focus)
        let bright = NSIntersectionRange(focus, NSRange(location: 0, length: len))
        if bright.length > 0, let tr = tv.textRange(for: bright) { tlm.removeRenderingAttribute(.foregroundColor, for: tr) }
        for r in dims where NSMaxRange(r) <= len {
            if let tr = tv.textRange(for: r) { tlm.addRenderingAttribute(.foregroundColor, value: color, for: tr) }
        }
        editing.focusDimmed[id] = vis
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
