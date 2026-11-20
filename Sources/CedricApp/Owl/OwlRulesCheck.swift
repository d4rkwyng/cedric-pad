import AppKit
import CedricCore

/// CEDRIC_OWL_CHECK=/out/dir with CEDRIC_OWL_CHECK_RULES=1: the newer
/// non-AI rules end to end, with real key and mouse events. Open a saved
/// plain-text file holding "Todo\n" (CEDRIC_OPEN) with the owl on.
///
///   1. Types three "- item" lines under the title; waits for "It looks
///      like you're writing a to-do list"; clicks Fix it: the lines are
///      Markdown checkboxes and the tab is Markdown. ⌘Z undoes the edit
///      and the language; ⇧⌘Z redoes both.
///   2. Types "Fix the the bug"; waits for the doubled-word hint; Show Me
///      selects "the the"; then Fix it.
///   3. Types merge-conflict markers; waits for the warning; Show Me
///      selects the `<<<<<<<` line.
///
/// With CEDRIC_OWL_CHECK_AI=1 instead (fake AI, automatic checks off,
/// a Swift file holding `0...items.count`): typing never asks the AI;
/// clicking the owl and "Ask AI Now" does, and its hint appears.
@MainActor
enum OwlRulesCheck {
    static func check(_ ok: Bool, _ what: String) { OwlCheck.check(ok, what) }

    /// Waits for the owl to present `id` (other hints are answered "Not
    /// now" and the owl asked again), then calls `then` with the bubble.
    static func waitFor(_ id: String, in tab: EditorWindowController, timeout: Double = 20,
                        then: @escaping @MainActor (OwlBubble?) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if let owl = tab.owl, let bubble = owl.bubble, let shown = owl.presentedHint?.hint {
                if shown.id == id { then(bubble); return }
                print("owlcheck: (dismissing \(shown.id) while waiting for \(id))")
                if let notNow = bubble.buttons.first(where: { $0.title == String(localized: "Not now") }) { click(notNow) }
                OwlHub.shared.activity(in: tab)
            }
            if Date() > deadline { check(false, "the owl offered \(id) within \(Int(timeout)) s"); then(nil); return }
            OwlCheck.after(0.2) { poll() }
        }
        poll()
    }

    /// A real click; `OwlCheck.click` hands it to the button itself when a
    /// locked screen swallows it, once per reset of `clicked`.
    static func click(_ b: NSView) {
        OwlCheck.clicked = false
        OwlCheck.click(b)
    }

    static func button(_ bubble: OwlBubble, _ title: String) -> NSButton? {
        bubble.buttons.first { $0.title == title }
    }

    static func typeAtEnd(_ tab: EditorWindowController, _ text: String) {
        guard let w = tab.window else { return }
        tab.textView.setSelectedRange(NSRange(location: (tab.textView.string as NSString).length, length: 0))
        AICheck.type(w, text)
    }

    static func run(_ tab: EditorWindowController, out: String) {
        guard let window = tab.window else { OwlCheck.finish(out); return }
        check(tab.text == "Todo\n", "opened the to-do file (\(tab.text.debugDescription))")
        typeAtEnd(tab, "- milk\n- eggs\n- call Mum\n")
        let typed = "Todo\n- milk\n- eggs\n- call Mum\n"
        check(tab.text == typed, "typed three items")
        waitFor(RulesHintProvider.todoListID, in: tab) { bubble in
            guard let bubble, let fix = button(bubble, String(localized: "Fix it")) else { OwlCheck.finish(out); return }
            OwlCheck.snapshot(window, "\(out)/rules-1-todo.png") {
                click(fix)
                check(tab.text == "Todo\n- [ ] milk\n- [ ] eggs\n- [ ] call Mum\n", "Fix it made Markdown checkboxes")
                check(tab.doc.language == .markdown, "and the tab is now Markdown (\(tab.doc.language))")
                OwlCheck.key(window, "z", code: 6, [.command])
                check(tab.text == typed, "one ⌘Z restores the typed list")
                check(tab.doc.language == .plain, "and the tab is Plain Text again (\(tab.doc.language))")
                OwlCheck.key(window, "z", code: 6, [.command, .shift])
                check(tab.text == "Todo\n- [ ] milk\n- [ ] eggs\n- [ ] call Mum\n", "⇧⌘Z redoes the checkboxes")
                check(tab.doc.language == .markdown, "and Markdown (\(tab.doc.language))")
                step2(tab, out: out)
            }
        }
    }

    static func step2(_ tab: EditorWindowController, out: String) {
        guard let window = tab.window else { return }
        typeAtEnd(tab, "Fix the the bug\n")
        waitFor(RulesHintProvider.duplicateWordID, in: tab) { bubble in
            guard let bubble, let show = button(bubble, String(localized: "Show Me")) else { OwlCheck.finish(out); return }
            check(bubble.buttons.map(\.title) == ["Fix it", "Show Me", "Not now", "Don’t show again"].map { String(localized: String.LocalizationValue($0)) },
                  "Fix it, Show Me, Not now, Don’t show again (\(bubble.buttons.map(\.title)))")
            OwlCheck.snapshot(window, "\(out)/rules-2-twice.png") {
                click(show)
                let sel = tab.textView.selectedRange()
                check((tab.text as NSString).substring(with: sel) == "the the", "Show Me selected the doubled words")
                // Shown once per document: present the rules' hint again for Fix it.
                let ctx = tab.owlContextWindow().context
                guard let again = RulesHintProvider().check(ctx, facts: tab.owlFacts(wholeDocument: true)).first(where: { $0.id == RulesHintProvider.duplicateWordID }) else {
                    check(false, "the doubled word is still there"); OwlCheck.finish(out); return
                }
                tab.owl?.present(again, context: ctx)
                OwlCheck.after(0.4) {
                    guard let b2 = tab.owl?.bubble, let fix = button(b2, String(localized: "Fix it")) else { check(false, "Fix it"); OwlCheck.finish(out); return }
                    click(fix)
                    check(tab.text.hasSuffix("- [ ] call Mum\nFix the bug\n"), "Fix it removed the second “the”")
                    step3(tab, out: out)
                }
            }
        }
    }

    static func step3(_ tab: EditorWindowController, out: String) {
        guard let window = tab.window else { return }
        typeAtEnd(tab, "<<<<<<< ours\nmine\n=======\ntheirs\n>>>>>>> theirs\n")
        waitFor(RulesHintProvider.conflictID, in: tab) { bubble in
            guard let bubble, let show = button(bubble, String(localized: "Show Me")) else { OwlCheck.finish(out); return }
            check(button(bubble, String(localized: "Fix it")) == nil, "a warning offers Show Me, no fix")
            // A small window: the bubble stays off the line it is about.
            let size = window.frame.size
            window.setContentSize(NSSize(width: 360, height: 285))
            tab.textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
            window.contentView?.layoutSubtreeIfNeeded()
            tab.owl?.layoutViews()
            let hinted = tab.owl?.hintedRect()
            check(hinted != nil && tab.owl?.bubble.map { !$0.frame.intersects(hinted!) } == true,
                  "in a 360×285 window the bubble doesn’t cover the hinted line (bubble \(String(describing: tab.owl?.bubble?.frame)), line \(String(describing: hinted)))")
            OwlCheck.snapshot(window, "\(out)/rules-3-small.png") {
            window.setContentSize(size)
            window.contentView?.layoutSubtreeIfNeeded()
            tab.owl?.layoutViews()
            OwlCheck.snapshot(window, "\(out)/rules-3-conflict.png") {
                click(show)
                let sel = tab.textView.selectedRange()
                check((tab.text as NSString).substring(with: sel) == "<<<<<<< ours", "Show Me selected the <<<<<<< line")
                check(tab.owl?.bubble == nil, "bubble closed")
                OwlCheck.finish(out)
            }
            }
        }
    }

    // MARK: Markdown's writing checks (0.4.0)

    /// CEDRIC_OWL_CHECK_RULES=markdown: a saved Markdown file holding
    /// `markdownBroken`, next to docs/guide.md. The owl offers the broken
    /// link's nearest file ("Link to “docs/guide.md”?"); Fix it rewrites
    /// the link, keeping its #fragment; one ⌘Z puts it back; ⇧⌘Z redoes it.
    static let markdownBroken = "# Notes\n\nSee [the guide](docs/gide.md#setup) first.\n"
    static let markdownFixed = "# Notes\n\nSee [the guide](docs/guide.md#setup) first.\n"

    static func runMarkdown(_ tab: EditorWindowController, out: String) {
        guard let window = tab.window else { OwlCheck.finish(out); return }
        check(tab.text == markdownBroken, "opened the Markdown file (\(tab.text.debugDescription))")
        check(tab.doc.language == .markdown, "as Markdown (\(tab.doc.language))")
        // The first query only starts the file checks and the folder's
        // listing (off the main thread); the owl asks again on the next
        // activity, as when the writer types on. Nudge him every 1.5 s
        // (longer than CEDRIC_OWL_PAUSE + CEDRIC_OWL_INTERVAL) until he asks.
        var offered = false
        func nudge() {
            guard !offered else { return }
            if tab.owl?.bubble == nil { OwlHub.shared.activity(in: tab) }
            OwlCheck.after(1.5) { nudge() }
        }
        OwlCheck.after(1.5) { nudge() }
        waitFor("rules.md.broken-link", in: tab, timeout: 30) { bubble in
            offered = true
            guard let bubble else { OwlCheck.finish(out); return }
            let title = tab.owl?.presentedHint?.hint.title ?? ""
            check(title == "No file “gide.md”. Link to “docs/guide.md”?", "the hint names the nearest file (\(title))")
            guard let fix = button(bubble, String(localized: "Fix it")) else {
                check(false, "the bubble has Fix it (\(bubble.buttons.map(\.title)))"); OwlCheck.finish(out); return
            }
            OwlCheck.snapshot(window, "\(out)/markdown-1-broken-link.png") {
                click(fix)
                check(tab.text == markdownFixed, "Fix it linked docs/guide.md#setup (\(tab.text.debugDescription))")
                OwlCheck.key(window, "z", code: 6, [.command])
                check(tab.text == markdownBroken, "one ⌘Z restores the broken link")
                OwlCheck.key(window, "z", code: 6, [.command, .shift])
                check(tab.text == markdownFixed, "⇧⌘Z redoes the fix")
                OwlCheck.finish(out)
            }
        }
    }

    // MARK: AI only when asked

    static func runAI(_ tab: EditorWindowController, out: String) {
        guard let window = tab.window, let owl = tab.owl else { OwlCheck.finish(out); return }
        let hub = OwlHub.shared
        hub.appActiveChanged()
        AICheck.wait("the AI provider", timeout: 10, { hub.ai.isActive }) { ok in
            check(ok, "the fake AI registered")
            check(!hub.ai.isAutomatic, "automatic checks are off (CEDRIC_AI_AUTO=0)")
            check(hub.ai.statusLine()?.hasSuffix("checks only when you ask") == true, "status says so (\(hub.ai.statusLine() ?? "-"))")
            typeAtEnd(tab, "// still typing\n")
            // Pause, min-idle and interval are all 0.2 s here: an automatic check would have run.
            OwlCheck.after(3) {
                check(hub.ai.lastCheck == nil && hub.ai.thinking.isEmpty, "typing and pausing never asked the AI")
                OwlCheck.click(owl.owl)
                AICheck.wait("the popover", timeout: 3, { owl.popoverShown }) { _ in
                    guard let ask = owl.popoverButton(String(localized: "Ask AI Now")) else {
                        check(false, "the popover has Ask AI Now"); OwlCheck.finish(out); return
                    }
                    OwlCheck.snapshot(window, "\(out)/ai-1-popover.png") {
                        AICheck.press(ask, "Ask AI Now") { hub.ai.lastCheck != nil || !hub.ai.thinking.isEmpty || !owl.popoverShown }
                        AICheck.wait("the AI hint", timeout: 10, { owl.presentedHint?.hint.id == "fake-off-by-one" }) { ok in
                            check(ok, "Ask AI Now asked once and its hint appeared")
                            if !ok { print("owlcheck: lastCheck=\(String(describing: hub.ai.lastCheck)) thinking=\(hub.ai.thinking) popover=\(owl.popoverShown) bubble=\(owl.bubble != nil) source=\(hub.coordinator.source)") }
                            OwlCheck.snapshot(window, "\(out)/ai-2-asked.png") { OwlCheck.finish(out) }
                        }
                    }
                }
            }
        }
    }
}
