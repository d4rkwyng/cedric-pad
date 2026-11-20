#if DEBUG
import UIKit
import CedricCore

/// Debug builds only: `-OwlinkSaveCheck <dir>` runs the data-safety
/// behaviour inside the app (the Edited mark, Undo/Redo, the recovery copy,
/// Revert to Opened Version, "Save automatically" off, the close prompt),
/// renders the window at the interesting moments to <dir>/save-*.png,
/// writes <dir>/savecheck.txt (PASS/FAIL lines) and quits. It ends by
/// holding the edited editor on screen for 20 s for an outside screenshot.
@MainActor
enum SaveCheck {
    static var outDir: URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-OwlinkSaveCheck"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1])
    }

    private static var log: [String] = []
    private static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        log.append((ok ? "PASS " : "FAIL ") + what)
        if !ok { failures += 1 }
    }

    static func run(in window: UIWindow, browser: UIViewController, out: URL) {
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let saveSetting = AppSettings.saveAutomatically
            await steps(window, browser, out)
            AppSettings.saveAutomatically = saveSetting
            log.append(failures == 0 ? "savecheck: all passed" : "savecheck: \(failures) failed")
            try? log.joined(separator: "\n").appending("\n").write(to: out.appendingPathComponent("savecheck.txt"), atomically: true, encoding: .utf8)
            try? await Task.sleep(for: .seconds(20))
            exit(failures == 0 ? 0 : 1)
        }
    }

    static func info(_ what: String, _ tv: UITextView) {
        let um = tv.undoManager
        log.append("INFO \(what): canUndo \(um?.canUndo ?? false) '\(um?.undoActionName ?? "")' canRedo \(um?.canRedo ?? false) level \(um?.groupingLevel ?? -1) um \(um.map { String(describing: type(of: $0)) } ?? "nil") firstResponder \(tv.isFirstResponder) len \((tv.text as NSString).length)")
    }

    static func wait(_ seconds: Double, until: () -> Bool) async -> Bool {
        for _ in 0..<Int(seconds * 10) {
            if until() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return until()
    }

    private static func steps(_ window: UIWindow, _ browser: UIViewController, _ out: URL) async {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("savecheck.swift")
        try? FileManager.default.removeItem(at: url)
        if let src = Bundle.main.url(forResource: "sample", withExtension: "swift", subdirectory: "Samples") {
            try? FileManager.default.copyItem(at: src, to: url)
        }
        let original = (try? Data(contentsOf: url)) ?? Data()
        let store = SaveSafetyStores.recovery
        AppSettings.saveAutomatically = true
        let doc = TextDocument(fileURL: url)
        let opened = await withCheckedContinuation { c in doc.open { c.resume(returning: $0) } }
        check(opened, "opened the sample")
        guard opened else { return }
        check(doc.openedCopy == .kept && doc.openedBytes() == original, "kept a private copy of the bytes as opened")
        let editor = EditorViewController(document: doc)
        let nav = UINavigationController(rootViewController: editor)
        nav.modalPresentationStyle = .fullScreen
        // The document browser may still be starting: wait for the editor
        // to be on screen before touching it.
        for _ in 0..<60 where browser.presentedViewController == nil {
            if browser.view.window != nil { browser.present(nav, animated: false) }
            try? await Task.sleep(for: .milliseconds(500))
        }
        check(await wait(15) { editor.view.window != nil && !editor.textView.text.isEmpty }, "editor on screen with the text")
        try? await Task.sleep(for: .seconds(1))
        let tv = editor.textView
        check(!doc.hasUnsavedChanges && !editor.editedShown, "not Edited after opening")
        info("after open", tv)
        check(editor.undoBarItem.isEnabled == false, "Undo disabled before any edit")
        SelfCheck.render(window, out.appendingPathComponent("save-opened.png"))

        // Typing: Edited at once, Undo enabled, a recovery copy within ~3 s.
        tv.selectedRange = NSRange(location: (tv.text as NSString).length, length: 0)
        tv.insertText("// typed by the save check\n")
        info("right after insertText", tv)
        try? await Task.sleep(for: .milliseconds(300))
        info("0.3 s after insertText", tv)
        check(doc.hasUnsavedChanges, "typing marks the document edited")
        check(editor.editedShown, "the Edited mark shows")
        check(await wait(2) { editor.undoBarItem.isEnabled }, "Undo enabled after typing")
        // Before autosave can run (it may, with the setting on): turn it off.
        AppSettings.saveAutomatically = false
        check(await wait(5) { store.read(documentPath: doc.recoveryPath)?.text == tv.text }, "recovery copy written with the unsaved text")
        SelfCheck.render(window, out.appendingPathComponent("save-edited.png"))

        // Autosave off: an autosave doesn't touch the file.
        let autosaved = await withCheckedContinuation { c in doc.autosave { c.resume(returning: $0) } }
        check(autosaved && (try? Data(contentsOf: url)) == original, "with Save Automatically off, autosave leaves the file alone")
        check(editor.navigationItem.rightBarButtonItems?.contains(editor.saveBarItem) == true, "Save button in the bar with it off")

        // Undo and Redo.
        info("before undo", tv)
        tv.undoManager?.undo()
        info("after undo", tv)
        check(!tv.text.contains("typed by the save check"), "Undo removes the typing")
        check(await wait(2) { editor.redoBarItem.isEnabled }, "Redo enabled after Undo")
        tv.undoManager?.redo()
        check(tv.text.contains("typed by the save check"), "Redo puts it back")

        // The close prompt (shown, then cancelled).
        editor.closeDocument()
        try? await Task.sleep(for: .seconds(1))
        let alert = editor.presentedViewController as? UIAlertController
        check(alert?.actions.map(\.title) == ["Save", "Don’t Save", "Cancel"], "close asks Save / Don’t Save / Cancel")
        SelfCheck.render(window, out.appendingPathComponent("save-close-prompt.png"))
        if alert != nil { await withCheckedContinuation { c in editor.dismiss(animated: false) { c.resume() } } }

        // Revert to Opened Version: one undoable change.
        editor.revertToOpened()
        info("after revert", tv)
        check(tv.text == TextCodec.decode(original)?.text, "Revert puts back the opened text")
        tv.undoManager?.undo()
        check(tv.text.contains("typed by the save check"), "Undo after Revert brings the edits back")

        // Save: Edited clears, the recovery copy goes, the file has the edit.
        editor.saveDocument()
        check(await wait(5) { !doc.hasUnsavedChanges }, "Save clears the Edited state")
        check(await wait(3) { store.read(documentPath: doc.recoveryPath) == nil }, "recovery copy deleted on save")
        check(!editor.editedShown, "the Edited mark goes after saving")
        let back = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        check(back.contains("typed by the save check"), "file on disk has the edit")

        // Edited again for the outside screenshot (left in place: the
        // app quits after it, like a forced quit).
        tv.insertText("// unsaved\n")
        _ = await wait(5) { store.read(documentPath: doc.recoveryPath) != nil }
        SelfCheck.render(window, out.appendingPathComponent("save-edited-again.png"))
        let pending = store.pending(documentPath: doc.recoveryPath,
                                    documentModified: try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        check(pending != nil, "the recovery copy is newer than the file (offered on next launch)")
    }
}
#endif
