import AppKit
import CedricCore

/// CEDRIC_OWL_CHECK_CHAT=panel-tabs (with CEDRIC_OWL_CHECK and the fake
/// engine): files opened while Ask Cedric, then Settings, is the key window
/// land in the document window's tab group, never as tabs of that window.
/// Opens a text file, a PDF and a Markdown file through
/// application(_:open:), the path `open -a` and the Finder use.
/// (0.1.1-rc1 VM: a file opened with Ask Cedric key became a tab in the panel.)
@MainActor
enum PanelTabsCheck {
    static func check(_ ok: Bool, _ what: String) { OwlCheck.check(ok, what) }
    static func after(_ s: Double, _ f: @escaping @MainActor () -> Void) { OwlCheck.after(s, f) }
    /// "X is the key window": only an active app has one. With the screen
    /// locked (or the app in the background) nothing can be made key, so
    /// this is noted instead of failed, and the placement checks still run;
    /// run it at an unlocked screen (or in the test VM) for the real test.
    static func keyCheck(_ ok: Bool, _ what: String) {
        if NSApp.isActive { check(ok, what) } else { print("owlcheck: (app not active, no key window: skipped \"\(what)\")") }
    }

    static func run(_ tab: EditorWindowController, out: String) {
        guard let docWindow = tab.window, let app = NSApp.delegate as? AppDelegate else { OwlCheck.finish(out); return }
        let dir = URL(fileURLWithPath: out).appendingPathComponent("panel-tabs-files")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let txt = dir.appendingPathComponent("notes.txt")
        let pdf = dir.appendingPathComponent("doc.pdf")
        let md = dir.appendingPathComponent("readme.md")
        let txt2 = dir.appendingPathComponent("settings-open.txt")
        try? "plain text\n".write(to: txt, atomically: true, encoding: .utf8)
        try? "# Title\n\nSome *markdown*.\n".write(to: md, atomically: true, encoding: .utf8)
        try? "opened with Settings key\n".write(to: txt2, atomically: true, encoding: .utf8)
        let txt3 = dir.appendingPathComponent("minimized-open.txt")
        try? "opened with every document window minimized\n".write(to: txt3, atomically: true, encoding: .utf8)
        let page = NSTextField(labelWithString: "Hello PDF from the panel-tabs check")
        page.frame = NSRect(x: 0, y: 0, width: 300, height: 120)
        try? page.dataWithPDF(inside: page.bounds).write(to: pdf)

        tab.openAskCedric()
        after(0.4) {
            guard let chat = tab.owlChat, chat.isShown else {
                check(false, "Ask Cedric opens"); OwlCheck.finish(out); return
            }
            let panel = chat.panel
            check(panel.tabbingMode == .disallowed, "the Ask Cedric panel doesn't tab")
            let files = [txt, pdf, md]
            @MainActor func step(_ i: Int) {
                guard i < files.count else { reopen(); return }
                panel.makeKeyAndOrderFront(nil)
                after(0.2) {
                    keyCheck(NSApp.keyWindow === panel, "Ask Cedric is the key window before opening \(files[i].lastPathComponent)")
                    app.application(NSApp, open: [files[i]])
                    after(0.6) {
                        verify(files[i], host: panel, hostName: "Ask Cedric", app: app, docWindow: docWindow)
                        step(i + 1)
                    }
                }
            }
            // Reopen Closed Tab with the panel key: back in the document window.
            @MainActor func reopen() {
                guard let w = window(for: txt, app: app) else { check(false, "notes.txt is open to close"); settings(); return }
                w.performClose(nil)
                after(0.4) {
                    check(window(for: txt, app: app) == nil, "notes.txt closed")
                    panel.makeKeyAndOrderFront(nil)
                    after(0.2) {
                        keyCheck(NSApp.keyWindow === panel, "Ask Cedric is the key window before Reopen Closed Tab")
                        NSApp.sendAction(#selector(AppDelegate.reopenClosedTab(_:)), to: nil, from: nil)
                        after(0.6) {
                            verify(txt, host: panel, hostName: "Ask Cedric", app: app, docWindow: docWindow, what: "reopened ")
                            settings()
                        }
                    }
                }
            }
            @MainActor func settings() {
                SettingsWindowController.show()
                after(0.4) {
                    guard let sw = SettingsWindowController.shared?.window else {
                        check(false, "Settings opens"); OwlCheck.finish(out); return
                    }
                    keyCheck(NSApp.keyWindow === sw, "Settings is the key window before opening \(txt2.lastPathComponent)")
                    app.application(NSApp, open: [txt2])
                    after(0.6) {
                        verify(txt2, host: sw, hostName: "Settings", app: app, docWindow: docWindow)
                        sw.close()
                        OwlCheck.snapshot(docWindow, "\(out)/panel-tabs.png") { minimized() }
                    }
                }
            }
            // No visible document window (all minimized), the panel key:
            // the file gets a window of its own, never a tab of the panel.
            @MainActor func minimized() {
                for w in docWindow.tabGroup?.windows ?? [docWindow] { w.miniaturize(nil) }
                after(1.0) {
                    panel.makeKeyAndOrderFront(nil)
                    after(0.3) {
                        keyCheck(NSApp.keyWindow === panel, "Ask Cedric is the key window with every document window minimized")
                        app.application(NSApp, open: [txt3])
                        after(0.8) {
                            let name = txt3.lastPathComponent
                            guard let w = window(for: txt3, app: app) else { check(false, "\(name) opened"); done(); return }
                            check(w !== panel && w.isVisible && !w.isMiniaturized, "\(name) opened in a visible window that isn't the panel")
                            check(!(panel.tabbedWindows ?? []).contains(w) && (panel.tabbedWindows?.count ?? 0) <= 1,
                                  "Ask Cedric has no tabs (tabbedWindows: \(panel.tabbedWindows?.count ?? 0))")
                            done()
                        }
                    }
                }
            }
            @MainActor func done() {
                for w in docWindow.tabGroup?.windows ?? [docWindow] where w.isMiniaturized { w.deminiaturize(nil) }
                after(0.6) {
                    chat.close()
                    OwlCheck.finish(out)
                }
            }
            step(0)
        }
    }

    static func window(for url: URL, app: AppDelegate) -> NSWindow? {
        let path = url.standardizedFileURL.path
        if let t = app.tabs.last(where: { $0.doc.fileURL?.standardizedFileURL.path == path }) { return t.window }
        if let t = app.pdfTabs.last(where: { $0.window?.representedURL?.standardizedFileURL.path == path }) { return t.window }
        return app.viewerTabs.last { $0.window?.representedURL?.standardizedFileURL.path == path }?.window
    }

    static func verify(_ url: URL, host: NSWindow, hostName: String, app: AppDelegate, docWindow: NSWindow, what: String = "") {
        let name = what + url.lastPathComponent
        guard let w = window(for: url, app: app) else { check(false, "\(name) opened"); return }
        check(w !== host, "\(name) is not the \(hostName) window")
        check(host.tabbedWindows?.count ?? 0 <= 1 && !(host.tabbedWindows ?? []).contains(w),
              "\(hostName) has no tabs (tabbedWindows: \(host.tabbedWindows?.count ?? 0))")
        check(docWindow.tabGroup?.windows.contains(w) == true,
              "\(name) is a tab in the document window's tab group (\(docWindow.tabGroup?.windows.count ?? 0) tabs)")
        check(!(host.tabGroup?.windows.contains(docWindow) ?? false), "\(hostName) stays a separate window")
    }
}
