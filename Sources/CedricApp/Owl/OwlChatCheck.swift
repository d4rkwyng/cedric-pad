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
/// Before step 2, Cedric in the panel's header (`face`): he waves, listens
/// to real typing, thinks, searches, talks and nods through a question,
/// light, dark and under Reduce Motion; and stops when the panel closes.
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
            face(tab, chat, out: out) { explain(tab, chat, out: out) }
        }
    }

    /// CEDRIC_OWL_CHECK_CHAT_OFF=1, no CEDRIC_OWL_CHAT, a fresh defaults
    /// domain and no engine ready (CEDRIC_ASK_ENGINE=0): Ask Cedric is off,
    /// Ask Cedric and Check Grammar with AI are disabled, ⌥⌘/ opens
    /// nothing, and the owl offers Set Up Ask Cedric… first.
    static func runDefaultOff(_ tab: EditorWindowController, out: String) {
        guard let window = tab.window, let app = NSApp.delegate as? AppDelegate else { OwlCheck.finish(out); return }
        check(DevEnvironment.values["CEDRIC_OWL_CHAT"] == nil, "no CEDRIC_OWL_CHAT override")
        check(UserDefaults.standard.object(forKey: "owlChat") == nil, "fresh defaults: owlChat was never set")
        check(!AskCedricEngine.isAvailable, "no engine ready (CEDRIC_ASK_ENGINE=0)")
        check(!Settings.shared.owlChat, "Ask Cedric is off with no engine ready")
        check(!tab.canAskCedric, "the tab can't Ask Cedric")
        if let ask = menuItem(#selector(AppDelegate.askCedricMenu(_:))) {
            check(!app.validateMenuItem(ask), "Edit › Ask Cedric… is disabled")
        } else { check(false, "Edit › Ask Cedric… is in the menu") }
        if let grammar = menuItem(#selector(AppDelegate.checkGrammarWithAIMenu(_:))) {
            check(!app.validateMenuItem(grammar), "Check Grammar with AI is disabled")
        } else { check(false, "Check Grammar with AI is in the menu") }
        OwlCheck.key(window, "/", code: 44, [.command, .option])
        after(0.4) {
            check(tab.owlChat == nil, "⌥⌘/ opens no chat panel")
            guard let owl = tab.owl else { OwlCheck.finish(out); return }
            OwlCheck.click(owl.owl)
            after(0.3) {
                check(owl.popoverButton(String(localized: "Set Up Ask Cedric…")) != nil, "the owl offers Set Up Ask Cedric…")
                check(owl.popoverButtonsFit, "every button in the owl's popover fits inside it")
                check(owl.popoverButton(String(localized: "Ask about this file…")) == nil, "and no Ask about this file…")
                guard let pw = owl.popoverButton(String(localized: "Set Up Ask Cedric…"))?.window else { owl.closePopover(); OwlCheck.finish(out); return }
                OwlCheck.snapshot(pw, "\(out)/owl-menu-setup.png") {
                    owl.closePopover()
                    OwlCheck.finish(out)
                }
            }
        }
    }

    static func menuItem(_ action: Selector) -> NSMenuItem? {
        func find(_ menu: NSMenu?) -> NSMenuItem? {
            for i in menu?.items ?? [] {
                if i.action == action { return i }
                if let found = find(i.submenu) { return found }
            }
            return nil
        }
        return find(NSApp.mainMenu)
    }

    /// CEDRIC_OWL_CHECK_CHAT=default, fresh defaults, no CEDRIC_OWL_CHAT,
    /// an engine ready (the fake): Ask Cedric is on by default; the owl's
    /// first item is Ask about this file…, which opens the panel; and the
    /// one-time hint (CEDRIC_ASK_HINT=1) shows once and is remembered.
    static func runDefaultOn(_ tab: EditorWindowController, out: String) {
        guard let window = tab.window, let owl = tab.owl else { OwlCheck.finish(out); return }
        check(UserDefaults.standard.object(forKey: "owlChat") == nil, "fresh defaults: owlChat was never set")
        check(AskCedricEngine.isAvailable, "an engine is ready (the fake)")
        check(Settings.shared.owlChat, "Ask Cedric is on by default when an engine is ready")
        UserDefaults.standard.removeObject(forKey: OwlController.askIntroKey)
        // The one-time hint.
        after(0.8) {
            owl.introduceAskCedric()   // what the idle tick does
            let b = owl.bubble
            check(b?.hint.id == OwlController.askIntroID, "the owl introduces Ask Cedric once (\(b?.hint.title ?? "no bubble"))")
            check(UserDefaults.standard.bool(forKey: OwlController.askIntroKey), "and remembers that it did")
            OwlCheck.snapshot(window, "\(out)/ask-intro.png") {
                if let got = b?.buttons.first(where: { $0.title == String(localized: "Got it") }) { OwlCheck.click(got) }
                check(owl.bubble == nil, "Got it closes it")
                check(!owl.introduceAskCedric() && owl.bubble == nil, "it doesn't come back")
                OwlCheck.click(owl.owl)
                after(0.3) {
                    guard let first = owl.popoverButton(String(localized: "Ask about this file…")) else {
                        check(false, "the owl offers Ask about this file…"); OwlCheck.finish(out); return
                    }
                    let stack = first.superview as? NSStackView
                    check(stack?.arrangedSubviews.first === first, "Ask about this file… is the first item")
                    check(owl.popoverButton(String(localized: "Set Up Ask Cedric…")) == nil, "no Set Up item with an engine ready")
                    check(owl.popoverButton(String(localized: "Check Script for Risks…")) == nil, "no script check for a Swift file")
                    OwlCheck.snapshot(first.window ?? window, "\(out)/owl-menu.png") {
                        OwlCheck.click(first)
                        after(0.3) {
                            check(tab.owlChat?.isShown == true, "Ask about this file… opens Ask Cedric")
                            if let chat = tab.owlChat {
                                check(chat.actionButtons[.explainLine]?.isHidden == false, "Explain Line is offered for code")
                                check(chat.actionButtons[.scriptSafety]?.isHidden == true, "Check for Risks isn't, for Swift")
                                check(chat.actionButtons[.summarise]?.isHidden == true, "Summarise isn't, for code")
                                explainLine(tab, chat, out: out)
                            } else { OwlCheck.finish(out) }
                        }
                    }
                }
            }
        }
    }

    /// Explain Line with only a caret: the caret's line is what is asked about.
    static func explainLine(_ tab: EditorWindowController, _ chat: OwlChatPanel, out: String) {
        let ns = tab.text as NSString
        let line3 = ns.lineRange(for: NSRange(location: ns.range(of: "for ").location, length: 0))
        tab.textView.setSelectedRange(NSRange(location: line3.location + 2, length: 0))
        chat.refresh()
        OwlCheck.click(chat.actionButtons[.explainLine]!)
        waitDone(chat) { _ in
            check(chat.transcriptText.contains("Lines 3–3 look fine"), "Explain Line asked about the caret's line only (line 3)")
            check(tab.textView.selectedRange().length == 0, "the caret is left alone")
            chat.close()
            OwlCheck.finish(out)
        }
    }

    /// CEDRIC_OWL_CHECK_CHAT=script: a risky PowerShell script. The owl
    /// offers the check; the offline scan's findings show first; then the
    /// (fake) model's review with a verdict. CEDRIC_OWL_CHAT=0 too: the
    /// scan alone, with a note that no AI was asked.
    static func runScript(_ tab: EditorWindowController, out: String) {
        guard let window = tab.window, let owl = tab.owl else { OwlCheck.finish(out); return }
        let aiOn = Settings.shared.owlChat
        OwlCheck.click(owl.owl)
        after(0.3) {
            guard let b = owl.popoverButton(String(localized: "Check Script for Risks…")) else {
                check(false, "the owl offers Check Script for Risks… for a .ps1"); OwlCheck.finish(out); return
            }
            check(true, "the owl offers Check Script for Risks… for a .ps1")
            OwlCheck.snapshot(b.window ?? window, "\(out)/owl-menu-script.png") { OwlCheck.click(b) }
            after(0.2) {
                guard let chat = tab.owlChat, chat.isShown else { check(false, "the check opens the panel"); OwlCheck.finish(out); return }
                waitDone(chat, timeout: 20) { _ in
                    after(0.3) {
                        let scan = chat.lastScan ?? []
                        let cats = Set(scan.map(\.category))
                        check(cats.isSuperset(of: [.downloadAndRun, .encoded, .disablesSecurity, .broadDelete]),
                              "the offline scan flagged download-and-run, encoded, security off and a broad delete (\(scan.count) findings)")
                        check(chat.transcriptText.contains("Offline scan (no AI)"), "the scan's findings are in the transcript")
                        check(chat.transcriptText.contains("Verdict: " + ScriptVerdict.forcedDontRun),
                              "a high finding forces the verdict \"\(ScriptVerdict.forcedDontRun)\"")
                        check(chat.transcriptText.range(of: "safe to run", options: .caseInsensitive) == nil,
                              "the transcript never says \"safe to run\"")
                        if aiOn {
                            check(chat.transcriptText.contains("Verdict:"), "the model's review ends with a verdict")
                            let renders = chat.streamedRenders
                            check(!renders.isEmpty && renders.allSatisfy { r in
                                r.range(of: "safe to run", options: .caseInsensitive) == nil && r.hasSuffix("Verdict: " + ScriptVerdict.forcedDontRun + ".")
                                    && !r.contains(ScriptVerdict.trustSource)
                            }, "every streamed render is clamped: the forced verdict only, never the model's (\(renders.count) renders)")
                            if DevEnvironment.values["CEDRIC_AI_FAKE"] != nil {
                                check(chat.transcriptText.contains("Line \(scan.first?.line ?? 0): risky"), "the model was given the scan's findings")
                            } else {
                                print("owlcheck: live answer: \(chat.transcriptText.components(separatedBy: "Cedric\n").last ?? "")")
                            }
                        } else {
                            check(chat.transcriptText.contains("offline scan only"), "with Ask Cedric off, the scan alone, saying so")
                            check(chat.asks == 0, "and no AI request")
                        }
                        OwlCheck.snapshot(chat.panel, "\(out)/script-safety\(aiOn ? "" : "-offline").png") {
                            chat.close()
                            _ = window
                            OwlCheck.finish(out)
                        }
                    }
                }
            }
        }
    }

    /// Types `text` into the question field, key by key, through the panel.
    static func type(_ chat: OwlChatPanel, _ text: String) {
        chat.panel.makeKeyAndOrderFront(nil)
        chat.panel.makeFirstResponder(chat.input)
        for ch in text { OwlCheck.key(chat.panel, String(ch), code: 0, []) }
    }

    /// Cedric in the header through one question, then under Reduce Motion.
    static func face(_ tab: EditorWindowController, _ chat: OwlChatPanel, out: String, then: @escaping @MainActor () -> Void) {
        let f = chat.face
        OwlView.reduceMotion = false
        // With the screen locked the window server reports the panel
        // occluded; the check treats it as visible from then on.
        f.updateLive()
        f.reduceMotionChanged()
        check(f.isLive, "the panel's owl is on screen with the panel")
        check(f.moodLog.contains(.wave), "he waves when the panel opens (\(f.moodLog))")
        check(f.superview != nil && f.window === chat.panel, "he sits in the panel's header")
        OwlCheck.snapshot(chat.panel, "\(out)/chat-owl-0-wave.png") {
            after(1.2) {
                check(f.mood == .idle && f.blinkScheduled, "the wave settles to idle, with a blink scheduled")
                f.blinkNow()
                check(f.isAnimating, "idle: he blinks")
                after(0.4) {
                    let before = f.moodLog.count
                    type(chat, "Where is 'total' used?")
                    let listens = f.moodLog[before...].filter { $0 == .listen }.count
                    check(chat.input.stringValue == "Where is 'total' used?", "typed with real keys (\(chat.input.stringValue))")
                    check(f.mood == .listen && listens == 1, "typing: he listens, once for a burst of keys (\(listens))")
                    OwlCheck.snapshot(chat.panel, "\(out)/chat-owl-1-listen.png") {
                        let start = f.moodLog.count
                        var talkShot = false
                        OwlCheck.key(chat.panel, "\r", code: 36, [])
                        check(chat.running, "Return asks the question")
                        @MainActor func poll() {
                            if chat.running {
                                if f.mood == .talk, !talkShot {
                                    talkShot = true
                                    OwlCheck.snapshot(chat.panel, "\(out)/chat-owl-2-talk.png") {}
                                }
                                after(0.02) { poll() }
                                return
                            }
                            let seen = Array(f.moodLog[start...])
                            let order: [OwlChatMood] = [.think, .search, .talk, .nod]
                            var i = 0
                            for m in seen where i < order.count && m == order[i] { i += 1 }
                            check(i == order.count, "asking: think, search, talk, then a nod (\(seen))")
                            check(chat.transcriptText.contains("fake answer"), "the answer arrived")
                            OwlCheck.snapshot(chat.panel, "\(out)/chat-owl-3-nod.png") {
                                chat.panel.appearance = NSAppearance(named: .darkAqua)
                                after(0.1) {
                                    OwlCheck.snapshot(chat.panel, "\(out)/chat-owl-4-dark.png") {
                                        chat.panel.appearance = nil
                                        reduced(chat, out: out, then: then)
                                    }
                                }
                            }
                        }
                        after(0.02) { poll() }
                    }
                }
            }
        }
    }

    /// Reduce Motion: still poses only, never a timer.
    static func reduced(_ chat: OwlChatPanel, out: String, then: @escaping @MainActor () -> Void) {
        let f = chat.face
        OwlView.reduceMotion = true
        f.reduceMotionChanged()
        check(!f.isAnimating && !f.blinkScheduled, "Reduce Motion: no frame or blink timer when idle")
        let shown = f.framesShown
        type(chat, "Explain this")
        check(!f.isAnimating, "Reduce Motion: no listening glance")
        let start = f.moodLog.count
        var moved = false
        var stills: Set<ObjectIdentifier> = []
        OwlCheck.key(chat.panel, "\r", code: 36, [])
        @MainActor func poll() {
            if f.isAnimating { moved = true }
            if let c = f.current { stills.insert(ObjectIdentifier(c)) }
            if chat.running { after(0.02) { poll() }; return }
            if f.isAnimating { moved = true }
            let seen = Array(f.moodLog[start...])
            check(!moved, "Reduce Motion: no strip plays while asking (\(seen))")
            check(seen.contains(.think) && seen.contains(.talk), "Reduce Motion: his moods still follow the chat (\(seen))")
            let poses = Set([OwlArt.poses[.idle], OwlArt.poses[.thinking], OwlArt.poses[.talking]].compactMap { $0.map(ObjectIdentifier.init) })
            check(stills.isSubset(of: poses), "Reduce Motion: only still poses are drawn (\(f.framesShown - shown) changes)")
            OwlCheck.snapshot(chat.panel, "\(out)/chat-owl-5-reduce-motion.png") {
                OwlView.reduceMotion = false
                f.reduceMotionChanged()
                chat.clearHistory(nil)
                then()
            }
        }
        after(0.02) { poll() }
    }

    /// Waits until the panel is idle, sampling the streamed length.
    static func waitDone(_ chat: OwlChatPanel, timeout: Double = 15, samples: Set<Int> = [], _ then: @escaping @MainActor (Set<Int>) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        var seen = samples
        func poll() {
            if chat.running {
                seen.insert(chat.streamedCount)
                if Date() > deadline { check(false, "answer finished within \(Int(timeout)) s"); then(seen); return }
                after(0.02) { poll() }
            } else { then(seen) }
        }
        after(0.02) { poll() }
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
                check(chat.face.mood == .flap, "the panel's owl flaps on Apply (\(chat.face.mood))")
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
            check(!chat.face.isLive && !chat.face.isAnimating && !chat.face.blinkScheduled,
                  "the panel's owl stops when it closes: no timers")
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
            after(0.2) { waitProse() }
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
