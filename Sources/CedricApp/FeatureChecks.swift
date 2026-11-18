import AppKit
import CedricCore

/// In-process checks of Fix Typos… (the spelling step-through), the
/// detachable preview and the CSV grid, run by Scripts/tools-check.sh like
/// the other DevChecks: the menus' key equivalents and real key events
/// sent to the step-through's panel, clicks on its buttons.
///
///   CEDRIC_CHECK=spellstep|detachpreview|csvpreview
@MainActor
extension DevChecks {
    static func featureCheck(_ name: String, _ app: AppDelegate) -> Bool {
        switch name {
        case "spellstep": spellStep(app)
        case "detachpreview": detachPreview(app)
        default: return false
        }
        return true
    }

    /// A key press sent to `w` as an NSEvent (keyDown, keyUp).
    static func keyTo(_ w: NSWindow, _ chars: String, code: UInt16, _ mods: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: w.windowNumber, context: nil, characters: chars,
                                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                w.sendEvent(e)
            }
        }
    }

    static func press(_ b: NSButton) { click(b, at: NSPoint(x: b.bounds.midX, y: b.bounds.midY)) }

    // MARK: Fix Typos…

    static func spellStep(_ app: AppDelegate) {
        let text = "I beleive this. A mispeled word, teh dog and teh cat.\nverry good, verry nice.\nzqxlearnwrd is new.\n`codde` and [linkk](https://exmple.com/pth).\n"
        let md = app.open(write("typos.md", text))!
        let swift = app.open(write("typos.swift", "let mispeledName = 1 // a wrod in a comment\n"))!
        // Large mode (a 120 K-character line): checked only as far as needed.
        let big = String(repeating: "word ", count: 6_000) + "tpyo " + String(repeating: "word ", count: 18_000) + "\n"
        let large = app.open(write("large.txt", big))!
        let ns = text as NSString
        for t in [md, swift, large] { sized(t) }
        let tv = md.textView
        var s: SpellStepController? { md.spellStep }
        var guess = ""
        var learned: [String] = []
        var learnedThen = false
        func now() -> String { s?.current?.word ?? "-" }
        func progress() -> String { s?.progressLabel.stringValue ?? "-" }
        run([
            sync {
                focus(md)
                tv.setSelectedRange(NSRange(location: ns.range(of: "A mispeled").location, length: 0))
                key(";", [.command, .option])
                expect(s != nil && s!.panel.isVisible, "⌥⌘; opens the Fix Typos panel")
                expect(now() == "mispeled", "the first word is the one after the caret", now())
                expect(tv.selectedRange() == ns.range(of: "mispeled"), "and it is selected", "\(tv.selectedRange())")
                expect(s?.table.selectedRow == 0 && !(s?.guesses.isEmpty ?? true), "the first suggestion is preselected",
                       "\(s?.guesses ?? [])")
                // Panel sits next to the word, clear of it.
                if let s, let r = Optional(tv.firstRect(forCharacterRange: ns.range(of: "mispeled"), actualRange: nil)) {
                    expect(!s.panel.frame.intersects(r), "the panel doesn't cover the word", "\(s.panel.frame) \(r)")
                }
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { next() } },
            sync {
                expect(progress() == "1 of 7", "progress counts every word (scan done)", progress())
                guess = s?.guesses.first ?? ""
            },
            snapshot("spellstep-panel.png"),
            { next in
                guard let p = s?.panel else { next(); return }
                snapshot("spellstep-panel-only.png", window: p)(next)
            },
            sync {
                guard let p = s?.panel else { return }
                keyTo(p, "\r", code: 36)
                expect(md.text.contains("A \(guess) word"), "Return changes it to the first suggestion", md.text)
                expect(now() == "teh", "and moves on", now())
                expect(progress() == "2 of 7", "2 of 7", progress())
                guess = s?.guesses.first ?? ""
            },
            sync {
                guard let b = s?.changeAllButton else { return }
                press(b)
                expect(!md.text.contains("teh") && md.text.contains("\(guess) dog and \(guess) cat"), "Change All changes both", md.text)
                expect(now() == "verry", "then the next word", now())
                expect(progress() == "4 of 7", "4 of 7", progress())
            },
            sync {
                guard let p = s?.panel else { return }
                let first = s?.current?.range
                keyTo(p, String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!), code: 124, [.command])
                expect(now() == "verry" && s?.current?.range != first, "⌘→ skips to the next one", "\(now()) \(String(describing: s?.current?.range))")
            },
            sync {
                guard let b = s?.ignoreButton else { return }
                press(b)
                expect(now() == "zqxlearnwrd", "Ignore All passes the rest of that word", now())
                expect(md.text.contains("verry good, verry nice"), "and changes nothing")
                // Learn Word goes to the user's dictionary: learned, checked, and forgotten again.
                s?.onLearn = { w in
                    NSSpellChecker.shared.learnWord(w)
                    learnedThen = NSSpellChecker.shared.hasLearnedWord(w)
                    NSSpellChecker.shared.unlearnWord(w)
                    learned.append(w)
                }
            },
            sync {
                guard let b = s?.learnButton else { return }
                press(b)
                expect(learned == ["zqxlearnwrd"] && learnedThen, "Learn Word learns it", "\(learned)")
                expect(!NSSpellChecker.shared.hasLearnedWord("zqxlearnwrd"), "(and the check forgot it again)")
                expect(now() == "beleive", "then wraps round to the top", now())
                expect(progress() == "7 of 7", "7 of 7", progress())
                expect(!md.text.contains("codde") || now() != "codde", "code spans and links are never stepped into")
            },
            sync {
                guard let p = s?.panel else { return }
                keyTo(p, "\t", code: 48)
                expect(s?.current == nil, "Tab skips the last one", now())
                expect(md.text.contains("I beleive this"), "skipping changes nothing")
            },
            snapshot("spellstep-done.png"),
            sync {
                guard let p = s?.panel else { return }
                keyTo(p, "\u{1b}", code: 53)
                expect(md.spellStep == nil && !p.isVisible, "Esc closes it")
                expect(md.window?.firstResponder === tv, "the text has the focus again")
            },
            sync {
                key("z", [.command])
                expect(md.text.contains("teh dog and teh cat") && !md.text.contains("mispeled"), "one ⌘Z undoes Change All", md.text)
            },
            sync {
                key("z", [.command])
                expect(md.text == text, "the next ⌘Z undoes the single Change", md.text)
            },
            // Typing in the document while the panel is open: the words still to come follow.
            sync {
                tv.setSelectedRange(NSRange(location: 0, length: 0))
                key(";", [.command, .option])
                expect(now() == "beleive", "from the top: beleive", now())
                tv.setSelectedRange(NSRange(location: 0, length: 0))
                tv.insertText("Well, ", replacementRange: NSRange(location: 0, length: 0))
                s?.skip(nil)
                let r = s?.current?.range ?? NSRange(location: 0, length: 0)
                expect(now() == "mispeled" && (md.text as NSString).substring(with: r) == "mispeled",
                       "an edit above moves the words still to come", "\(now()) \(r)")
                s?.done(nil)
                md.textView.undoManager?.undo()
            },
            // Code: comments and strings only, never identifiers.
            sync {
                focus(swift)
                swift.textView.setSelectedRange(NSRange(location: 0, length: 0))
                key(";", [.command, .option])
                expect(swift.spellStep?.current?.word == "wrod", "in code, only comments and strings", swift.spellStep?.current?.word ?? "-")
                swift.spellStep?.done(nil)
            },
            // Large mode: on demand, a few chunks at a time.
            sync {
                focus(large)
                expect(large.extrasPaused, "the long-line file is in large mode")
                large.textView.setSelectedRange(NSRange(location: 0, length: 0))
                key(";", [.command, .option])
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next() } },
            sync {
                let st = large.spellStep
                expect(st?.current?.word == "tpyo", "large mode: the word is found", st?.current?.word ?? "-")
                expect(!(st?.stepper.scanComplete ?? true), "but the rest of the file isn't checked",
                       "\(st?.stepper.unscanned.count ?? -1) chunks left")
                expect(st?.progressLabel.stringValue.hasSuffix("+") == true, "progress says more may come", st?.progressLabel.stringValue ?? "-")
                st?.done(nil)
                for t in [md, swift, large] { t.doc.markSaved() }
            },
        ])
    }

    // MARK: Detached preview

    /// Waits (up to 5 s) until the web preview's text contains `needle`.
    static func waitForPreview(_ tab: EditorWindowController, contains needle: String, _ name: String) -> (@escaping () -> Void) -> Void {
        { next in
            let deadline = Date().addingTimeInterval(5)
            @MainActor func poll() {
                guard let web = tab.preview?.webView else { expect(false, name, "no web preview"); next(); return }
                web.evaluateJavaScript("document.body ? document.body.innerText : ''") { result, _ in
                    MainActor.assumeIsolated {
                        let text = result as? String ?? ""
                        if text.contains(needle) { expect(true, name); next() }
                        else if Date() > deadline { expect(false, name, "preview text=\(text.prefix(120).debugDescription)"); next() }
                        else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { poll() } } }
                    }
                }
            }
            poll()
        }
    }

    static func detachPreview(_ app: AppDelegate) {
        let a = app.open(write("first.md", "# First\n\nhello\n"))!
        let b = app.open(write("second.md", "# Second\n\nother document\n"))!
        sized(a); sized(b)
        let item = { menuItem(action: #selector(AppDelegate.toggleDetachPreview(_:))) }
        var pw: NSWindow? { a.previewWindow?.window }
        run([
            sync {
                focus(a)
                key("p", [.command, .option])
                expect(a.previewVisible && !a.previewDetached && a.previewPane?.superview === a.split, "⌥⌘P docks the preview beside the text")
                expect(a.previewPane?.detachButton.title == "Detach", "its header has Detach", a.previewPane?.detachButton.title ?? "-")
                if let i = item() { _ = app.validateMenuItem(i); expect(i.title == "Detach Preview", "View › Detach Preview", i.title) }
            },
            waitForPreview(a, contains: "hello", "the docked preview shows the document"),
            sync {
                guard let button = a.previewPane?.detachButton else { return }
                press(button)
                expect(a.previewDetached && pw?.isVisible == true, "Detach moves it into its own window")
                expect(pw?.title == "first.md — Preview", "titled after its document", pw?.title ?? "-")
                expect(a.split.subviews.count == 1, "the editor has the whole window")
                expect(pw.map { $0.styleMask.contains(.resizable) } == true, "the window is resizable")
                expect(a.previewPane?.detachButton.title == "Attach", "its header now has Attach", a.previewPane?.detachButton.title ?? "-")
                if let i = item() { _ = app.validateMenuItem(i); expect(i.title == "Attach Preview", "the menu says Attach Preview", i.title) }
                expect(app.currentTab === a, "the editor keeps the focus")
                focus(a)
                a.textView.setSelectedRange(NSRange(location: (a.text as NSString).length, length: 0))
                type("live typing")
            },
            waitForPreview(a, contains: "live typing", "typing updates the detached preview"),
            sync {
                pw?.setFrame(NSRect(x: 160, y: 140, width: 480, height: 400), display: true)
                expect(pw?.frame.size == NSSize(width: 480, height: 400), "it resizes", "\(pw?.frame ?? .zero)")
                // Another tab in front: the detached preview stays with its own document.
                focus(b)
                b.textView.setSelectedRange(NSRange(location: (b.text as NSString).length, length: 0))
                type("zzz")
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { next() } },
            waitForPreview(a, contains: "live typing", "bound to its document while another tab is in front"),
            sync {
                expect(pw?.title == "first.md — Preview" && b.previewPane == nil, "the other tab has no preview of its own")
            },
            { next in
                guard let w = pw else { next(); return }
                snapshot("detached-preview.png", window: w)(next)
            },
            sync {
                // ⇧⌥⌘P from the editor: docked again.
                focus(a)
                key("p", [.command, .option, .shift])
                expect(!a.previewDetached && a.previewPane?.superview === a.split && a.previewVisible, "⇧⌥⌘P attaches it again")
                expect(a.previewWindow == nil, "and its window is gone")
            },
            waitForPreview(a, contains: "live typing", "the re-docked preview is live"),
            sync {
                key("p", [.command, .option, .shift])
                expect(a.previewDetached, "⇧⌥⌘P detaches it")
                // Closing the window closes the preview.
                pw?.performClose(nil)
                expect(a.previewPane == nil && !a.previewVisible, "closing its window closes the preview")
                key("p", [.command, .option, .shift])
                expect(a.previewDetached && pw?.isVisible == true, "⇧⌥⌘P with no preview opens it detached")
            },
            snapshot("detached-preview-editor.png"),
            sync {
                let w = pw
                a.doc.markSaved(); b.doc.markSaved()
                a.window?.performClose(nil)
                expect(w?.isVisible == false, "closing the tab closes its detached preview")
            },
        ])
    }
}
