import AppKit
import CedricCore
import CedricAI

/// CEDRIC_OWL_CHECK_CHAT=1 (with CEDRIC_OWL_CHECK and the fake engine,
/// CEDRIC_AI_FAKE): Ask Cedric end to end, by real key and mouse events.
///
///   1. ⌥⌘/ opens the panel (made on first use);
///   2. Explain: the answer streams in (several partial lengths seen);
///   3. Add Comments on a selected line, with tools: get_lines, then
///      propose_edit becomes a diff; Apply changes the text; one ⌘Z undoes it;
///   4. the same again, then an edit in the document: Apply refuses, Ask Again shows;
///   5. Stop cancels a running answer;
///   6. Escape closes the panel.
@MainActor
enum OwlChatCheck {
    static func check(_ ok: Bool, _ what: String) { OwlCheck.check(ok, what) }
    static func after(_ s: Double, _ f: @escaping @MainActor () -> Void) { OwlCheck.after(s, f) }

    static func run(_ tab: EditorWindowController, out: String) {
        guard let window = tab.window else { return }
        check(tab.owlChat == nil, "no chat panel before it is asked for")
        OwlCheck.key(window, "/", code: 44, [.command, .option])
        after(0.3) {
            guard let chat = tab.owlChat, chat.isShown else {
                check(false, "⌥⌘/ opens Ask Cedric"); OwlCheck.finish(out); return
            }
            check(true, "⌥⌘/ opens Ask Cedric")
            explain(tab, chat, out: out)
        }
    }

    /// CEDRIC_OWL_CHECK_CHAT_OFF=1, no CEDRIC_OWL_CHAT, a fresh defaults
    /// domain: the "Owl chat (beta)" switch is off by default, so Ask Cedric
    /// and Check Grammar with AI are disabled and ⌥⌘/ opens nothing.
    static func runDefaultOff(_ tab: EditorWindowController, out: String) {
        guard let window = tab.window, let app = NSApp.delegate as? AppDelegate else { OwlCheck.finish(out); return }
        check(ProcessInfo.processInfo.environment["CEDRIC_OWL_CHAT"] == nil, "no CEDRIC_OWL_CHAT override")
        check(UserDefaults.standard.object(forKey: "owlChat") == nil, "fresh defaults: owlChat was never set")
        check(!Settings.shared.owlChat, "Owl chat (beta) is off by default")
        check(!tab.canAskCedric, "the tab can't Ask Cedric")
        func item(_ action: Selector, in menu: NSMenu?) -> NSMenuItem? {
            for i in menu?.items ?? [] {
                if i.action == action { return i }
                if let found = item(action, in: i.submenu) { return found }
            }
            return nil
        }
        if let ask = item(#selector(AppDelegate.askCedricMenu(_:)), in: NSApp.mainMenu) {
            check(!app.validateMenuItem(ask), "Edit › Ask Cedric… is disabled")
        } else { check(false, "Edit › Ask Cedric… is in the menu") }
        if let grammar = item(#selector(AppDelegate.checkGrammarWithAIMenu(_:)), in: NSApp.mainMenu) {
            check(!app.validateMenuItem(grammar), "Check Grammar with AI is disabled")
        } else { check(false, "Check Grammar with AI is in the menu") }
        OwlCheck.key(window, "/", code: 44, [.command, .option])
        after(0.4) {
            check(tab.owlChat == nil, "⌥⌘/ opens no chat panel")
            OwlCheck.finish(out)
        }
    }

    /// Waits until the panel is idle, sampling the streamed length.
    static func waitDone(_ chat: OwlChatPanel, timeout: Double = 15, samples: Set<Int> = [], _ then: @escaping @MainActor (Set<Int>) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        var seen = samples
        func poll() {
            if chat.running {
                seen.insert(chat.streamedCount)
                if Date() > deadline { check(false, "answer finished within \(Int(timeout)) s"); then(seen); return }
                after(0.02, poll)
            } else { then(seen) }
        }
        after(0.02, poll)
    }

    static func explain(_ tab: EditorWindowController, _ chat: OwlChatPanel, out: String) {
        guard let b = chat.actionButtons[.explain] else { return }
        OwlCheck.click(b)
        check(chat.running || chat.asks == 1, "Explain starts a request")
        waitDone(chat) { seen in
            check(chat.flushes >= 3, "the answer streamed into the transcript in \(chat.flushes) steps (seen while polling: \(seen.filter { $0 > 0 }.count))")
            check(chat.transcriptText.contains("fake answer from the test engine"), "the full answer is in the transcript")
            OwlCheck.snapshot(chat.panel, "\(out)/chat-1-explain.png") { addComments(tab, chat, out: out) }
        }
    }

    static func addComments(_ tab: EditorWindowController, _ chat: OwlChatPanel, out: String) {
        let tv = tab.textView
        let original = tab.text
        let line2 = (original as NSString).lineRange(for: NSRange(location: (original as NSString).range(of: "\n").location + 1, length: 0))
        tv.setSelectedRange(NSRange(location: line2.location, length: line2.length - 1))
        chat.refresh()
        chat.selectScope(.selection)
        guard let b = chat.actionButtons[.addComments] else { return }
        OwlCheck.click(b)
        waitDone(chat) { _ in
            let o = chat.lastOutcome
            check(chat.lastUsedTools, "tools on for the fake engine (CEDRIC_OWL_TOOLS=1)")
            check((o?.toolCalls ?? 0) >= 2, "the model used tools (\(o?.toolCalls ?? 0) calls: get_lines, propose_edit)")
            check(chat.transcriptText.contains("Looked at lines"), "the transcript shows what Cedric looked at")
            check(o?.proposal != nil && !chat.card.isHidden, "propose_edit became a diff card")
            check(chat.isProposalCurrent && chat.applyButton.isEnabled, "Apply is enabled while the text is unchanged")
            OwlCheck.snapshot(chat.panel, "\(out)/chat-2-diff.png") {
                OwlCheck.click(chat.applyButton)
                let applied = tab.text
                check(applied.contains("// \(FakeChatEngine.commentText)\n"), "Apply inserted the comment")
                check(chat.card.isHidden, "the card closes after Apply")
                if let w = tab.window {
                    w.makeKeyAndOrderFront(nil)
                    w.makeFirstResponder(tv)
                    OwlCheck.key(w, "z", code: 6, [.command])
                }
                check(tab.text == original, "one ⌘Z undoes Cedric’s edit")
                stale(tab, chat, out: out)
            }
        }
    }

    static func stale(_ tab: EditorWindowController, _ chat: OwlChatPanel, out: String) {
        let tv = tab.textView
        let original = tab.text
        let ns = original as NSString
        let line2 = ns.lineRange(for: NSRange(location: ns.range(of: "\n").location + 1, length: 0))
        tv.setSelectedRange(NSRange(location: line2.location, length: line2.length - 1))
        chat.refresh()
        chat.selectScope(.selection)
        OwlCheck.click(chat.actionButtons[.addComments]!)
        waitDone(chat) { _ in
            check(chat.pending != nil, "a second proposal")
            // The user edits the document meanwhile.
            guard let w = tab.window else { return }
            w.makeFirstResponder(tv)
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            OwlCheck.key(w, "x", code: 7, [])
            after(0.1) {
                check(!chat.isProposalCurrent, "after an edit the proposal is stale")
                let before = tab.text
                let ok = chat.applyProposal(nil)
                check(!ok && tab.text == before, "Apply refuses a stale proposal")
                check(!chat.askAgainButton.isHidden && !chat.staleLabel.isHidden, "the card offers Ask Again")
                OwlCheck.snapshot(chat.panel, "\(out)/chat-3-stale.png") {
                    chat.discardProposal(nil)
                    cancel(tab, chat, out: out)
                }
            }
        }
    }

    static func cancel(_ tab: EditorWindowController, _ chat: OwlChatPanel, out: String) {
        tab.textView.setSelectedRange(NSRange(location: 0, length: 0))
        chat.refresh()
        OwlCheck.click(chat.actionButtons[.explain]!)
        after(0.15) {
            check(chat.running, "a request is running")
            OwlCheck.click(chat.stopButton)
            after(0.1) {
                check(!chat.running, "Stop cancels it")
                check(chat.transcriptText.contains("Stopped"), "the transcript says it stopped")
                check(chat.stopButton.isHidden && !chat.sendButton.isHidden, "Ask is back after Stop")
                let count = chat.streamedCount
                after(0.4) {
                    check(chat.streamedCount == count, "nothing more arrives after Stop")
                    let md = { () -> String in chat.copyMarkdown(nil); return NSPasteboard.general.string(forType: .string) ?? "" }()
                    check(md.contains("**You:**") && md.contains("```diff"), "Copy as Markdown has the questions and the diff")
                    finishChecks(tab, chat, out: out)
                }
            }
        }
    }

    static func finishChecks(_ tab: EditorWindowController, _ chat: OwlChatPanel, out: String) {
        chat.panel.makeKeyAndOrderFront(nil)
        chat.panel.makeFirstResponder(chat.input)
        if let fe = chat.panel.fieldEditor(false, for: chat.input) {
            _ = chat.control(chat.input, textView: fe as! NSTextView, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        }
        after(0.3) {
            check(!chat.isShown, "Escape closes the panel")
            OwlChatCheck.after(0.05) { extra(tab, out) }
        }
    }

    /// CEDRIC_OWL_CHECK_CHAT=grammar: Check Grammar with AI on a prose file
    /// (the fake engine "finds" "then I expected"): an underline, the
    /// owl's grammar bubble, Fix it, one ⌘Z.
    static func runGrammar(_ tab: EditorWindowController, out: String) {
        guard let window = tab.window else { return }
        let deadline = Date().addingTimeInterval(15)
        func waitProse() {
            if tab.grammar.lastSawProse == true {
                check(tab.canCheckGrammarWithAI, "Check Grammar with AI is available in prose")
                let original = tab.text
                NSApp.sendAction(#selector(AppDelegate.checkGrammarWithAIMenu(_:)), to: nil, from: nil)
                check(tab.grammar.aiPasses == 1, "the menu item starts one AI pass")
                waitBubble(original)
                return
            }
            if Date() > deadline { check(false, "the text was found to be prose"); OwlCheck.finish(out); return }
            after(0.2, waitProse)
        }
        func waitBubble(_ original: String) {
            if let b = tab.owl?.bubble, GrammarMap.isGrammarHint(b.hint.id) {
                check(b.hint.replacement == "than I expected", "the owl offers the AI's grammar fix (\(b.hint.title))")
                let r = (tab.text as NSString).range(of: "then I expected")
                check(tab.textView.grammarRanges.contains(r), "the AI's finding is underlined like the system's")
                OwlCheck.snapshot(window, "\(out)/grammar-ai.png") {
                    guard let fix = b.buttons.first(where: { $0.title == String(localized: "Fix it") }) else { check(false, "Fix it"); OwlCheck.finish(out); return }
                    OwlCheck.click(fix)
                    check(tab.text.contains("than I expected") && !tab.text.contains("then I expected"), "Fix it applied the AI's correction")
                    window.makeFirstResponder(tab.textView)
                    OwlCheck.key(window, "z", code: 6, [.command])
                    check(tab.text == original, "one ⌘Z undoes it")
                    OwlCheck.finish(out)
                }
                return
            }
            if Date() > deadline { check(false, "a grammar bubble from the AI within 15 s"); OwlCheck.finish(out); return }
            after(0.2) { waitBubble(original) }
        }
        waitProse()
    }

    /// Hook for later steps.
    static var extra: @MainActor (EditorWindowController, String) -> Void = { tab, out in animations(tab, out: out) }

    /// The owl's animations, then the same under Reduce Motion.
    static func animations(_ tab: EditorWindowController, out: String) {
        guard let owl = tab.owl, let window = tab.window else { OwlCheck.finish(out); return }
        let v = owl.owl
        OwlView.reduceMotion = false
        owl.reduceMotionChanged()
        owl.chatPhase(.thinking)
        check(v.isPlaying && v.inState, "thinking loops while the AI works")
        owl.chatPhase(.searching)
        check(v.isPlaying, "searching loops while a search tool runs")
        owl.chatPhase(nil)
        check(!v.isPlaying && v.pose == .idle, "back to idle when the answer is done")
        owl.nod()
        check(v.isPlaying, "a nod plays after an edit is applied")
        // Typing stops a gesture at once.
        window.makeFirstResponder(tab.textView)
        OwlCheck.key(window, "y", code: 16, [])
        check(!v.isPlaying, "typing stops the gesture (never animates while typing)")
        let looks = owl.looks
        after(1.1) {
            owl.idleTickNow()
            check(owl.looks == looks + 1 && v.isPlaying, "after typing stops he looks toward the caret")
            v.stopSequence()
            // Reduce Motion.
            OwlView.reduceMotion = true
            owl.reduceMotionChanged()
            owl.chatPhase(.thinking)
            check(!v.isPlaying && v.inState, "Reduce Motion: thinking is a still frame, no timer")
            owl.chatPhase(.writing)
            check(!v.isPlaying, "Reduce Motion: writing is a still frame")
            owl.chatPhase(nil)
            owl.nod()
            v.flap()
            v.wave()
            check(!v.isPlaying, "Reduce Motion: no nod, flap or wave")
            owl.idleTickNow()
            check(!v.isPlaying, "Reduce Motion: an idle tick animates nothing")
            OwlCheck.snapshot(window, "\(out)/anim-reduce-motion.png") {
                OwlView.reduceMotion = OwlView.currentReduceMotion()
                OwlCheck.finish(out)
            }
        }
    }
}
