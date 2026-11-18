import AppKit
import CedricCore
import WebKit

/// In-process checks of the Markdown preview and tools, run by
/// Scripts/tools-check.sh like the other DevChecks.
///
///   CEDRIC_CHECK=mdpreview|outline
@MainActor
extension DevChecks {
    static func markdownCheck(_ name: String, _ app: AppDelegate) -> Bool {
        switch name {
        case "mdpreview": markdownPreview(app)
        case "outline": outlineCheck(app)
        default: return false
        }
        return true
    }

    /// Runs `code` in the preview, in Cedric's own content world (where
    /// its script lives), and hands over the result.
    static func previewJS(_ tab: EditorWindowController, _ code: String, _ then: @escaping @MainActor (Any?) -> Void) {
        guard let web = tab.preview?.webView else { then(nil); return }
        web.evaluateJavaScript(code, in: nil, in: .defaultClient) { result in
            MainActor.assumeIsolated {
                switch result {
                case .success(let v): then(v)
                case .failure(let e): then("error: \(e)")
                }
            }
        }
    }

    /// The same, in the page's own world (what page JavaScript would see).
    static func pageJS(_ tab: EditorWindowController, _ code: String, _ then: @escaping @MainActor (Any?) -> Void) {
        guard let web = tab.preview?.webView else { then(nil); return }
        web.evaluateJavaScript(code) { v, _ in MainActor.assumeIsolated { then(v) } }
    }

    /// Waits (up to 5 s) for the preview to apply a render after the current one.
    static func waitForSwap(_ tab: EditorWindowController, _ name: String, since: @escaping () -> Int) -> (@escaping () -> Void) -> Void {
        { next in
            let start = since()
            let deadline = Date().addingTimeInterval(5)
            @MainActor func poll() {
                let n = (tab.preview?.bodySwaps ?? 0) + (tab.preview?.pageLoads ?? 0)
                if n > start { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { next() } }
                else if Date() > deadline { expect(false, name, "no render"); next() }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { MainActor.assumeIsolated { poll() } } }
            }
            poll()
        }
    }

    static func markdownPreview(_ app: AppDelegate) {
        var body = "# Notes\n\nFirst paragraph with a [link to other](other.md) and ![dot](dot.png).\n\n"
        body += "<script>document.title = 'page-script-ran'</script>\n\n<img src=\"nope.png\" onerror=\"document.title='handler-ran'\">\n\n"
        for k in 1...60 { body += "## Section \(k)\n\nParagraph \(k) with some *text* to fill the page out a little.\n\n- item a\n- item b\n\n" }
        // A 1x1 PNG beside the file (relative images load from the document's folder).
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
        try? png.write(to: dir.appendingPathComponent("dot.png"))
        _ = write("other.md", "# Other\n\nthe other file\n")
        let tab = app.open(write("notes.md", body))!
        sized(tab)
        let p = { tab.preview }
        var loadsBefore = 0, swapsBefore = 0
        var scrollY = 0.0
        run([
            sync {
                focus(tab)
                key("p", [.command, .option])
                expect(tab.previewVisible, "⌥⌘P shows the preview")
            },
            waitForPreview(tab, contains: "Paragraph 60", "the preview shows the document"),
            { next in
                previewJS(tab, "typeof window.__cedricPatch + ',' + typeof window.__cedricScrollTo") { v in
                    expect(v as? String == "function,function", "Cedric's script runs in its own world with page JavaScript off", "\(v ?? "nil")")
                    next()
                }
            },
            { next in
                pageJS(tab, "document.title + '|' + typeof window.__cedricPatch") { v in
                    expect(v as? String == "|undefined", "page scripts and handlers don't run, and the page can't see Cedric's script", "\(v ?? "nil")")
                    next()
                }
            },
            { next in
                previewJS(tab, "(() => { const i = document.querySelector('img[alt=dot]'); return i ? i.complete + ',' + i.naturalWidth : 'none' })()") { v in
                    expect(v as? String == "true,1", "a relative image loads from the document's folder", "\(v ?? "nil")")
                    next()
                }
            },
            { next in
                previewJS(tab, "document.documentElement.setAttribute('data-cedric-mark', '1'); window.__cedricQuietUntil = Date.now() + 500; window.scrollTo(0, 600); window.__cedricLineAt(window.scrollY + 8)") { v in
                    scrollY = (v as? NSNumber)?.doubleValue ?? -1
                    loadsBefore = p()?.pageLoads ?? 0
                    swapsBefore = p()?.bodySwaps ?? 0
                    next()
                }
            },
            sync {
                // An edit near the top: only that block is swapped in.
                let ns = tab.text as NSString
                tab.textView.setSelectedRange(NSRange(location: ns.range(of: "First paragraph").location, length: 0))
                type("Very ")
            },
            waitForSwap(tab, "typing renders the preview", since: { swapsBefore + loadsBefore }),
            waitForPreview(tab, contains: "Very First paragraph", "the edit shows in the preview"),
            { next in
                previewJS(tab, "document.documentElement.getAttribute('data-cedric-mark') + ',' + window.__cedricLineAt(window.scrollY + 8)") { v in
                    let parts = (v as? String ?? "").split(separator: ",")
                    expect(parts.first == "1", "the page isn't reloaded (no flash)", "\(v ?? "nil")")
                    let y = parts.count > 1 ? Double(parts[1]) ?? -1 : -1
                    expect(abs(y - scrollY) < 0.5, "the preview stays on the same text (an edit above doesn't move it)", "line before \(scrollY) after \(y)")
                    expect(p()?.pageLoads == loadsBefore && (p()?.bodySwaps ?? 0) > swapsBefore, "only the body is swapped",
                           "loads \(p()?.pageLoads ?? -1) swaps \(p()?.bodySwaps ?? -1)")
                    next()
                }
            },
            { next in
                previewJS(tab, "document.querySelectorAll('li[data-line]').length") { v in
                    expect(((v as? NSNumber)?.intValue ?? 0) >= 120, "list items carry their source lines", "\(v ?? "nil")")
                    next()
                }
            },
            // Editor → preview.
            // (Laid out whole first: an occluded window's text view doesn't grow by itself.)
            sync { if let tlm = tab.textView.textLayoutManager { tlm.ensureLayout(for: tlm.documentRange); tlm.textViewportLayoutController.layoutViewport() }; tab.window?.displayIfNeeded(); tab.scrollToLine(200) },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { next() } },
            { next in
                let top = tab.topLine
                previewJS(tab, "window.__cedricLineAt(window.scrollY + 8)") { v in
                    let line = (v as? NSNumber)?.doubleValue ?? -1
                    expect(abs(line - Double(top)) <= 3, "scrolling the editor scrolls the preview to the same line", "editor \(top) preview \(line)")
                    next()
                }
            },
            // Preview → editor: a scroll the user makes in the preview.
            { next in
                previewJS(tab, "window.__cedricQuietUntil = 0; window.scrollTo(0, document.documentElement.scrollHeight / 4); window.__cedricLineAt(window.scrollY + 8)") { v in
                    let line = (v as? NSNumber)?.doubleValue ?? -1
                    // (An occluded window's page delivers its scroll events late: wait.)
                    let started = Date(), deadline = started.addingTimeInterval(4)
                    @MainActor func poll() {
                        let top = tab.topLine
                        if abs(Double(top) - line) <= 3 || Date() > deadline {
                            expect(abs(Double(top) - line) <= 3, "scrolling the preview scrolls the editor to the same line", "preview \(line) editor \(top)")
                            print("check: note: the editor followed after \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
                            next()
                        } else {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { poll() } }
                        }
                    }
                    poll()
                }
            },
            // A relative .md link opens in Cedric.
            { next in
                previewJS(tab, "document.querySelector('a[href=\"other.md\"]').click(); 1") { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        let other = app.tabs.first { $0.doc.fileURL?.lastPathComponent == "other.md" }
                        expect(other != nil, "a relative .md link opens the file in a Cedric tab", app.tabs.map(\.doc.displayName).joined(separator: ","))
                        other?.doc.markSaved()
                        other?.window?.performClose(nil)
                        next()
                    }
                }
            },
            // Detached: still swapped in place.
            sync {
                focus(tab)
                key("p", [.command, .option, .shift])
                expect(tab.previewDetached, "the preview detaches")
                loadsBefore = p()?.pageLoads ?? 0
                swapsBefore = p()?.bodySwaps ?? 0
                tab.textView.setSelectedRange(NSRange(location: (tab.text as NSString).length, length: 0))
                type("detached edit")
            },
            waitForPreview(tab, contains: "detached edit", "typing updates the detached preview"),
            sync {
                expect(p()?.pageLoads == loadsBefore && (p()?.bodySwaps ?? 0) > swapsBefore, "the detached preview swaps the body too",
                       "loads \(p()?.pageLoads ?? -1) swaps \(p()?.bodySwaps ?? -1)")
                key("p", [.command, .option, .shift])
                expect(!tab.previewDetached && tab.previewVisible, "and docks again")
            },
            { next in perfBigMarkdown(app, tab, next) },
            sync { for t in app.tabs { t.doc.markSaved() } },
        ])
    }

    /// A 1 MB Markdown file with the preview open: the main thread's time
    /// per keystroke and per preview update.
    static func perfBigMarkdown(_ app: AppDelegate, _ small: EditorWindowController, _ next: @escaping () -> Void) {
        var unit = "## Part\n\nSome **bold** and *em* text with `code` and a [link](https://example.com). Another sentence to fill.\n\n"
        unit += "- one\n- two\n  - nested\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```swift\nlet x = 1\n```\n\n> quoted line\n\n"
        let big = String(repeating: unit, count: 1_048_576 / unit.utf8.count + 1)
        let tab = app.open(write("big.md", big))!
        sized(tab)
        focus(tab)
        let t0 = DispatchTime.now()
        _ = Markdown.render(big, options: .preview)
        let renderMs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
        print("check: metric md_1mb_render_ms=\(String(format: "%.1f", renderMs)) (now off the main thread)")
        tab.togglePreview()
        var keyMs: [Double] = []
        var updateMs: [Double] = []
        var rounds = 0
        @MainActor func round() {
            guard rounds < 12, let p = tab.preview else { finish(); return }
            rounds += 1
            let before = p.bodySwaps + p.pageLoads
            p.resetMainThreadTimes()
            tab.textView.setSelectedRange(NSRange(location: 40 + rounds * 7, length: 0))
            let k0 = DispatchTime.now()
            type("x")
            keyMs.append(Double(DispatchTime.now().uptimeNanoseconds - k0.uptimeNanoseconds) / 1e6)
            let deadline = Date().addingTimeInterval(8)
            @MainActor func wait() {
                if p.bodySwaps + p.pageLoads > before {
                    updateMs.append(p.mainThreadTimes.max() ?? 0)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { round() } }
                } else if Date() > deadline {
                    expect(false, "1 MB: the preview updates", "no render")
                    finish()
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { MainActor.assumeIsolated { wait() } }
                }
            }
            wait()
        }
        @MainActor func finish() {
            func median(_ a: [Double]) -> Double { a.isEmpty ? -1 : a.sorted()[a.count / 2] }
            let kMed = median(keyMs), uMax = updateMs.max() ?? -1
            print("check: metric md_1mb_key_median_ms=\(String(format: "%.2f", kMed)) key_max_ms=\(String(format: "%.2f", keyMs.max() ?? -1))")
            print("check: metric md_1mb_preview_main_thread_max_ms=\(String(format: "%.2f", uMax)) median=\(String(format: "%.2f", median(updateMs))) background_render_ms=\(String(format: "%.1f", tab.preview?.lastRenderMs ?? -1))")
            expect(updateMs.count >= 10, "1 MB: the preview updates after each pause", "\(updateMs.count)")
            expect(kMed < 16, "1 MB: a keystroke stays under a frame with the preview open", "\(kMed) ms")
            expect(uMax < 16, "1 MB: a preview update costs the main thread under a frame", "\(uMax) ms")
            tab.doc.markSaved()
            next()
        }
        // Let the first full render land.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated { round() } }
    }

    // MARK: Outline

    static func waitForOutline(_ tab: EditorWindowController, after: @escaping () -> Int, _ name: String) -> (@escaping () -> Void) -> Void {
        { next in
            let start = after()
            let deadline = Date().addingTimeInterval(5)
            @MainActor func poll() {
                if (tab.outline.sidebar?.builds ?? 0) > start { next() }
                else if Date() > deadline { expect(false, name, "no rebuild"); next() }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { poll() } } }
            }
            poll()
        }
    }

    static func outlineCheck(_ app: AppDelegate) {
        var text = "# Guide\n\nIntro.\n\n```sh\n# not a heading\n```\n\n"
        for k in 1...30 { text += "## Section \(k)\n\nBody \(k).\n\n" }
        text += "Setext Title\n---\n\nend\n"
        let tab = app.open(write("guide.md", text))!
        let code = app.open(write("code.swift", "// # nope\n"))!
        sized(tab); sized(code)
        var side: OutlineSidebar? { tab.outline.sidebar }
        let ns = { tab.text as NSString }
        func caretLine() -> Int { tab.lineIndex.line(containing: tab.textView.selectedRange().location) }
        var builds = 0
        run([
            sync {
                focus(code)
                if let i = menuItem(action: #selector(AppDelegate.toggleOutlineMenu(_:))) {
                    expect(!app.validateMenuItem(i), "View › Show Outline is off for a Swift file")
                }
                focus(tab)
                if let i = menuItem(action: #selector(AppDelegate.toggleOutlineMenu(_:))) {
                    expect(app.validateMenuItem(i) && i.state == .off, "and on for Markdown")
                }
                expect(tab.outline.sidebar == nil, "the outline isn't built until it is first shown")
                key("o", [.control, .command])
                expect(tab.outlineVisible, "⌃⌘O shows the outline")
            },
            waitForOutline(tab, after: { 0 }, "the outline is built"),
            sync {
                let titles = side?.headings.map(\.title) ?? []
                expect(titles.count == 32 && titles.first == "Guide" && titles.last == "Setext Title", "it lists the # and setext headings",
                       "\(titles.count) \(titles.prefix(3)) \(titles.suffix(1))")
                expect(!titles.contains("not a heading"), "but not a # inside fenced code")
                expect((side?.frame.width ?? 0) > 100 && (tab.scrollView.frame.minX) >= (side?.frame.maxX ?? 0), "it sits left of the text",
                       "\(side?.frame ?? .zero) \(tab.scrollView.frame)")
                let target = ns().range(of: "Body 10.")
                tab.textView.setSelectedRange(NSRange(location: target.location, length: 0))
                let sel = side?.selectedHeading?.title ?? "-"
                expect(sel == "Section 10", "the heading the caret is under is selected", sel)
            },
            snapshot("outline.png"),
            sync {
                // A click on a row jumps there. (A real click when Cedric is the
                // active app; when it isn't, NSTableView ignores the synthetic
                // mouse-down, so the row is selected as the click would.)
                guard let s = side, let row = s.rows.firstIndex(where: { s.headings[$0].title == "Section 25" }) else { return }
                s.table.scrollRowToVisible(row)
                let r = s.table.rect(ofRow: row)
                clickDirect(s.table, at: NSPoint(x: r.midX, y: r.midY))
                if s.table.selectedRow != row { s.table.selectRowIndexes([row], byExtendingSelection: false) }
                let want = s.headings[s.rows[row]].line
                expect(caretLine() == want, "clicking a heading puts the caret on it", "\(caretLine()) want \(want)")
                expect(tab.topLine <= want && tab.topLine >= want - 30, "and scrolls it into view", "top \(tab.topLine)")
                builds = s.builds
                // Typing a new heading: the outline follows when typing pauses.
                tab.textView.setSelectedRange(NSRange(location: ns().length, length: 0))
                type("\r# Appendix")
            },
            waitForOutline(tab, after: { builds }, "typing rebuilds the outline"),
            sync {
                expect(side?.headings.last?.title == "Appendix", "with the new heading", side?.headings.last?.title ?? "-")
                key("o", [.control, .command])
                expect(!tab.outlineVisible, "⌃⌘O hides it again")
                // Go to Heading: the outline with its filter focused.
                key("j", [.command, .shift])
                expect(tab.outlineVisible && tab.outline.transient, "⇧⌘J opens it for the jump")
                expect(tab.window?.firstResponder === side?.field.currentEditor(), "with the filter focused")
                type("tion 7")
                expect(side?.rows.count == 1 && side?.selectedHeading?.title == "Section 7", "typing filters the headings",
                       "\(side?.rows.count ?? -1) \(side?.selectedHeading?.title ?? "-")")
                key("\r")
                let want = side?.headings.first { $0.title == "Section 7" }?.line ?? -1
                expect(caretLine() == want, "Return jumps to it", "\(caretLine()) want \(want)")
                expect(!tab.outlineVisible && tab.window?.firstResponder === tab.textView, "and puts the outline away again, focus back in the text")
                // Esc: back to the text, nowhere else.
                key("j", [.command, .shift])
                type("Sect")
                let before = caretLine()
                key("\u{1b}")
                expect(!tab.outlineVisible && caretLine() == before && tab.window?.firstResponder === tab.textView, "Esc goes back to the text")
                for t in [tab, code] { t.doc.markSaved() }
            },
        ])
    }
}
