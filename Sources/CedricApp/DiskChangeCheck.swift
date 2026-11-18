import AppKit
import CedricCore

/// CEDRIC_CHECK=diskconflict (Scripts/tools-check.sh): another process
/// rewrites an open file, then ⌘S. The save must ask (Keep My Version /
/// Reload Theirs / Compare) instead of overwriting; a window becoming key
/// shows the "Changed on disk" bar for a tab with unsaved edits, owl off.
@MainActor
extension DevChecks {
    /// Rewrites `url` from another process (as another app would).
    static func rewriteElsewhere(_ url: URL, _ text: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "printf '%s' \"$1\" > \"$2\"", "sh", text, url.path]
        try? p.run()
        p.waitUntilExit()
    }

    static func sheetButton(_ tab: EditorWindowController, _ title: String) -> NSButton? {
        func find(_ v: NSView) -> NSButton? {
            if let b = v as? NSButton, b.title == title { return b }
            for s in v.subviews { if let b = find(s) { return b } }
            return nil
        }
        return tab.window?.attachedSheet?.contentView.flatMap(find)
    }

    static func diskConflict(_ app: AppDelegate) {
        let url = write("conflict.txt", "mine\n")
        let tab = app.open(url)!
        sized(tab)
        func disk() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "-" }
        let compares = app.compareWindows.count
        run([
            sync {
                expect(tab.owl == nil, "the owl is off")
                focus(tab)
                tab.textView.setSelectedRange(NSRange(location: 4, length: 0))
                type(" one")
                rewriteElsewhere(url, "theirs\n")
                key("s", [.command])
            },
            sync {
                expect(disk() == "theirs\n", "⌘S didn't overwrite the other app's change", disk())
                expect(tab.window?.attachedSheet != nil, "⌘S asks instead")
                expect(sheetButton(tab, "Keep My Version") != nil && sheetButton(tab, "Reload Theirs") != nil
                       && sheetButton(tab, "Compare") != nil, "with Keep My Version, Reload Theirs and Compare")
                sheetButton(tab, "Compare")?.performClick(nil)
            },
            sync {
                expect(app.compareWindows.count == compares + 1, "Compare opens the compare view")
                expect(disk() == "theirs\n" && tab.doc.isDirty, "and saves nothing")
                app.compareWindows.last?.window?.performClose(nil)
                focus(tab)
                key("s", [.command])
            },
            sync {
                expect(tab.window?.attachedSheet != nil, "⌘S again still asks")
                sheetButton(tab, "Reload Theirs")?.performClick(nil)
            },
            sync {
                expect(tab.text == "theirs\n" && !tab.doc.isDirty, "Reload Theirs takes the file's text", tab.text)
                tab.textView.undoManager?.undo()
                expect(tab.text == "mine one\n", "Undo brings mine back", tab.text)
                rewriteElsewhere(url, "theirs again\n")
                focus(tab)
                key("s", [.command])
            },
            sync {
                expect(tab.window?.attachedSheet != nil, "a second change asks again")
                sheetButton(tab, "Keep My Version")?.performClick(nil)
            },
            sync {
                expect(disk() == "mine one\n" && !tab.doc.isDirty, "Keep My Version writes this tab's text", disk())
                focus(tab)
                tab.textView.setSelectedRange(NSRange(location: 8, length: 0))
                type(" two")
                key("s", [.command])
            },
            sync {
                expect(tab.window?.attachedSheet == nil && disk() == "mine one two\n", "an ordinary ⌘S doesn't ask", disk())
                type(" three")
                rewriteElsewhere(url, "changed while away\n")
                tab.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: tab.window))
            },
            sync {
                expect(tab.diskBar?.isHidden == false, "becoming key shows the Changed on disk bar (owl off)",
                       tab.diskBar?.label.stringValue ?? "no bar")
                expect(tab.text == "mine one two three\n" && tab.doc.isDirty, "and keeps the unsaved edits", tab.text)
            },
            snapshot("disk-changed-bar.png"),
            sync {
                tab.diskBar?.button("Keep Mine")?.performClick(nil)
                expect(tab.diskBar?.isHidden == true, "Keep Mine hides the bar")
                key("s", [.command])
            },
            sync {
                expect(tab.window?.attachedSheet == nil && disk() == "mine one two three\n", "then ⌘S saves without asking", disk())
                rewriteElsewhere(url, "clean reload\n")
                tab.reloadIfChangedOnDisk()
                expect(tab.text == "clean reload\n" && tab.diskBar?.isHidden != false, "a tab without edits just reloads", tab.text)
            },
        ])
    }
}
