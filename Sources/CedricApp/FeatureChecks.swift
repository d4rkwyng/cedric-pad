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
}
