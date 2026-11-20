import AppKit
import CedricCore

/// An in-process typing check (`CEDRIC_TYPE_CHECK=1`, run by
/// Scripts/typing-check.sh). For every theme (System light and dark, Light,
/// Dark, Tankard, Dracula), in a new untitled tab and in an opened file, it
/// types with real key events (NSEvent keyDown through the window, so
/// NSTextView's own key handling and insertText run, as for a user), draws
/// the window and samples the pixels under the typed glyphs, read from
/// TextKit's own segment frames. Typed text must be visible immediately
/// (before any deferred work runs) and after the highlighter has run.
///
/// Also checks the caret, selection, paste, undo/redo, Replace All, a theme
/// switch while typing, marked (IME) text, typing in the find field and at
/// the end of a 10 MB file (`CEDRIC_TYPE_CHECK_BIG`).
///
///   CEDRIC_TYPE_CHECK_FILE=/path   the file to open for the "file" cases (required)
///   CEDRIC_TYPE_CHECK_SHOTS=/dir   also write a PNG of each case's text view
///   CEDRIC_TYPE_CHECK_BIG=/path    a big file to type at the end of
///
/// Output: one "typecheck: PASS|FAIL <case> …" line per check, then
/// "typecheck: done failures=N". Exit status = failures (capped at 1).
@MainActor
enum TypingCheck {
    static var failures = 0
    static let env = DevEnvironment.values

    static func report(_ ok: Bool, _ name: String, _ detail: String) {
        if !ok { failures += 1 }
        print("typecheck: \(ok ? "PASS" : "FAIL") \(name) \(detail)")
        fflush(stdout)
    }

    /// Lets the run loop turn (deferred colouring, layout).
    static func settle(_ seconds: Double = 0.15) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: Key events

    static func key(_ window: NSWindow, _ chars: String, keyCode: UInt16 = 0, mods: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode) else { continue }
            window.sendEvent(e)
        }
    }

    static func type(_ window: NSWindow, _ text: String) {
        for ch in text {
            switch ch {
            case "\n": key(window, "\r", keyCode: 36)
            case "\t": key(window, "\t", keyCode: 48)
            default: key(window, String(ch))
            }
        }
    }

    static func command(_ window: NSWindow, _ chars: String, shift: Bool = false) {
        // Menu key equivalents go through NSApp, as for a real ⌘-key.
        let mods: NSEvent.ModifierFlags = shift ? [.command, .shift] : [.command]
        if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil, characters: chars,
                                    charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 0) {
            NSApp.sendEvent(e)
        }
    }

    // MARK: Pixels

    struct Ink { var pixels: Int; var total: Int; var maxContrast: Double }

    static func luminance(_ c: NSColor) -> Double {
        guard let s = c.usingColorSpace(.sRGB) else { return 0 }
        func ch(_ v: CGFloat) -> Double { let d = Double(v); return d <= 0.03928 ? d / 12.92 : pow((d + 0.055) / 1.055, 2.4) }
        return 0.2126 * ch(s.redComponent) + 0.7152 * ch(s.greenComponent) + 0.0722 * ch(s.blueComponent)
    }

    static func contrast(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }

    /// Rects (text view coordinates) of the glyphs in `range`.
    static func glyphRects(_ tv: EditorTextView, _ range: NSRange) -> [NSRect] {
        guard let tlm = tv.textLayoutManager, let r = tv.textRange(for: range) else { return [] }
        tlm.ensureLayout(for: r)
        var rects: [NSRect] = []
        tlm.enumerateTextSegments(in: r, type: .standard, options: []) { _, frame, _, _ in
            let f = frame.offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y)
            if f.width > 0.5 { rects.append(f) }
            return true
        }
        return rects
    }

    /// Draws the text view and counts pixels under `rects` that stand out
    /// from every background they could be on (the theme background, the
    /// current-line band, the selection) by at least 2:1.
    static func ink(_ tv: EditorTextView, _ rects: [NSRect], backgrounds: [UInt32], shot: String? = nil) -> Ink {
        tv.window?.displayIfNeeded()
        tv.displayIfNeeded()
        let bounds = rects.reduce(NSRect.null) { $0.union($1) }.intersection(tv.bounds)
        guard !bounds.isEmpty, let rep = DevHooks.render(tv, bounds) else { return Ink(pixels: 0, total: 0, maxContrast: 1) }
        if let shot, let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: shot)) }
        let bgLum = backgrounds.map { luminance(NSColor(hex: $0)) }
        var count = 0, total = 0
        var best = 1.0
        let sx = Double(rep.pixelsWide) / bounds.width, sy = Double(rep.pixelsHigh) / bounds.height
        for r in rects {
            let local = r.offsetBy(dx: -bounds.minX, dy: -bounds.minY).intersection(NSRect(origin: .zero, size: bounds.size))
            // Bitmap rows run top-down; the text view is flipped too, so y maps straight.
            let x0 = Int(local.minX * sx), x1 = Int(local.maxX * sx), y0 = Int(local.minY * sy), y1 = Int(local.maxY * sy)
            guard x1 > x0, y1 > y0 else { continue }
            for y in stride(from: y0, to: min(y1, rep.pixelsHigh), by: 1) {
                for x in stride(from: x0, to: min(x1, rep.pixelsWide), by: 1) {
                    guard let c = rep.colorAt(x: x, y: y) else { continue }
                    total += 1
                    let l = luminance(c)
                    let worst = bgLum.map { contrast(l, $0) }.min() ?? 1
                    best = max(best, worst)
                    if worst >= 2 { count += 1 }
                }
            }
        }
        return Ink(pixels: count, total: total, maxContrast: best)
    }

    /// What the window server will show, as far as the process can tell:
    /// TextKit 2 draws each laid-out paragraph in its own element view; the
    /// screen shows that view's layer contents, which are only produced when
    /// the view is displayed. cacheDisplay redraws every view and so can't
    /// see a view that exists but was never displayed (blank on screen). For
    /// the typed glyphs, every covering element view must have drawn
    /// contents and no pending display that would never be serviced.
    static func screenPath(_ tv: EditorTextView, _ rects: [NSRect]) -> (ok: Bool, detail: String) {
        func elementViews(_ v: NSView) -> [NSView] {
            let mine = String(describing: Swift.type(of: v)).contains("ViewportElementView") ? [v] : []
            return mine + v.subviews.flatMap(elementViews)
        }
        let views = elementViews(tv)
        var covering = 0, blank = 0
        for r in rects {
            for v in views where v.convert(v.bounds, to: tv).intersects(r) {
                covering += 1
                let hasContents = v.layer?.contents != nil || (v.layer?.sublayers ?? []).contains { $0.contents != nil }
                if !hasContents || v.isHidden || v.alphaValue < 0.01 { blank += 1 }
            }
        }
        return (covering > 0 && blank == 0, "element views covering=\(covering) blank=\(blank)")
    }

    /// Visible = some pixels clearly stand out, with a strong peak contrast.
    static func visible(_ i: Ink, minPixels: Int = 30) -> Bool { i.pixels >= minPixels && i.maxContrast >= 3 }

    static func describe(_ i: Ink) -> String { String(format: "ink=%d/%d max=%.1f:1", i.pixels, i.total, i.maxContrast) }

    // MARK: Cases

    struct ThemeCase { var name: String; var theme: EditorTheme; var system: NSAppearance.Name? }

    static let themes: [ThemeCase] = [
        ThemeCase(name: "system-light", theme: .system, system: .aqua),
        ThemeCase(name: "system-dark", theme: .system, system: .darkAqua),
        ThemeCase(name: "light", theme: .light, system: nil),
        ThemeCase(name: "dark", theme: .dark, system: nil),
        ThemeCase(name: "tankard", theme: .tankard, system: nil),
        ThemeCase(name: "dracula", theme: .dracula, system: nil),
        ThemeCase(name: "cedric", theme: .cedric, system: nil),
        ThemeCase(name: "cedric-night", theme: .cedricNight, system: nil),
    ]

    static func apply(_ c: ThemeCase) {
        NSApp.appearance = c.system.flatMap(NSAppearance.init(named:))
        Settings.shared.themeOverride = c.theme
        NotificationCenter.default.post(name: .cedricAppearanceChanged, object: nil)
    }

    static func run(_ app: AppDelegate) {
        guard let file = env["CEDRIC_TYPE_CHECK_FILE"] else { print("typecheck: set CEDRIC_TYPE_CHECK_FILE"); exit(2) }
        let shots = env["CEDRIC_TYPE_CHECK_SHOTS"]
        for c in themes {
            apply(c)
            for kind in ["untitled", "file"] {
                let tab: EditorWindowController?
                if kind == "untitled" {
                    app.newTab(nil)
                    tab = app.tabs.last
                } else {
                    tab = app.open(URL(fileURLWithPath: file))
                }
                guard let tab, let window = tab.window else { report(false, "\(c.name)/\(kind)", "no tab"); continue }
                window.makeKeyAndOrderFront(nil)
                settle(0.05)
                let tv = tab.textView
                // As a user finds it: no makeFirstResponder from the check.
                report(window.firstResponder === tv, "\(c.name)/\(kind)/editor-has-focus",
                       "firstResponder=\(window.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "nil")")
                window.makeFirstResponder(tv)
                tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
                let p = tab.palette
                let bgs = [p.background, p.currentLine]
                if kind == "file" {
                    settle()
                    // Control: text that was loaded, not typed.
                    let ctl = ink(tv, glyphRects(tv, NSRange(location: 0, length: 12)), backgrounds: bgs,
                                  shot: shots.map { "\($0)/\(c.name)-control.png" })
                    report(visible(ctl), "\(c.name)/file/loaded-text-visible", describe(ctl))
                    type(window, "\n")
                }
                let start = (tv.string as NSString).length
                let typed = "let answer = 42 // typed"
                type(window, typed)
                let range = NSRange(location: start, length: (typed as NSString).length)
                let got = (tv.string as NSString).length >= start + range.length
                    ? (tv.string as NSString).substring(with: range) : ""
                report(got == typed, "\(c.name)/\(kind)/keys-inserted", "text=\(got.debugDescription)")
                // Immediately: before the run loop turns (deferred colouring hasn't run).
                let now = ink(tv, glyphRects(tv, range), backgrounds: bgs)
                report(visible(now), "\(c.name)/\(kind)/typed-visible-immediately", describe(now))
                settle()
                let later = ink(tv, glyphRects(tv, range), backgrounds: bgs,
                                shot: shots.map { "\($0)/\(c.name)-\(kind).png" })
                report(visible(later), "\(c.name)/\(kind)/typed-visible-after-highlight", describe(later))
                // Let one more display cycle pass (as on screen), without cacheDisplay forcing a draw.
                settle(0.2)
                let sp = screenPath(tv, glyphRects(tv, range))
                report(sp.ok, "\(c.name)/\(kind)/typed-screen-layers", sp.detail)

                // Return keeps indentation; Tab inserts a tab.
                let beforeIndent = (tv.string as NSString).length
                type(window, "\n\tz")
                let tail = (tv.string as NSString).substring(from: beforeIndent)
                report(tail == "\n\tz", "\(c.name)/\(kind)/return-tab", "inserted=\(tail.debugDescription)")
                let zRange = NSRange(location: (tv.string as NSString).length - 1, length: 1)
                settle()
                let zInk = ink(tv, glyphRects(tv, zRange), backgrounds: bgs)
                report(visible(zInk, minPixels: 8), "\(c.name)/\(kind)/after-tab-visible", describe(zInk))

                // Caret colour against the background (and the current-line band).
                let caretL = luminance(tv.insertionPointColor)
                let caretC = bgs.map { contrast(caretL, luminance(NSColor(hex: $0))) }.min() ?? 1
                report(caretC >= 3, "\(c.name)/\(kind)/caret-contrast", String(format: "%.1f:1", caretC))

                // Selection: the band must differ from the background, and text on it stay readable.
                tv.setSelectedRange(range)
                tv.window?.displayIfNeeded()
                let selC = contrast(luminance(NSColor(hex: p.selection)), luminance(NSColor(hex: p.background)))
                let selInk = ink(tv, glyphRects(tv, range), backgrounds: [p.selection])
                report(selC >= 1.25 && visible(selInk), "\(c.name)/\(kind)/selection",
                       String(format: "band %.2f:1, ", selC) + describe(selInk))

                if kind == "untitled" { multiCaretCase(c, tab, window, ime: c.name == "dark") }
                if kind == "file" { splitCase(c, tab, window) }
                if c.name == "dark" && kind == "untitled" { extraChecks(app, tab, window) }
                // Leave the tab without a save prompt.
                tab.doc.markSaved()
                window.close()
                settle(0.05)
            }
        }
        apply(themes[3])
        if let big = env["CEDRIC_TYPE_CHECK_BIG"] { bigFileCheck(app, big) }
        print("typecheck: done failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    /// View › Split Editor: typing in the second pane (real keys through
    /// the window) is drawn in both panes, in this theme; then unsplit.
    static func splitCase(_ c: ThemeCase, _ tab: EditorWindowController, _ window: NSWindow) {
        tab.splitPanes(focusSecond: true)
        guard let s = tab.splitEditor else { report(false, "\(c.name)/split/made", "no split"); return }
        let tv2 = s.second.textView, tv1 = tab.primaryTextView
        report(window.firstResponder === tv2, "\(c.name)/split/second-pane-has-focus", "")
        tab.scrollToLine(0, in: tab.primaryPane)
        tab.scrollToLine(0, in: s.second)
        tv2.setSelectedRange(NSRange(location: 0, length: 0))
        let typed = "split typed "
        type(window, typed)
        let range = NSRange(location: 0, length: (typed as NSString).length)
        report(tv1.string.hasPrefix(typed), "\(c.name)/split/keys-inserted", "text=\(String(tv1.string.prefix(20)).debugDescription)")
        settle()
        let p = tab.palette
        let bgs = [p.background, p.currentLine]
        let in2 = ink(tv2, glyphRects(tv2, range), backgrounds: bgs)
        report(visible(in2), "\(c.name)/split/typed-visible-in-pane-2", describe(in2))
        let in1 = ink(tv1, glyphRects(tv1, range), backgrounds: bgs)
        report(visible(in1), "\(c.name)/split/typed-visible-in-pane-1", describe(in1))
        tab.unsplit()
        report(!tab.isSplit && tv1.contentStorage?.textLayoutManagers.count == 1, "\(c.name)/split/unsplit", "")
    }

    /// Paste, undo/redo, Replace All, theme switch mid-typing, marked text,
    /// select-all + delete, and the find field. Run once (Dark theme).
    static func extraChecks(_ app: AppDelegate, _ tab: EditorWindowController, _ window: NSWindow) {
        let tv = tab.textView
        func lastVisible(_ name: String, _ len: Int) {
            let n = (tv.string as NSString).length
            let r = NSRange(location: n - len, length: len)
            settle()
            let p = tab.palette
            let i = ink(tv, glyphRects(tv, r), backgrounds: [p.background, p.currentLine])
            report(visible(i, minPixels: 8), "extra/\(name)", describe(i))
        }
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))

        // Paste (with CRLF, which is normalised).
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\r\npasted words", forType: .string)
        tv.paste(nil)
        settle()
        report(tv.string.hasSuffix("\npasted words") && !tv.string.contains("\r"), "extra/paste-normalised", "tail=\(String(tv.string.suffix(14)).debugDescription)")
        lastVisible("paste-visible", 12)

        // Undo / redo of typing.
        type(window, " undo me")
        let withTyping = tv.string
        tv.undoManager?.undo()
        settle()
        report(tv.string != withTyping, "extra/undo", "after undo ends \(String(tv.string.suffix(12)).debugDescription)")
        tv.undoManager?.redo()
        settle()
        report(tv.string == withTyping, "extra/redo", "")
        lastVisible("redo-visible", 7)

        // Replace All through the find bar.
        tab.showFindBar(replace: true)
        tab.findBar.findField.stringValue = "words"
        tab.findBar.replaceField.stringValue = "WORDS"
        tab.findBar.onReplaceAll?()
        settle()
        report(tv.string.contains("pasted WORDS"), "extra/replace-all", tab.findBar.status.stringValue)
        window.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        lastVisible("replace-all-visible", 5)

        // Typing in the find field (key events to the field editor).
        tab.showFindBar(replace: false)
        tab.findBar.findField.stringValue = ""
        window.makeFirstResponder(tab.findBar.findField)
        type(window, "pasted")
        report(tab.findBar.findField.stringValue == "pasted", "extra/find-field-typing", "field=\(tab.findBar.findField.stringValue.debugDescription)")
        tab.hideFindBar()
        window.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))

        // Theme switch mid-typing: type, switch, type more; both runs visible.
        type(window, " before")
        apply(themes[4]) // tankard
        type(window, " after")
        lastVisible("theme-switch-before-text", 13)
        apply(themes[2]) // light
        type(window, " light")
        lastVisible("theme-switch-light", 6)
        apply(themes[3]) // back to dark

        // Marked text (what an input method shows while composing), then commit.
        tv.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        lastVisible("ime-marked-visible", 2)
        tv.insertText("日本", replacementRange: tv.markedRange())
        report(tv.string.hasSuffix("日本") && !tv.hasMarkedText(), "extra/ime-commit", "")
        lastVisible("ime-committed-visible", 2)

        // Select All + Delete, then typing still shows.
        tv.selectAll(nil)
        key(window, "\u{7f}", keyCode: 51)
        report(tv.string.isEmpty, "extra/select-all-delete", "length=\((tv.string as NSString).length)")
        type(window, "fresh")
        lastVisible("after-delete-visible", 5)
    }

    /// Multiple carets (MultiCaretEditing.swift): three carets added with
    /// ⌃⇧↓, then typed at with key events; the text must land at every
    /// caret and stand out, immediately and after highlighting, and the
    /// extra carets must be drawn. With `ime`, also an input method's
    /// marked text at the primary, committed at every caret.
    static func multiCaretCase(_ c: ThemeCase, _ tab: EditorWindowController, _ window: NSWindow, ime: Bool) {
        let tv = tab.textView
        let name = "\(c.name)/multicaret"
        window.makeFirstResponder(tv)
        let base = (tv.string as NSString).length
        tv.setSelectedRange(NSRange(location: base, length: 0))
        // The lines as one insert (Return would carry the previous line's indent).
        tv.insertText("\nmc\nmc\nmc", replacementRange: NSRange(location: base, length: 0))
        tv.setSelectedRange(NSRange(location: base + 3, length: 0))
        let down = String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)
        DevChecks.key(down, [.control, .shift])
        DevChecks.key(down, [.control, .shift])
        let carets = tv.multiCarets?.map(\.head) ?? []
        report(carets == [base + 3, base + 6, base + 9], "\(name)/carets-added", "carets=\(carets)")
        type(window, "Q7")
        let ns = tv.string as NSString
        let tail = ns.substring(from: base)
        report(tail == "\nmcQ7\nmcQ7\nmcQ7", "\(name)/keys-inserted-at-every-caret", "tail=\(tail.debugDescription)")
        let typed = (0..<3).map { NSRange(location: base + 3 + $0 * 5, length: 2) }
        let rects = typed.flatMap { glyphRects(tv, $0) }
        let p = tab.palette
        let bgs = [p.background, p.currentLine]
        let now = ink(tv, rects, backgrounds: bgs)
        report(visible(now, minPixels: 24), "\(name)/typed-visible-immediately", describe(now))
        settle()
        let later = ink(tv, rects, backgrounds: bgs)
        report(visible(later, minPixels: 24), "\(name)/typed-visible-after-highlight", describe(later))
        settle(0.2)
        let sp = screenPath(tv, rects)
        report(sp.ok, "\(name)/typed-screen-layers", sp.detail)
        // The extra carets (not the primary, drawn by NSTextView): caret-coloured pixels just before each.
        var drawn = 0
        let caretL = luminance(tv.insertionPointColor)
        for (i, k) in (tv.multiCarets ?? []).enumerated() where i != tv.multiPrimary {
            let r = glyphRects(tv, NSRange(location: k.head - 1, length: 1))
            guard let g = r.first else { continue }
            let box = NSRect(x: g.maxX - 0.5, y: g.minY + 2, width: 2.5, height: max(2, g.height - 4))
            if let rep = DevHooks.render(tv, box) {
                var hit = false
                for y in 0..<rep.pixelsHigh where !hit {
                    for x in 0..<rep.pixelsWide where contrast(luminance(rep.colorAt(x: x, y: y) ?? .clear), caretL) < 1.1 { hit = true; break }
                }
                if hit { drawn += 1 }
            }
        }
        report(drawn == 2, "\(name)/extra-carets-drawn", "\(drawn)/2")
        if ime {
            // An input method composes at the primary; the commit goes in at every caret.
            tv.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            report(tv.hasMarkedText() && tv.multiCarets?.count == 3, "\(name)/ime-marked-keeps-carets", "")
            tv.insertText("日本", replacementRange: tv.markedRange())
            let t2 = (tv.string as NSString).substring(from: base)
            report(t2 == "\nmcQ7日本\nmcQ7日本\nmcQ7日本", "\(name)/ime-commit-at-every-caret", "tail=\(t2.debugDescription)")
            let r2 = (0..<3).map { NSRange(location: base + 5 + $0 * 7, length: 2) }
            settle()
            let i2 = ink(tv, r2.flatMap { glyphRects(tv, $0) }, backgrounds: bgs)
            report(visible(i2, minPixels: 24), "\(name)/ime-committed-visible", describe(i2))
        }
        // ⎋: back to one caret.
        key(window, "\u{1b}", keyCode: 53)
        report(tv.multiCarets == nil, "\(name)/escape-single-caret", "")
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
    }

    static func bigFileCheck(_ app: AppDelegate, _ path: String) {
        guard let tab = app.open(URL(fileURLWithPath: path)), let window = tab.window else { report(false, "big/open", path); return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(tab.textView)
        let tv = tab.textView
        let end = (tv.string as NSString).length
        tv.setSelectedRange(NSRange(location: end, length: 0))
        tab.reveal(NSRange(location: end, length: 0))
        settle()
        let t0 = Date()
        type(window, "\nlet tail = 1")
        let ms = Date().timeIntervalSince(t0) * 1000
        let r = NSRange(location: (tv.string as NSString).length - 12, length: 12)
        let i = ink(tv, glyphRects(tv, r), backgrounds: [tab.palette.background, tab.palette.currentLine])
        report(visible(i), "big/typed-at-end-visible-immediately", describe(i) + String(format: " (13 keys in %.0f ms)", ms))
        tab.doc.markSaved()
        window.close()
    }
}
