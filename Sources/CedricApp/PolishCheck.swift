import AppKit
import CedricCore
import QuartzCore

/// Part of the whole-window render check (Scripts/render-check.sh): the
/// owl dragged with real mouse events, and the language auto-detection
/// driven with real key events, each rendered as a whole window.
@MainActor
enum PolishCheck {
    typealias Report = (Bool, String, String) -> Void

    // MARK: Mouse events

    static func mouse(_ window: NSWindow, _ type: NSEvent.EventType, at p: NSPoint, clicks: Int = 1) {
        guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
                                         pressure: type == .leftMouseUp ? 0 : 1) else { return }
        window.sendEvent(e)
    }

    /// Press at `from`, move in steps to `to`, release (window coordinates).
    static func drag(_ window: NSWindow, from: NSPoint, to: NSPoint, steps: Int = 12) {
        mouse(window, .leftMouseDown, at: from)
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            mouse(window, .leftMouseDragged, at: NSPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
        }
        mouse(window, .leftMouseUp, at: to)
    }

    static func render(_ window: NSWindow, _ path: String) -> (NSBitmapImageRep?, NSView) {
        window.displayIfNeeded()
        CATransaction.flush()
        let root = window.contentView!.superview ?? window.contentView!
        let rep = RenderDump.renderLayer(root)
        RenderDump.save(rep, path)
        return (rep, root)
    }

    // MARK: Owl

    static func owl(_ app: AppDelegate, out: String, report: Report) {
        TypingCheck.apply(TypingCheck.themes[3]) // dark: where the rim matters
        app.newTab(nil)
        guard let tab = app.tabs.last, let window = tab.window else { report(false, "owl-drag/tab", "no tab"); return }
        window.setContentSize(NSSize(width: 900, height: 670))
        window.makeKeyAndOrderFront(nil)
        // Readable Width (0.4.0, on for plain text) centres the text, so the
        // caret would no longer sit under the owl parked at the top left.
        tab.setReadableWidth(false)
        Settings.shared.owlOverride = true
        NotificationCenter.default.post(name: .cedricOwlSettingsChanged, object: nil)
        TypingCheck.settle(0.1)
        guard let oc = tab.owl else { report(false, "owl-drag/owl", "no owl"); return }
        let owl = oc.owl, overlay = oc.overlay
        oc.resetPosition()
        window.makeFirstResponder(tab.textView)
        TypingCheck.type(window, "Hello owl\nsecond line")
        TypingCheck.settle(0.3)

        func center() -> NSPoint { owl.convert(NSPoint(x: owl.bounds.midX, y: owl.bounds.midY), to: nil) }
        let startFrame = owl.frame

        // A press that moves 2 pt is a click: the popover, no move.
        let c0 = center()
        mouse(window, .leftMouseDown, at: c0)
        mouse(window, .leftMouseDragged, at: NSPoint(x: c0.x + 2, y: c0.y))
        mouse(window, .leftMouseUp, at: NSPoint(x: c0.x + 2, y: c0.y))
        TypingCheck.settle(0.2)
        report(oc.popoverShown && owl.frame == startFrame, "owl-drag/click-opens-popover", "shown=\(oc.popoverShown) frame=\(owl.frame)")
        oc.closePopover()
        TypingCheck.settle(0.5)
        let closedBefore = !oc.popoverShown

        // Drag to the top left of the editor.
        let target = overlay.convert(NSPoint(x: 60, y: overlay.bounds.maxY - 50), to: nil)
        drag(window, from: center(), to: target)
        TypingCheck.settle(0.4)
        let place = Settings.shared.owlPlacement
        let expected = NSRect(x: 6, y: overlay.bounds.maxY - 74, width: 72, height: 72)
        report(place == OwlPlacement(corner: .topLeft, inset: OwlPlacement.margin) && owl.frame == expected,
               "owl-drag/snapped-top-left", "placement=\(place.corner) \(place.inset) frame=\(owl.frame) overlay=\(overlay.bounds.size)")
        report(!oc.popoverShown, "owl-drag/drag-is-not-a-click", "popover=\(oc.popoverShown) closed-before-drag=\(closedBefore)")
        // The caret is at the end of "second line", under him: he fades.
        report(oc.owlFaded && owl.alphaValue < 0.5, "owl-drag/fades-over-caret", "faded=\(oc.owlFaded) alpha=\(owl.alphaValue)")
        let typed = (tab.text as NSString).range(of: "Hello owl\nsecond line")
        var (rep, root) = render(window, "\(out)/owl-drag-over-caret.png")
        let bg = NSColor(hex: tab.palette.background)
        let textRects = TypingCheck.glyphRects(tab.textView, typed).map { tab.textView.convert($0, to: root) }
        if let rep {
            let t = RenderDump.inkCount(rep, textRects, root: root, bg: bg)
            report(t >= 30, "owl-drag/caret-text-readable", "ink=\(t)")
        }

        // Caret moves away (more lines): he's back at full strength, top left.
        TypingCheck.type(window, String(repeating: "\n", count: 14) + "far below")
        TypingCheck.settle(0.4)
        report(!oc.owlFaded && owl.alphaValue > 0.99, "owl-drag/unfades", "alpha=\(owl.alphaValue)")
        (rep, root) = render(window, "\(out)/owl-drag-top-left.png")
        if let rep {
            let r = owl.convert(owl.bounds, to: root)
            let o = RenderDump.inkCount(rep, [r], root: root, bg: bg)
            let topLeft = r.minX < 120 && r.maxY > root.bounds.height - 140
            report(o >= 200 && topLeft, "owl-drag/rendered-top-left", "ink=\(o) rect=\(r)")
        }

        // A hint: the bubble opens below him and to the right (where there's room).
        // An AI hint with a fix: "Fix it", and its source under the title.
        let ctx = tab.owlContextWindow().context
        let hint = OwlHint(id: "check.bubble", kind: .fix, title: "Capitalise “Hello owl”?",
                           detail: "Below and to the right when Cedric is top left.",
                           range: (ctx.text as NSString).range(of: "Hello owl"), replacement: "Hello Owl", source: "apple")
        oc.present(hint, context: ctx)
        TypingCheck.settle(0.2)
        if let b = oc.bubble {
            report(b.frame.maxY <= owl.frame.maxY && b.frame.minX >= owl.frame.minX - 4 && b.tailOnTop && b.tailAtLeft,
                   "owl-drag/bubble-side-with-room", "bubble=\(b.frame) owl=\(owl.frame)")
            report(b.buttons.first?.title == "Fix it" && b.sourceLabel?.stringValue == "AI suggestion · Apple Intelligence",
                   "owl-bubble/fix-it-and-source", "buttons=\(b.buttons.map(\.title)) source=\(b.sourceLabel?.stringValue ?? "-")")
        } else {
            report(false, "owl-drag/bubble-side-with-room", "no bubble")
        }
        _ = render(window, "\(out)/owl-drag-bubble.png")
        oc.hideBubble()

        // A resize keeps him top left (corner + inset).
        window.setContentSize(NSSize(width: 1200, height: 800))
        TypingCheck.settle(0.2)
        report(owl.frame.origin == NSPoint(x: 6, y: overlay.bounds.maxY - 74), "owl-drag/survives-resize",
               "frame=\(owl.frame) overlay=\(overlay.bounds.size)")

        // Double-click: back bottom right.
        let c = center()
        mouse(window, .leftMouseDown, at: c)
        mouse(window, .leftMouseUp, at: c)
        mouse(window, .leftMouseDown, at: c, clicks: 2)
        mouse(window, .leftMouseUp, at: c, clicks: 2)
        TypingCheck.settle(0.4)
        oc.closePopover()
        report(Settings.shared.owlPlacement == .default && owl.frame.maxX == overlay.bounds.maxX - 6,
               "owl-drag/double-click-resets", "placement=\(Settings.shared.owlPlacement.corner) frame=\(owl.frame)")

        Settings.shared.owlOverride = false
        NotificationCenter.default.post(name: .cedricOwlSettingsChanged, object: nil)
        tab.doc.markSaved()
        window.close()
        TypingCheck.settle(0.05)
    }

    // MARK: Language detection

    static func language(_ app: AppDelegate, out: String, report: Report) {
        TypingCheck.apply(TypingCheck.themes[2]) // light
        func newTab() -> (EditorWindowController, NSWindow)? {
            app.newTab(nil)
            guard let tab = app.tabs.last, let w = tab.window else { return nil }
            w.setContentSize(NSSize(width: 900, height: 670))
            w.makeKeyAndOrderFront(nil)
            w.makeFirstResponder(tab.textView)
            return (tab, w)
        }
        func done(_ tab: EditorWindowController) { tab.doc.markSaved(); tab.window?.close(); TypingCheck.settle(0.05) }

        // Typed "<html>": HTML (auto), once typing pauses.
        guard let (tab, w) = newTab() else { report(false, "language/tab", "no tab"); return }
        TypingCheck.type(w, "<html>")
        let before = tab.statusBar.languageButton.title
        TypingCheck.settle(0.7)
        let title = tab.statusBar.languageButton.title
        report(title == "HTML (auto)", "language/typed-html-auto", "title=\(title) (before the pause: \(before))")
        _ = render(w, "\(out)/language-html-auto.png")
        // Plain Text picked from the status-bar menu: typing more HTML doesn't switch it.
        let menu = tab.statusBar.languageButton.menu!
        if let i = menu.items.firstIndex(where: { ($0.representedObject as? String) == Language.plain.rawValue }) {
            menu.performActionForItem(at: i)
        }
        TypingCheck.type(w, "\n<!doctype html>\n<body><p>more</p></body>")
        TypingCheck.settle(0.7)
        let paste = NSPasteboard(name: NSPasteboard.Name("org.cedric.check"))
        paste.clearContents()
        paste.setString("\n<div>pasted</div>\n", forType: .string)
        _ = tab.textView.readSelection(from: paste, type: .string)
        TypingCheck.settle(0.2)
        report(tab.doc.language == .plain && tab.doc.languageIsManual && tab.statusBar.languageButton.title == "Plain Text",
               "language/manual-plain-stays", "language=\(tab.doc.language) title=\(tab.statusBar.languageButton.title)")
        _ = render(w, "\(out)/language-manual-plain.png")
        done(tab)

        // Derek's Markdown, typed.
        guard let (md, mw) = newTab() else { return }
        TypingCheck.type(mw, "# Title\n## Sub Title\n**Test**\nTesting markdown\n")
        TypingCheck.settle(0.7)
        report(md.statusBar.languageButton.title == "Markdown (auto)", "language/typed-markdown-auto", "title=\(md.statusBar.languageButton.title)")
        _ = render(mw, "\(out)/language-markdown-auto.png")
        done(md)

        // A paste switches at once (no pause needed).
        guard let (pt, _) = newTab() else { return }
        paste.clearContents()
        paste.setString("{\"name\": \"cedric\", \"owl\": true}\n", forType: .string)
        _ = pt.textView.readSelection(from: paste, type: .string)
        TypingCheck.settle(0.05)
        report(pt.statusBar.languageButton.title == "JSON (auto)", "language/paste-json-auto", "title=\(pt.statusBar.languageButton.title)")
        done(pt)
        paste.releaseGlobally()
    }

    // MARK: Cedric themes

    /// Swift, Markdown with its preview, and HTML in the Cedric and Cedric
    /// Night themes, written whole-window (web preview via takeSnapshot).
    static func themeShowcase(_ app: AppDelegate, out: String, report: Report) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cedric-showcase-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let samples: [(String, String, Bool)] = [
            ("owl.swift", """
            import Foundation

            /// Cedric polishes his monocle while you type.
            @MainActor
            struct Owl: Identifiable {
                let id = UUID()
                var name = "Cedric"
                var hoots: Int = 3 // a polite number

                func greet(_ who: String) -> String {
                    guard !who.isEmpty else { return "Hoo?" }
                    return "Good evening, \\(who). " + String(repeating: "hoo ", count: hoots)
                }
            }
            """, false),
            ("notes.md", """
            # Cedric's notes

            ## Today
            - Polish the **monocle**
            - Read *two* chapters of [the owl book](https://example.com)
            1. Hoot
            2. Sleep

            > Wisdom is knowing when to stay in the corner.

            ```swift
            let owl = Owl()
            ```
            """, true),
            ("index.html", """
            <!doctype html>
            <html lang="en">
            <head>
              <meta charset="utf-8">
              <title>Cedric</title>
              <style>body { color: #27295a; background: #fbeee4; }</style>
            </head>
            <body>
              <!-- the owl's page -->
              <h1 class="title">Hello from Cedric</h1>
              <p>Typing <em>quietly</em>, polishing <strong>loudly</strong>.</p>
            </body>
            </html>
            """, false),
            ("deploy.ps1", #"""
            <#
            .SYNOPSIS
                Deploys Cedric's notes.
            #>
            [CmdletBinding()]
            param([Parameter(Mandatory)][string]$Path, [int]$Retries = 3)

            function Publish-Notes {
                $size = (Get-Item $Path).Length / 1KB
                if ($size -gt 512 -and $env:CI) { Write-Warning "Big: $([math]::Round($size)) KB" }
                $body = @"
            Owl: $env:USERNAME
            "@
                Write-Host "Done in $Retries tries" -ForegroundColor Green # hoo
            }
            """#, false),
        ]
        for (theme, name) in [(EditorTheme.cedric, "cedric"), (.cedricNight, "cedric-night")] {
            TypingCheck.apply(TypingCheck.ThemeCase(name: name, theme: theme, system: nil))
            for (file, text, preview) in samples {
                let url = dir.appendingPathComponent(file)
                try? text.write(to: url, atomically: true, encoding: .utf8)
                guard let tab = app.open(url), let w = tab.window else { report(false, "theme/\(name)/\(file)", "didn't open"); continue }
                w.setContentSize(NSSize(width: 1100, height: 640))
                w.makeKeyAndOrderFront(nil)
                if preview { tab.togglePreview() }
                let ps = file.hasSuffix(".ps1")
                if ps { tab.toggleOutline() }
                TypingCheck.settle(preview ? 1.5 : 0.4)
                if ps {
                    // Coloured as PowerShell: a cmdlet, a variable in a string, a help keyword.
                    let ns = tab.textView.string as NSString
                    func color(_ word: String) -> UInt32? {
                        let r = ns.range(of: word)
                        guard r.location != NSNotFound, let c = tab.textView.textStorage?.attribute(.foregroundColor, at: r.location, effectiveRange: nil) as? NSColor,
                              let rgb = c.usingColorSpace(.sRGB) else { return nil }
                        return UInt32(rgb.redComponent * 255 + 0.5) << 16 | UInt32(rgb.greenComponent * 255 + 0.5) << 8 | UInt32(rgb.blueComponent * 255 + 0.5)
                    }
                    let p = tab.palette
                    let want: [(String, TokenKind)] = [("Write-Host", .function), ("$Retries", .variable), (".SYNOPSIS", .keyword), ("-gt", .keyword), ("[string]", .type)]
                    let wrong = want.filter { color($0.0) != p.color(for: $0.1) }.map(\.0)
                    report(tab.doc.language == .powershell && wrong.isEmpty, "theme/\(name)/powershell-colours",
                           "language=\(tab.doc.language) wrong=\(wrong)")
                    let titles = tab.outline.sidebar?.headings.map(\.title) ?? []
                    report(tab.outlineVisible && titles == ["Publish-Notes"], "theme/\(name)/powershell-outline", "titles=\(titles)")
                }
                let path = "\(out)/theme-\(name)-\((file as NSString).pathExtension).png"
                var finished = false
                DevHooks.write(window: w, to: path) { finished = true }
                let deadline = Date().addingTimeInterval(8)
                while !finished && Date() < deadline { TypingCheck.settle(0.05) }
                report(finished && FileManager.default.fileExists(atPath: path) && tab.palette.name == theme.palette(systemIsDark: false).name,
                       "theme/\(name)/\(file)", "palette=\(tab.palette.name) wrote=\(finished)")
                if preview { tab.togglePreview() }
                if ps { tab.hideOutline() }
                tab.doc.markSaved()
                w.close()
                TypingCheck.settle(0.05)
            }
        }
    }

    // MARK: Spelling

    /// Comment-only checking in Swift, prose in Markdown (red underlines
    /// rendered in the light and dark themes), text colours untouched, and
    /// the owl's "Fix 3 typos?" as one undo step.
    static func spelling(_ app: AppDelegate, out: String, report: Report) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cedric-spelling-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let swift = "let mispeled = 1 // this comment has a mispeled word\nlet b = \"a mispeled string\"\n"
        let md = "# Notes\n\nThis is a sentense with a tpyo.\nSee `codde` and [the dcos](https://exmple.com).\n"
        for (i, c) in [TypingCheck.themes[2], TypingCheck.themes[3]].enumerated() {
            TypingCheck.apply(c)
            let json = "{\"naem\": \"vlaue with wrods\", \"lsit\": [\"mispeled\"]}\n"
            for (file, text) in [("typos.swift", swift), ("typos.md", md), ("data.json", json)] {
                let url = dir.appendingPathComponent(file)
                try? text.write(to: url, atomically: true, encoding: .utf8)
                guard let tab = app.open(url), let w = tab.window else { report(false, "spelling/\(file)", "didn't open"); continue }
                w.setContentSize(NSSize(width: 900, height: 420))
                w.makeKeyAndOrderFront(nil)
                let tv = tab.textView
                let colours = { () -> [String] in
                    var out: [String] = []
                    tv.textStorage?.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: tv.textStorage!.length)) { v, r, _ in
                        out.append("\(r.location),\(r.length):\((v as? NSColor)?.description ?? "-")")
                    }
                    return out
                }
                TypingCheck.settle(0.3)
                let before = colours()
                tv.checkTextInDocument(nil)
                let ns = tv.string as NSString
                // Continuous checking answers asynchronously: wait for both words.
                var marked: [String] = []
                let until = Date().addingTimeInterval(4)
                repeat {
                    TypingCheck.settle(0.1)
                    marked = tv.markedMisspellings.map { ns.substring(with: $0) }.sorted()
                } while marked.count < 2 && Date() < until && !file.hasSuffix("json")
                TypingCheck.settle(0.2)
                marked = tv.markedMisspellings.map { ns.substring(with: $0) }.sorted()
                if i == 0 {
                    if file.hasSuffix("swift") {
                        // The identifier "mispeled" is not marked; the comment's and the string's are.
                        let first = ns.range(of: "mispeled")
                        let idMarked = tv.markedMisspellings.contains { $0.location == first.location }
                        report(!idMarked && marked == ["mispeled", "mispeled"], "spelling/swift-comments-and-strings-only",
                               "marked=\(tv.markedMisspellings.map(\.location)) identifier at \(first.location)")
                    } else if file.hasSuffix("json") {
                        // Data: no checking at all (values are names and ids, not writing).
                        report(marked.isEmpty && !tv.isContinuousSpellCheckingEnabled, "spelling/json-not-checked",
                               "marked=\(marked) continuous=\(tv.isContinuousSpellCheckingEnabled)")
                    } else {
                        report(marked == ["sentense", "tpyo"], "spelling/markdown-prose-not-code-or-links", "marked=\(marked)")
                    }
                    report(before == colours(), "spelling/\(file)/colours-untouched", "runs before=\(before.count) after=\(colours().count)")
                    report(tv.textLayoutManager != nil, "spelling/\(file)/textkit2", "still TextKit 2")
                }
                _ = render(w, "\(out)/spelling-\(c.name)-\((file as NSString).pathExtension).png")
                tab.doc.markSaved()
                w.close()
                TypingCheck.settle(0.05)
            }
        }

        // The owl: three typos in Markdown prose → "Fix 3 typos?" → one undo step.
        TypingCheck.apply(TypingCheck.themes[2])
        let url = dir.appendingPathComponent("owl-typos.md")
        try? "# Owl\n\nI beleive teh owl is verry wise, said NASA.\n".write(to: url, atomically: true, encoding: .utf8)
        Settings.shared.owlOverride = true
        NotificationCenter.default.post(name: .cedricOwlSettingsChanged, object: nil)
        guard let tab = app.open(url), let w = tab.window, let owl = tab.owl else { report(false, "spelling/owl", "no tab or owl"); return }
        w.setContentSize(NSSize(width: 900, height: 420))
        w.makeKeyAndOrderFront(nil)
        let tv = tab.textView
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        w.makeFirstResponder(tv)
        // What the owl's scheduled query does once typing pauses and the
        // rules have nothing (OwlHub.fire → offerAfterPause), without an
        // open typing undo group: injected events never close one.
        TypingCheck.settle(0.2)
        tab.spelling.offerAfterPause(skipPause: true)
        let original = tv.string
        let deadline = Date().addingTimeInterval(4)
        while owl.bubble == nil && Date() < deadline { TypingCheck.settle(0.1) }
        let title = owl.bubble?.hint.title ?? "-"
        report(title == "Fix 3 typos?", "spelling/owl-offers-fix", "bubble=\(title)")
        _ = render(w, "\(out)/spelling-owl-offer.png")
        report(owl.bubble?.buttons.first?.title == "Fix Typos…", "spelling/owl-offers-step-through",
               "buttons=\(owl.bubble?.buttons.map(\.title) ?? [])")
        if let fixIt = owl.bubble?.buttons.first(where: { $0.title == "Fix All" }) {
            let um = tv.undoManager
            fixIt.performClick(nil)
            TypingCheck.settle(0.2)
            let fixed = tv.string
            report(fixed == "# Owl\n\nI believe the owl is very wise, said NASA.\n", "spelling/owl-fix-applied", "text=\(fixed.debugDescription)")
            w.makeFirstResponder(tv)
            um?.undo()
            TypingCheck.settle(0.2)
            report(tv.string == original, "spelling/owl-fix-one-undo", "after one undo=\(tv.string.debugDescription)")
        } else {
            report(false, "spelling/owl-fix-applied", "no Fix All button")
        }
        Settings.shared.owlOverride = false
        NotificationCenter.default.post(name: .cedricOwlSettingsChanged, object: nil)
        tab.doc.markSaved()
        w.close()
        TypingCheck.settle(0.05)
    }
}
