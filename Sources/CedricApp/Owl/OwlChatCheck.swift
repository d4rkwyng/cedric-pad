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

    /// Hook for later steps (animations, grammar).
    static var extra: @MainActor (EditorWindowController, String) -> Void = { _, out in OwlCheck.finish(out) }
}
