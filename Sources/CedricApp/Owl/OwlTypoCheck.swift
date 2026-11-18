import AppKit
import CedricCore

/// CEDRIC_OWL_CHECK=/out/dir with CEDRIC_OWL_CHECK_TYPOS=1: "Fix N
/// typos?" on the owl's shared schedule (build 7 findings F-M1, F-M2,
/// F-H1), with real key events. Open a saved prose file with typos
/// (CEDRIC_OPEN, `diary.txt`); `server.log` and an empty `email.txt` sit
/// next to it. Run with CEDRIC_OWL_PAUSE (the typing pause) above 1.2 s.
///
///   1. diary.txt, nothing typed: the typo offer comes once the pause has
///      passed after the open.
///   2. server.log with misspelled field names: no typo offer (and no
///      Trim), however long the owl looks.
///   3. email.txt: typing a two-sentence email at about 7 keys a second,
///      with a 1.2 s pause after the first sentence: no bubble while
///      typing; the offer comes after the last key, not before the pause.
@MainActor
enum OwlTypoCheck {
    static func check(_ ok: Bool, _ what: String) { OwlCheck.check(ok, what) }
    static var pause: Double { OwlHub.shared.coordinator.typingPause }

    static func run(_ tab: EditorWindowController, out: String) {
        guard let window = tab.window, let owl = tab.owl, let dir = tab.doc.fileURL?.deletingLastPathComponent() else {
            check(false, "opened diary.txt with the owl"); OwlCheck.finish(out); return
        }
        check(pause > 1.2, "the typing pause (\(pause) s) is longer than the 1.2 s sentence pause")
        let opened = Date()
        AICheck.wait("the typo offer after opening", timeout: pause + 8, { owl.bubble != nil }) { _ in
            let hint = owl.presentedHint?.hint
            let waited = Date().timeIntervalSince(opened)
            check(hint?.id == OwlController.typoFixID, "an opened prose file gets the typo offer without typing (\(hint?.id ?? "none"))")
            check(waited >= pause - 0.3, "not before the pause (after \(String(format: "%.1f", waited)) s)")
            check(owl.bubble?.buttons.map(\.title).contains(String(localized: "Fix All")) == true, "with Fix All")
            OwlCheck.snapshot(window, "\(out)/typos-1-opened.png") {
                owl.hideBubble()
                window.close()
                logFile(dir.appendingPathComponent("server.log"), dir: dir, out: out)
            }
        }
    }

    static func logFile(_ url: URL, dir: URL, out: String) {
        guard let app = NSApp.delegate as? AppDelegate, let tab = app.open(url), let window = tab.window, let owl = tab.owl else {
            check(false, "opened server.log"); OwlCheck.finish(out); return
        }
        window.makeKeyAndOrderFront(nil)
        var seen: [String] = []
        let start = Date()
        func poll() {
            if let h = owl.presentedHint?.hint {
                seen.append(h.id)
                owl.hideBubble()
                OwlHub.shared.activity(in: tab)
            }
            if Date().timeIntervalSince(start) < pause + 5 { OwlCheck.after(0.2) { poll() }; return }
            check(!seen.contains(OwlController.typoFixID), "no typo offer in a log (\(seen))")
            check(!seen.contains(RulesHintProvider.trailingID), "and no Trim in a log")
            check(tab.text.contains("dur=0ms"), "the log is untouched")
            window.close()
            typing(dir.appendingPathComponent("email.txt"), out: out)
        }
        poll()
    }

    static func typing(_ url: URL, out: String) {
        guard let app = NSApp.delegate as? AppDelegate, let tab = app.open(url), let window = tab.window, let owl = tab.owl else {
            check(false, "opened email.txt"); OwlCheck.finish(out); return
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(tab.textView)
        let first = "Hi Sam, I beleive teh trip is verry close now. "
        let second = "We should pack tonite and leave erly in the morning."
        var shownWhileTyping: [String] = []
        var keys = Array(first) + ["\u{0}"] + Array(second)   // \0: the sentence pause
        var lastKey = Date()
        func next() {
            if let h = owl.presentedHint?.hint { shownWhileTyping.append(h.id); owl.hideBubble() }
            guard !keys.isEmpty else { done(); return }
            let c = keys.removeFirst()
            if c == "\u{0}" { OwlCheck.after(1.2) { next() }; return }
            AICheck.type(window, String(c))
            lastKey = Date()
            OwlCheck.after(0.14) { next() }
        }
        func done() {
            check(shownWhileTyping.isEmpty, "no bubble while typing, even in the 1.2 s pause (\(shownWhileTyping))")
            AICheck.wait("the typo offer after typing", timeout: pause + 8, { owl.bubble != nil }) { _ in
                let waited = Date().timeIntervalSince(lastKey)
                check(owl.presentedHint?.hint.id == OwlController.typoFixID, "the typo offer after the pause (\(owl.presentedHint?.hint.id ?? "none"))")
                check(waited >= pause - 0.3, "only once typing paused (\(String(format: "%.1f", waited)) s after the last key)")
                OwlCheck.snapshot(window, "\(out)/typos-2-typed.png") {
                    owl.hideBubble()
                    tab.doc.markSaved()
                    OwlCheck.finish(out)
                }
            }
        }
        OwlCheck.after(0.3) { next() }
    }
}
